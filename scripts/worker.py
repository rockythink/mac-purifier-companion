"""NDJSON worker for temperature-driven local purifier control."""

from __future__ import annotations

from collections import deque
from dataclasses import replace
from datetime import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time
import uuid
from typing import Any

import keyring
from keyring.backends.macOS import Keyring
from miio import AirPurifier
from miio.integrations.airpurifier.zhimi.airpurifier import OperationMode, SUPPORTED_MODELS

from history_store import HistoryStore
from host_metrics import read_system_conditions, sample_top_processes
from link_rules import Config, RuleEngine, expected_device_state, still_owned
from pair_device import (
    PairingError, PairingSession, commit_credentials, read_token,
    delete_local_credentials, verify_candidate,
)

ROOT = Path(__file__).resolve().parents[1]
LOCAL = Path(os.environ.get(
    "MACFANLINK_DATA_DIR",
    Path.home() / "Library" / "Application Support" / "cc.ss-data.MacFanLink",
))
STATE_PATH = LOCAL / "worker_state.json"
LOCK_PATH = LOCAL / "worker.lock"
DEVICE_PATH = LOCAL / "device.json"
RESOURCE_DIR = Path(os.environ.get("MACFANLINK_RESOURCE_DIR", ROOT / "Resources"))
MODELS = frozenset(SUPPORTED_MODELS)
MACMON = os.environ.get("MACFANLINK_MACMON", "macmon")
HOST_SAMPLE_SECONDS = 2.0
HISTORY_SAMPLE_SECONDS = 20.0


def _finite(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return float(value)


def _source_timestamp(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return _finite(value)
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError):
        return None


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    LOCAL.mkdir(mode=0o700, parents=True, exist_ok=True)
    LOCAL.chmod(0o700)
    temporary = path.with_suffix(".tmp")
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)
def _catalog_presentation(model: str) -> dict[str, str | None]:
    try:
        catalog = json.loads((RESOURCE_DIR / "model-catalog.json").read_text())
        entry = catalog.get("models", {}).get(model, {})
        image = entry.get("imageURL")
        name = entry.get("name")
        return {
            "imageURL": image if isinstance(image, str) and image else None,
            "productName": name if isinstance(name, str) and name else None,
        }
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return {"imageURL": None, "productName": None}


class Sensor:
    def __init__(self, output: queue.Queue[tuple[str, Any]], sample_seconds: float) -> None:
        self.output = output
        self.sample_seconds = sample_seconds
        self.process: subprocess.Popen[str] | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        interval = max(1000, int(self.sample_seconds * 1000))
        self.process = subprocess.Popen(
            [MACMON, "pipe", "-s", "0", "-i", str(interval)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.thread = threading.Thread(target=self._read, name="macmon-reader", daemon=True)
        self.thread.start()

    def _read(self) -> None:
        assert self.process and self.process.stdout
        for line in self.process.stdout:
            try:
                self.output.put(("sensor", json.loads(line)))
            except json.JSONDecodeError:
                self.output.put(("sensor_error", "invalid_json"))
        self.output.put(("sensor_error", "exited"))

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.process = None


class Worker:
    def __init__(self) -> None:
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.logs: deque[str] = deque(maxlen=12)
        self.mode = "dryRun"
        self.reason = "首次运行默认仅演练，不会写入设备"
        self.config = Config()
        self.verified: set[int] = set()
        self.intent_enabled = False
        self.manual_paused = False
        self.snapshot: dict[str, Any] | None = None
        self.expected: dict[str, Any] | None = None
        self.owner = False
        self.busy = False
        self.command_state = "none"
        self.command_detail = ""
        self.temperature: dict[str, Any] = {"cpu": None, "gpu": None, "cpuLoad": None, "timestamp": None, "stale": True}
        self.system: dict[str, Any] = {
            "timestamp": None, "stale": True, "gpuLoad": None, "memory": None,
            "memoryPressure": None, "thermalState": None, "fans": [],
        }
        self.sensor_received_mono: float | None = None
        self.sensor_source_wall: float | None = None
        self.system_received_mono: float | None = None
        self.system_source_wall: float | None = None
        self.last_wall: float | None = None
        self.last_mono: float | None = None
        self.device_view: dict[str, Any] = {
            "reachable": False, "power": None, "mode": None, "level": None, "rpm": None,
            "model": "", "firmware": "", "ip": "", "name": "", "imageURL": None,
            "productName": None,
            "supported": False, "supportDescription": "尚未选择设备",
        }
        self.account: dict[str, Any] = {
            "paired": False, "label": "", "region": "", "phase": "idle", "message": "",
            "qrImagePath": None, "expiresAt": None, "devices": [],
        }
        self.pairing: PairingSession | None = None
        self.pairing_thread: threading.Thread | None = None
        self.device: AirPurifier | None = None
        self.rule = RuleEngine(self.config)
        self.sensor: Sensor | None = None
        self.test_session: dict[str, Any] | None = None
        self.running = True
        self.last_emit = 0.0
        self.last_device_poll = 0.0
        self.status_dirty = True
        self.output_closed = False
        self.device_identity: str | None = None
        self.history_device_identity: str | None = None
        self.history_error: str | None = None
        self.history_session = uuid.uuid4().hex
        self.device_observed_mono: float | None = None
        self.last_history_timestamp: float | None = None
        self.last_history_signature: tuple[Any, ...] | None = None
        self.processes_pending = False
        try:
            self.history: HistoryStore | None = HistoryStore(LOCAL / "history.sqlite3")
        except Exception as exception:
            self.history = None
            self.history_error = f"历史记录不可用（{type(exception).__name__}）"
        self._load_state()

    def _load_state(self) -> None:
        try:
            metadata = json.loads(DEVICE_PATH.read_text())
            if isinstance(metadata, dict):
                self.device_identity = metadata.get("credentialId")
                stable_id = metadata.get("id") or metadata.get("credentialId")
                self.history_device_identity = stable_id if isinstance(stable_id, str) and stable_id else None
        except (OSError, ValueError, TypeError):
            pass
        if not STATE_PATH.exists():
            return
        try:
            data = json.loads(STATE_PATH.read_text())
            if not isinstance(data, dict):
                raise ValueError("state")
            self.config = Config.from_dict(data.get("config", {}))
            if not self.device_identity or data.get("deviceIdentity") != self.device_identity:
                self.config = replace(self.config, mediumLevel=None, highLevel=None)
                self.mode, self.manual_paused = "paused", True
                self.reason = "设备身份已变化，旧档位验证和恢复快照未复用"
                self.rule = RuleEngine(self.config)
                return
            self.verified = {int(x) for x in data.get("verifiedLevels", []) if isinstance(x, int) and not isinstance(x, bool) and 0 <= x <= 17}
            self.intent_enabled = data.get("intentEnabled") is True
            self.manual_paused = data.get("manualPaused") is True
            self.snapshot = data.get("snapshot") if isinstance(data.get("snapshot"), dict) else None
            self.expected = data.get("expected") if isinstance(data.get("expected"), dict) else None
            if self.manual_paused:
                self.mode = "paused"
                self.reason = "人工暂停已保留，需要显式恢复"
            elif self.intent_enabled:
                self.mode = "enabled"
                self.reason = "正在重新核对设备并等待新鲜温度"
            else:
                saved_mode = data.get("mode")
                self.mode = saved_mode if saved_mode in ("dryRun", "stopped") else "dryRun"
                self.reason = "已恢复上次运行模式"
            self.rule = RuleEngine(self.config)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            self.mode = "dryRun"
            self.reason = "运行状态无效，已安全回到仅演练"
            self.snapshot = self.expected = None

    def persist(self) -> None:
        _atomic_json(STATE_PATH, {
            "version": 2, "deviceIdentity": self.device_identity, "config": self.config.to_dict(), "verifiedLevels": sorted(self.verified),
            "intentEnabled": self.intent_enabled, "manualPaused": self.manual_paused,
            "mode": self.mode, "snapshot": self.snapshot, "expected": self.expected,
        })

    def log(self, text: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.logs.append(f"{stamp} {text}")
        self.status_dirty = True

    def error(self, message: str) -> None:
        self._output({"kind": "error", "message": message})
        self.log(message)

    def _output(self, value: dict[str, Any]) -> None:
        if self.output_closed:
            return
        try:
            print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)
        except (BrokenPipeError, OSError):
            self.output_closed = True
            self.shutdown(preserve_intent=True)
    def _temperature_stale(self) -> bool:
        if self.sensor_received_mono is None or self.sensor_source_wall is None:
            return True
        now_mono = time.monotonic()
        now_wall = time.time()
        return (now_mono - self.sensor_received_mono > self.config.staleSeconds or
                now_wall - self.sensor_source_wall > self.config.staleSeconds or
                self.sensor_source_wall - now_wall > max(5.0, self.config.sampleSeconds))

    def _system_stale(self) -> bool:
        if self.system_received_mono is None or self.system_source_wall is None:
            return True
        now_mono, now_wall = time.monotonic(), time.time()
        limit = max(6.0, HOST_SAMPLE_SECONDS * 3.0)
        return (now_mono - self.system_received_mono > limit or now_wall - self.system_source_wall > limit
                or self.system_source_wall - now_wall > 5.0)

    def can_enable(self) -> bool:
        levels = (self.config.mediumLevel, self.config.highLevel)
        return bool(
            not self.busy and self.mode != "manual" and self.snapshot is None
            and not self._temperature_stale() and self.device_view["reachable"]
            and self.device_view["power"] is True and all(level is not None and level in self.verified for level in levels)
            and levels[0] < levels[1]
        )

    def status(self) -> dict[str, Any]:
        self.temperature["stale"] = self._temperature_stale()
        self.system["stale"] = self._system_stale()
        dwell = [] if self.mode not in ("dryRun", "enabled") or self.temperature["stale"] else self.rule.dwell()
        return {
            "kind": "status", "mode": self.mode, "phase": self.rule.phase, "reason": self.reason,
            "temperature": dict(self.temperature), "system": dict(self.system),
            "device": dict(self.device_view), "account": dict(self.account),
            "owner": self.owner, "busy": self.busy, "canEnable": self.can_enable(), "dwell": dwell,
            "historyError": self.history_error,
            "verifiedLevels": sorted(self.verified), "commandState": self.command_state,
            "commandDetail": self.command_detail, "eventLog": list(self.logs), "config": self.config.to_dict(),
        }

    def emit_status(self, *, force: bool = False) -> None:
        now = time.monotonic()
        if (force or self.status_dirty) and now - self.last_emit >= 1.0:
            self._output(self.status())
            self.last_emit = now
            self.status_dirty = False

    def connect_device(self) -> None:
        try:
            metadata = json.loads(DEVICE_PATH.read_text())
            model = metadata.get("model")
            if not isinstance(model, str) or not isinstance(metadata.get("ip"), str):
                raise ValueError("metadata")
            keyring.set_keyring(Keyring())
            stable_id = metadata.get("id") or metadata.get("credentialId")
            self.history_device_identity = stable_id if isinstance(stable_id, str) and stable_id else None
            token = read_token(metadata)
            if not token:
                raise ValueError("credential")
            self.account.update({
                "paired": True, "label": str(metadata.get("accountLabel") or "米家账号"),
                "region": str(metadata.get("region") or ""), "phase": "idle", "message": "",
            })
            self.device_view.update({
                "model": model, "ip": metadata["ip"], "name": str(metadata.get("name") or model),
                **_catalog_presentation(model), "supported": model in MODELS,
                "supportDescription": "SDK 协议兼容，正在核验本地状态" if model in MODELS else "当前 SDK 不支持此型号协议",
            })
            if model not in MODELS:
                raise PairingError("unsupported_model")
            self.device = AirPurifier(metadata["ip"], token, timeout=3, model=model)
            info = self.device.info()
            if info.model != model:
                raise PairingError("local_model_mismatch")
            self.device_view.update({"firmware": info.firmware_version, "supportDescription": "本地型号与状态已核验"})
            self.poll_device()
            self._reconcile_cold_snapshot()
        except Exception as exception:
            self.device = None
            self.device_view["reachable"] = False
            self.reason = "净化器不可达、型号不支持或凭据无效"
            self.log(f"设备连接失败（{type(exception).__name__}）")

    def poll_device(self, *, check_ownership: bool = True) -> bool:
        if not self.device:
            return False
        self.last_device_poll = time.monotonic()
        was_reachable = self.device_view["reachable"]
        try:
            status = self.device.status()
            mode = status.mode.value if hasattr(status.mode, "value") else str(status.mode)
            self.device_view.update({
                "reachable": True, "power": status.is_on, "mode": mode,
                "level": status.favorite_level, "rpm": status.motor_speed,
            })
            self.device_observed_mono = self.last_device_poll
            self.last_device_poll = time.monotonic()
            if not was_reachable:
                self._history_event("connection", "净化器已连接")
            current = expected_device_state(status.is_on, mode, status.favorite_level)
            if check_ownership and self.owner and not still_owned(self.expected, current):
                was_manual = self.mode == "manual"
                self._history_event("manual", "检测到人工修改，联动已暂停")
                self.owner = False
                self.snapshot = self.expected = None
                self.mode = "paused"
                self.intent_enabled = not was_manual
                self.manual_paused = True
                self.rule = RuleEngine(self.config)
                self.reason = "检测到人工修改，联动已暂停"
                self.log(self.reason)
                self.persist()
            self.status_dirty = True
            return True
        except Exception as exception:
            if was_reachable:
                self._history_event("connection", "净化器连接已中断")
            self.device_view["reachable"] = False
            self.reason = "净化器读取失败，已停止写入"
            self.log(f"设备读取失败（{type(exception).__name__}）")
            if self.owner:
                self.mode = "paused"
                self.manual_paused = True
                self.owner = False
                self.persist()
            return False

    def _current_state(self) -> dict[str, Any]:
        return expected_device_state(bool(self.device_view["power"]), self.device_view["mode"], self.device_view["level"])

    def _reconcile_cold_snapshot(self) -> None:
        if not self.snapshot or not self.expected:
            return
        if still_owned(self.expected, self._current_state()):
            self.owner = True
            if self._restore("重启恢复接管前状态"):
                self.reason = "已核对并恢复上次接管状态，等待重新采样"
        else:
            self.snapshot = self.expected = None
            self.owner = False
            self.mode = "paused"
            self.manual_paused = True
            self.reason = "重启后设备状态已变化，未覆盖并保持暂停"
            self.log(self.reason)
            self.persist()

    def _write_level(self, level: int) -> bool:
        previously_owned = self.owner
        fresh = self.poll_device()
        if previously_owned and not self.owner:
            return False
        if not fresh or self.device_view["power"] is not True:
            self.command_state = "failed"
            self.command_detail = "设备未开启或不可达"
            return False
        if not self.owner:
            self.snapshot = self._current_state()
        expected = expected_device_state(True, "favorite", level)
        # Persist both sides of the conditional restore before the first write. If
        # feedback is lost after a successful device write, a later fresh read can
        # still prove ownership and recover the original state.
        self.expected = expected
        self.persist()
        self.command_state = "sent"
        self.command_detail = f"已发送最爱等级 {level}"
        try:
            if self.device_view["mode"] != "favorite":
                self.device.set_mode(OperationMode.Favorite)
            if self.device_view["level"] != level:
                self.device.set_favorite_level(level)
            if not self.poll_device(check_ownership=False):
                raise RuntimeError("feedback")
            expected = expected_device_state(True, "favorite", level)
            if not still_owned(expected, self._current_state()):
                raise RuntimeError("confirmation")
            self.expected = expected
            self.owner = True
            self.command_state = "confirmed"
            self.command_detail = f"已确认最爱等级 {level}"
            if not previously_owned:
                self._history_event("takeover", "联动已接管净化器档位")
            self.persist()
            return True
        except Exception as exception:
            self.command_state = "unknown"
            self.command_detail = f"调档未确认（{type(exception).__name__}）"
            self.reason = "调档未确认，已暂停以避免重复写入"
            self.mode = "paused"
            self.manual_paused = True
            self.owner = False
            self.log(self.reason)
            self.persist()
            return False

    def set_manual_purifier(self, level: Any) -> None:
        if isinstance(level, bool) or not isinstance(level, int) or not 0 <= level <= 17:
            raise ValueError("手动档位必须是 0 到 17 的整数")
        if self.busy or self.test_session:
            raise ValueError("净化器正在试听或执行其他操作")
        if not self.account["paired"] or self.device is None:
            raise ValueError("请先连接并核验净化器")

        # Manual control is opt-in and never powers the purifier on. The fresh
        # local read also performs the normal conditional-ownership check.
        self.intent_enabled = False
        self.manual_paused = True
        previously_owned = self.owner
        if not self.poll_device() or self.device_view["power"] is not True:
            self.mode = "paused"
            self.reason = "净化器必须已开启且可达，未执行手动调档"
            self.persist()
            raise ValueError(self.reason)
        if previously_owned and not self.owner:
            self.intent_enabled = False
            self.manual_paused = True
            self.persist()
            raise ValueError("检测到外部修改，已让出控制且未执行手动调档")
        if not self._write_level(level):
            # _write_level retains snapshot/expected on an uncertain result so a
            # later read can conditionally recover without claiming success.
            self.intent_enabled = False
            self.manual_paused = True
            self.persist()
            raise ValueError(self.command_detail or "手动调档未确认")

        self.mode = "manual"
        self.intent_enabled = False
        self.manual_paused = True
        self.reason = f"手动净化器档位 {level} 已确认；恢复自动联动需显式启用"
        self.rule = RuleEngine(self.config)
        self.persist()
        self.log(self.reason)
        self._history_event("manual", f"手动净化器档位 {level} 已确认")

    def release_manual_purifier(self) -> None:
        if self.mode != "manual" and not (self.manual_paused and self.snapshot is not None):
            raise ValueError("当前没有可释放的手动净化器控制")
        if self.snapshot is not None:
            self._restore("结束手动控制恢复")
            if self.snapshot is not None:
                # Restoration was not confirmed. Keep all recovery evidence and
                # fail this command rather than acknowledging a false release.
                self.intent_enabled = False
                self.manual_paused = True
                self.persist()
                raise ValueError(self.command_detail or "结束手动控制的恢复结果未确认")
        self.mode = "paused"
        self.intent_enabled = False
        self.manual_paused = True
        self.rule = RuleEngine(self.config)
        self.reason = "手动净化器控制已结束；自动联动仍保持暂停"
        self.persist()
        self.log(self.reason)

    def _restore_values(self, snapshot: dict[str, Any]) -> bool:
        assert self.device
        mode = snapshot.get("mode")
        level = snapshot.get("level")
        if isinstance(level, int) and self.device_view["level"] != level:
            self.device.set_favorite_level(level)
        if isinstance(mode, str) and self.device_view["mode"] != mode:
            self.device.set_mode(OperationMode(mode))
        if not self.poll_device(check_ownership=False):
            return False
        return still_owned(snapshot, self._current_state())

    def _restore(self, label: str) -> bool:
        if self.snapshot is not None and not self.poll_device(check_ownership=False):
            self.command_state = "unknown"
            self.command_detail = "设备不可达，无法确认恢复；已保留待核对快照"
            self.mode = "paused"
            self.manual_paused = True
            self.persist()
            return False
        if not self.snapshot or not still_owned(self.expected, self._current_state()):
            self.owner = False
            self.snapshot = self.expected = None
            self.command_state = "none"
            self.command_detail = "未持有控制权，未覆盖设备"
            self.persist()
            return False
        self.command_state = "sent"
        self.command_detail = label
        snapshot = self.snapshot
        try:
            if not self._restore_values(snapshot):
                raise RuntimeError("confirmation")
            self.command_state = "confirmed"
            self.command_detail = f"{label}已确认"
            self.owner = False
            self.snapshot = self.expected = None
            self.rule.commit("standby", time.monotonic())
            self.log(self.command_detail)
            self.persist()
            self._history_event("restore", "已确认恢复接管前设备状态")
            return True
        except Exception as exception:
            self.command_state = "unknown"
            self.command_detail = f"恢复未确认（{type(exception).__name__}）"
            self.owner = False
            self.mode = "paused"
            self.manual_paused = True
            self.reason = "无法确认恢复结果，已暂停"
            self.log(self.reason)
            self.persist()
            return False

    @staticmethod
    def _active_percent(value: Any) -> float | None:
        ratio = _finite(value)
        return ratio * 100.0 if ratio is not None and 0.0 <= ratio <= 1.0 else None

    @staticmethod
    def _memory_metrics(payload: Any) -> dict[str, float] | None:
        if not isinstance(payload, dict):
            return None
        values = [_finite(payload.get(key)) for key in ("ram_total", "ram_usage", "swap_total", "swap_usage")]
        if any(value is None or value < 0 for value in values):
            return None
        return {
            "totalBytes": values[0], "usedBytes": values[1],
            "swapTotalBytes": values[2], "swapUsedBytes": values[3],
        }

    @staticmethod
    def _fan_metrics(payload: Any) -> list[dict[str, Any]]:
        if not isinstance(payload, list):
            return []
        fans: list[dict[str, Any]] = []
        for item in payload:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                continue
            rpm, maximum = _finite(item.get("rpm")), _finite(item.get("max_rpm"))
            if rpm is None or rpm < 0:
                continue
            fans.append({"name": item["name"], "rpm": rpm,
                         "maxRPM": maximum if maximum is not None and maximum >= 0 else None})
        return fans

    def _history_event(self, kind: str, label: str, *, device: bool = True) -> None:
        if self.history is None:
            return
        try:
            self.history.record_event(
                timestamp=time.time(), kind=kind, label=label,
                device_id=self.history_device_identity if device else None,
            )
            self.history_error = None
        except Exception as exception:
            self.history_error = f"历史事件写入失败（{type(exception).__name__}）"

    def _record_history(self, *, timestamp: float, cpu: float | None, gpu: float | None,
                        cpu_load: float | None, now_mono: float) -> None:
        if self.history is None:
            return
        device_fresh = bool(
            self.history_device_identity and self.account["paired"] and self.device_view["reachable"]
            and self.device_observed_mono is not None
            and now_mono - self.device_observed_mono <= max(5.0, self.config.sampleSeconds * 1.5)
        )
        identity = self.history_device_identity if device_fresh else None
        signature = (identity, self.mode, self.owner if device_fresh else False, self.rule.phase,
                     self.system["memoryPressure"], self.system["thermalState"])
        due = (self.last_history_timestamp is None or timestamp - self.last_history_timestamp >= HISTORY_SAMPLE_SECONDS
               or signature != self.last_history_signature)
        if not due:
            return
        memory = self.system["memory"]
        try:
            self.history.record(
                timestamp=timestamp, device_id=identity, session_id=self.history_session,
                cpu=cpu, gpu=gpu, cpu_load=cpu_load, gpu_load=self.system["gpuLoad"],
                memory_used=memory["usedBytes"] if memory else None,
                memory_total=memory["totalBytes"] if memory else None,
                swap_used=memory["swapUsedBytes"] if memory else None,
                memory_pressure=self.system["memoryPressure"], thermal_state=self.system["thermalState"],
                mac_fans=self.system["fans"], rpm=self.device_view["rpm"] if device_fresh else None,
                level=self.device_view["level"] if device_fresh else None,
                device_mode=self.device_view["mode"] if device_fresh else None,
                worker_mode=self.mode, owner=self.owner if device_fresh else False, phase=self.rule.phase,
                sample_interval=HISTORY_SAMPLE_SECONDS,
            )
            self.last_history_timestamp, self.last_history_signature = timestamp, signature
            self.history_error = None
        except Exception as exception:
            self.history_error = f"历史记录写入失败（{type(exception).__name__}）"

    def _break_history_segment(self) -> None:
        if self.history is not None:
            self.history.break_segment()
        self.last_history_signature = None

    def handle_sensor(self, payload: Any) -> None:
        now_mono, now_wall = time.monotonic(), time.time()
        cpu = gpu = cpu_load = timestamp = None
        gpu_load = None
        memory = None
        fans: list[dict[str, Any]] = []
        if isinstance(payload, dict):
            timestamp = _source_timestamp(payload.get("timestamp"))
            temp = payload.get("temp")
            if isinstance(temp, dict):
                cpu = _finite(temp.get("cpu_temp_avg"))
                gpu = _finite(temp.get("gpu_temp_avg"))
            cpu_load = self._active_percent(payload.get("cpu_active_ratio"))
            gpu_load = self._active_percent(payload.get("gpu_active_ratio"))
            memory = self._memory_metrics(payload.get("memory"))
            fans = self._fan_metrics(payload.get("fans"))
        try:
            conditions = read_system_conditions()
        except Exception:
            conditions = {}
        pressure = conditions.get("memoryPressure") if isinstance(conditions, dict) else None
        thermal = conditions.get("thermalState") if isinstance(conditions, dict) else None
        pressure = pressure if pressure in ("normal", "warning", "critical") else None
        thermal = thermal if thermal in ("nominal", "fair", "serious", "critical") else None
        host_valid = timestamp is not None and any(
            value is not None for value in (cpu, gpu, cpu_load, gpu_load, memory, pressure, thermal)
        ) or bool(timestamp is not None and fans)
        if host_valid:
            self.system = {
                "timestamp": timestamp, "stale": False, "gpuLoad": gpu_load, "memory": memory,
                "memoryPressure": pressure, "thermalState": thermal, "fans": fans,
            }
            self.system_received_mono, self.system_source_wall = now_mono, timestamp
            self.system["stale"] = self._system_stale()
            if not self.system["stale"]:
                self._record_history(timestamp=timestamp, cpu=cpu, gpu=gpu, cpu_load=cpu_load, now_mono=now_mono)

        if self.last_wall is not None and self.last_mono is not None:
            wall_step, mono_step = now_wall - self.last_wall, now_mono - self.last_mono
            if mono_step < 0 or abs(wall_step - mono_step) > 2.0 or mono_step > max(6.0, HOST_SAMPLE_SECONDS * 3.0):
                self.rule.reset_dwell()
                self._break_history_segment()
                self._history_event("wake", "Mac 已从休眠或时钟跳变中恢复", device=False)
                self.log("检测到休眠或时钟跳变，已重置持续计时")
        self.last_wall, self.last_mono = now_wall, now_mono

        if cpu is None or timestamp is None:
            self._break_history_segment()
            self.rule.reset_dwell()
            if self._temperature_stale() and self.owner:
                self._restore("温度过期恢复")
            self.temperature["stale"] = True
            self.reason = "温度样本无效，未推进持续计时"
            self.status_dirty = True
            return
        self.sensor_received_mono, self.sensor_source_wall = now_mono, timestamp
        self.temperature = {"cpu": cpu, "gpu": gpu, "cpuLoad": cpu_load, "timestamp": timestamp, "stale": False}
        stale = self._temperature_stale()
        self.temperature["stale"] = stale
        if stale:
            self.rule.reset_dwell()
            self._break_history_segment()
            if self.owner:
                self._restore("温度过期恢复")
            self.reason = "温度样本已过期"
        elif self.mode in ("dryRun", "enabled") and not self.busy:
            decision = self.rule.update(cpu, now_mono)
            if decision:
                if self.mode == "dryRun":
                    self.command_state = "planned"
                    self.command_detail = decision.reason
                    self.rule.commit(decision.target, now_mono)
                    self.reason = decision.reason.replace("计划", "仅演练计划")
                    self.log(self.reason)
                elif decision.target == "standby":
                    self._restore("降温退出恢复")
                    self.reason = "温度已回落，退出接管"
                else:
                    level = self.config.mediumLevel if decision.target == "medium" else self.config.highLevel
                    if level is not None and self._write_level(level):
                        self.rule.commit(decision.target, now_mono)
                        self.reason = "已进入中档" if decision.target == "medium" else "已进入高档"
                        self.log(self.reason)
        self.status_dirty = True
        

    def _prepare_account_change(self) -> None:
        if self.test_session:
            self.finish_test(interrupted=True)
        if self.snapshot is not None:
            self._restore("切换账号前恢复")
        if self.snapshot is not None:
            raise ValueError("设备恢复结果未决，不能切换账号或删除凭据")
        self.mode, self.intent_enabled, self.manual_paused = "stopped", False, False
        self.rule = RuleEngine(self.config)
        self.persist()


    def begin_pairing(self, region: Any) -> None:
        if not isinstance(region, str):
            raise ValueError("米家地区无效")
        self._prepare_account_change()
        self.cancel_pairing(quiet=True)
        session: PairingSession
        session = PairingSession(
            region,
            lambda phase, fields: self.events.put(("pairing", {"session": session, "phase": phase, **{
                key: fields.get(key) for key in ("message", "qrImagePath", "expiresAt") if key in fields
            }})),
        )
        self.pairing = session
        self.account.update({
            "region": region, "phase": "requesting", "message": "正在请求米家登录二维码",
            "qrImagePath": None, "expiresAt": None, "devices": [],
        })
        self.busy = True

        def authorize() -> None:
            try:
                devices = session.run()
                if session.cancelled.is_set():
                    raise PairingError("cancelled")
                for device in devices:
                    device.update(_catalog_presentation(device["model"]))
                self.events.put(("pairing", {
                    "session": session, "phase": "choosingDevice",
                    "message": "请选择要连接的净化器", "devices": devices,
                }))
            except PairingError as error:
                phase = "idle" if str(error) == "cancelled" else "error"
                self.events.put(("pairing", {"session": session, "phase": phase, "message": self._pairing_message(str(error))}))
            except Exception as error:
                phase = "idle" if session.cancelled.is_set() else "error"
                message = "已取消登录" if phase == "idle" else f"登录失败（{type(error).__name__}）"
                self.events.put(("pairing", {"session": session, "phase": phase, "message": message}))

        self.pairing_thread = threading.Thread(target=authorize, name="xiaomi-qr-pairing", daemon=True)
        self.pairing_thread.start()
        self.status_dirty = True

    @staticmethod
    def _pairing_message(code: str) -> str:
        return {
            "cancelled": "已取消登录",
            "qr_expired": "二维码已过期，请重试",
            "unsupported_model": "此型号协议不受支持",
            "local_model_mismatch": "本地设备型号与云端记录不一致",
            "local_token_unavailable": "米家未提供可用的本地凭据",
            "local_address_invalid": "设备没有可用的局域网地址",
        }.get(code, "米家登录或设备读取失败")

    def cancel_pairing(self, *, quiet: bool = False) -> None:
        if self.pairing is not None:
            self.pairing.cancel()
            self.pairing = None
        self.busy = False
        if not quiet:
            self.account.update({
                "phase": "idle", "message": "已取消登录", "qrImagePath": None,
                "expiresAt": None, "devices": [],
            })
        self.status_dirty = True

    def select_device(self, device_id: Any) -> None:
        session = self.pairing
        if not isinstance(device_id, str) or session is None or self.account["phase"] != "choosingDevice":
            raise ValueError("当前没有可选择的设备")
        self.account.update({"phase": "connecting", "message": "正在核验局域网设备", "qrImagePath": None, "expiresAt": None})
        self.busy = True

        def validate() -> None:
            try:
                metadata, token = session.candidate_secret(device_id)
                checked = verify_candidate(metadata, token)
                self.events.put(("pair_selection", {"session": session, "metadata": metadata, "token": token, "checked": checked}))
            except PairingError as error:
                self.events.put(("pairing", {"session": session, "phase": "error", "message": self._pairing_message(str(error))}))
            except Exception as error:
                phase = "idle" if session.cancelled.is_set() else "error"
                message = "已取消登录" if phase == "idle" else f"本地核验失败（{type(error).__name__}）"
                self.events.put(("pairing", {"session": session, "phase": phase, "message": message}))

        self.pairing_thread = threading.Thread(target=validate, name="xiaomi-device-validation", daemon=True)
        self.pairing_thread.start()

    def _apply_selection(self, payload: dict[str, Any]) -> None:
        metadata, token, checked = payload["metadata"], payload["token"], payload["checked"]
        old_metadata: dict[str, Any] = {}
        try:
            old_metadata = json.loads(DEVICE_PATH.read_text())
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            pass
        old_token = read_token(old_metadata)
        preserve_calibration = old_metadata.get("model") == metadata["model"] and old_token == token
        metadata = commit_credentials(metadata, token, path=DEVICE_PATH, keyring_module=keyring)
        self.device_identity = metadata["credentialId"]
        stable_id = metadata.get("id") or metadata.get("credentialId")
        self.history_session = uuid.uuid4().hex
        self.history_device_identity = stable_id if isinstance(stable_id, str) and stable_id else None
        if not preserve_calibration:
            self.verified.clear()
            self.config = replace(self.config, mediumLevel=None, highLevel=None)
            self.rule = RuleEngine(self.config)
        self.device = checked["purifier"]
        status = checked["status"]
        mode = status.mode.value if hasattr(status.mode, "value") else str(status.mode)
        self.device_view.update({
            "reachable": True, "power": status.is_on, "mode": mode, "level": status.favorite_level,
            "rpm": status.motor_speed, "model": metadata["model"], "firmware": checked["firmware"],
            "ip": metadata["ip"], "name": metadata["name"], **_catalog_presentation(metadata["model"]),
            "supported": True, "supportDescription": "本地型号与状态已核验",
        })
        self.device_observed_mono = time.monotonic()
        self.account.update({
            "paired": True, "label": metadata.get("accountLabel", "米家账号"), "region": metadata["region"],
            "phase": "idle", "message": "设备已连接；旧凭据将在退出时清理" if metadata.get("credentialCleanupPending") else "设备连接成功", "qrImagePath": None, "expiresAt": None, "devices": [],
        })
        if self.pairing is not None:
            self.pairing.close()
        self.pairing = None
        self.busy = False
        self.persist()
        self.log("设备连接成功")

    def logout(self) -> None:
        self._prepare_account_change()
        self.cancel_pairing(quiet=True)
        delete_local_credentials(path=DEVICE_PATH, keyring_module=keyring)
        self.device = None
        self.verified.clear()
        self.config = replace(self.config, mediumLevel=None, highLevel=None)
        self.device_identity = None
        self.history_device_identity = None
        self.device_observed_mono = None
        self.rule = RuleEngine(self.config)
        self.device_view = {
            "reachable": False, "power": None, "mode": None, "level": None, "rpm": None,
            "model": "", "firmware": "", "ip": "", "name": "", "imageURL": None,
            "productName": None,
            "supported": False, "supportDescription": "尚未选择设备",
        }
        self.account = {
            "paired": False, "label": "", "region": "", "phase": "idle", "message": "已退出本机账号",
            "qrImagePath": None, "expiresAt": None, "devices": [],
        }
        self.persist()
        self.log("已删除本机米家凭据，未从云端解绑设备")
    def configure(self, value: Any) -> None:
        if self.mode == "enabled" or self.busy or self.owner:
            raise ValueError("启用或测试期间不能修改配置")
        new_config = Config.from_dict(value)
        restart_sensor = new_config.sampleSeconds != self.config.sampleSeconds
        self.config = new_config
        self.history_session = uuid.uuid4().hex
        self.rule = RuleEngine(self.config)
        self.persist()
        if restart_sensor:
            assert self.sensor
            self.sensor.stop()
            self.sensor = Sensor(self.events, self.config.sampleSeconds)
            self.sensor.start()
        self.reason = "配置已保存"
        self.log(self.reason)

    def start_test_strategy(self, levels: Any) -> None:
        if not isinstance(levels, list):
            raise ValueError("试听档位必须是数组")
        normalized: list[int] = []
        for level in levels:
            if isinstance(level, bool) or not isinstance(level, int) or not 0 <= level <= 17:
                raise ValueError("试听档位必须是 0–17 的整数")
            if level not in normalized:
                normalized.append(level)
        if not normalized or len(normalized) > 2 or self.mode == "enabled" or self.busy or self.snapshot is not None:
            raise ValueError("最多试听两个档位，且当前必须可安全测试")
        if not self.poll_device() or self.device_view["power"] is not True:
            raise ValueError("净化器必须已开启且可达")
        self.test_session = {"levels": normalized, "index": 0}
        self.busy = True
        self._begin_test_level()

    def start_test(self, level: Any) -> None:
        """Internal single-level entry retained for focused safety tests."""
        self.start_test_strategy([level])

    def _begin_test_level(self) -> None:
        session = self.test_session
        if not session:
            return
        level = session["levels"][session["index"]]
        self.reason = f"正在临时试听等级 {level}（10 秒）"
        self.log(self.reason)
        if not self._write_level(level):
            self.test_session = None
            self.busy = False
            return
        session.update({
            "level": level, "snapshot": dict(self.snapshot), "expected": dict(self.expected),
            "deadline": time.monotonic() + 10.0,
        })
        self.busy = True

    def finish_test(self, *, interrupted: bool = False) -> None:
        session = self.test_session
        if not session or "expected" not in session:
            return
        success = False
        fresh = self.poll_device()
        if fresh and still_owned(session["expected"], self._current_state()):
            try:
                success = self._restore_values(session["snapshot"])
            except Exception as exception:
                self.command_state = "unknown"
                self.command_detail = f"试听恢复未确认（{type(exception).__name__}）"
        else:
            self.command_detail = "试听期间设备被修改，已取消余下试听且未覆盖人工状态"
        if success and not interrupted:
            self.verified.add(session["level"])
            self.command_state = "confirmed"
            self.command_detail = f"等级 {session['level']} 试听及恢复均已确认"
        elif not success:
            self.command_state = "unknown"
        self.owner = False
        if success:
            self.snapshot = self.expected = None
        self.rule.reset_dwell()
        has_next = success and not interrupted and session["index"] + 1 < len(session["levels"])
        if has_next:
            session["index"] += 1
            for key in ("level", "snapshot", "expected", "deadline"):
                session.pop(key, None)
            self.persist()
            self._begin_test_level()
            return
        self.test_session = None
        self.busy = False
        if success and not interrupted:
            self.reason = "试听策略完成"
        elif success:
            self.reason = "试听已中止并恢复"
        else:
            self.reason = "试听已取消；恢复未确认或检测到人工修改"
        self.persist()
        self.log(self.reason)

    def _start_processes(self, request_id: str) -> None:
        if self.processes_pending:
            raise ValueError("已有进程采样正在进行")
        self.processes_pending = True

        def sample() -> None:
            response: dict[str, Any] = {
                "kind": "processes", "requestId": request_id, "timestamp": None,
                "processes": [], "error": None,
            }
            try:
                raw = sample_top_processes()
                if not isinstance(raw, dict):
                    raise TypeError("result")
                response["timestamp"] = _finite(raw.get("timestamp"))
                processes: list[dict[str, Any]] = []
                source = raw.get("processes")
                if isinstance(source, list):
                    for item in source[:3]:
                        if not isinstance(item, dict):
                            continue
                        pid, name, cpu = item.get("pid"), item.get("name"), _finite(item.get("cpuPercent"))
                        if (not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0
                                or not isinstance(name, str) or not name.strip() or cpu is None or cpu < 0):
                            continue
                        processes.append({
                            "pid": pid, "name": name.strip().rsplit("/", 1)[-1], "cpuPercent": cpu,
                        })
                response["processes"] = processes
                if raw.get("error") is not None:
                    response["error"] = "进程采样不可用"
            except Exception:
                response["error"] = "进程采样不可用"
            self.events.put(("processes", response))

        try:
            threading.Thread(target=sample, name="process-sampler", daemon=True).start()
        except Exception:
            self.processes_pending = False
            raise

    def _history_response(self, command: dict[str, Any]) -> None:
        hours = command.get("hours", 24.0)
        if isinstance(hours, bool) or not isinstance(hours, (int, float)) or not math.isfinite(hours):
            raise ValueError("历史时长无效")
        request_id = command.get("id")
        if not isinstance(request_id, str) or not request_id:
            raise ValueError("命令 ID 无效")
        if self.history is None:
            result = {
                "hours": min(max(float(hours), 1.0), 720.0), "retentionDays": 30,
                "totalSamples": 0, "recordingSince": None, "points": [], "events": [],
                "comparison": None, "error": self.history_error,
            }
        else:
            try:
                result = self.history.snapshot(device_id=self.history_device_identity, hours=float(hours))
                self.history_error = None
            except Exception as exception:
                self.history_error = f"历史记录读取失败（{type(exception).__name__}）"
                result = {
                    "hours": min(max(float(hours), 1.0), 720.0), "retentionDays": 30,
                    "totalSamples": 0, "recordingSince": None, "points": [], "events": [],
                    "comparison": None, "error": self.history_error,
                }
        self._output({"kind": "history", "requestId": request_id, **result})

    def _clear_history(self) -> None:
        if self.history is None:
            raise RuntimeError(self.history_error or "历史记录不可用")
        self.history.clear()
        self.last_history_timestamp = None
        self.last_history_signature = None
        self.history_error = None

    def handle_command(self, command: Any) -> None:
        if not isinstance(command, dict) or not isinstance(command.get("op"), str):
            raise ValueError("命令格式无效")
        op = command["op"]
        if op == "configure":
            self.configure(command.get("config"))
        elif op == "enable":
            if self.mode == "manual":
                self.release_manual_purifier()
            if not self.can_enable():
                raise ValueError("传感器、设备、已验证档位或恢复状态尚未满足启用条件")
            self.mode = "enabled"
            self.intent_enabled = True
            self.manual_paused = False
            self.rule = RuleEngine(self.config)
            self.reason = "联动已启用，等待连续温度条件"
            self.persist()
            self.log(self.reason)
            self._history_event("enable", "联动已启用")
        elif op == "dryRun":
            if self.test_session:
                self.finish_test(interrupted=True)
            if self.snapshot is not None:
                self._restore("切换仅演练前恢复")
            self.mode, self.intent_enabled, self.manual_paused = "dryRun", False, False
            self.rule = RuleEngine(self.config)
            self.reason = "仅演练模式，不会写入设备"
            self.persist()
            self.log(self.reason)
        elif op == "pause":
            if self.test_session:
                self.finish_test(interrupted=True)
            if self.snapshot is not None:
                self._restore("人工暂停恢复")
            self.mode, self.intent_enabled, self.manual_paused = "paused", True, True
            self.rule = RuleEngine(self.config)
            self.reason = "已人工暂停，需要显式恢复"
            self.persist()
            self.log(self.reason)
            self._history_event("pause", "联动已人工暂停")
        elif op == "stop":
            if self.test_session:
                self.finish_test(interrupted=True)
            if self.snapshot is not None:
                self._restore("停止联动恢复")
            self.mode, self.intent_enabled, self.manual_paused = "stopped", False, False
            self.rule = RuleEngine(self.config)
            self.reason = "联动已停止"
            self.persist()
            self.log(self.reason)
            self._history_event("stop", "联动已停止")
        elif op == "refresh":
            if self.device is None:
                self.connect_device()
            else:
                self.poll_device()
            self.reason = "状态已刷新" if self.device_view["reachable"] else "设备刷新失败"
        elif op == "testStrategy":
            self.start_test_strategy(command.get("levels"))
        elif op == "manualPurifier":
            if set(command) != {"id", "op", "level"}:
                raise ValueError("手动净化器命令只接受档位")
            self.set_manual_purifier(command["level"])
        elif op == "releaseManualPurifier":
            if set(command) != {"id", "op"}:
                raise ValueError("释放手动净化器命令不接受参数")
            self.release_manual_purifier()
        elif op == "beginPairing":
            self.begin_pairing(command.get("region"))
        elif op == "cancelPairing":
            self.cancel_pairing()
        elif op == "selectDevice":
            self.select_device(command.get("deviceId"))
        elif op == "logout":
            self.logout()
        elif op == "history":
            self._history_response(command)
        elif op == "clearHistory":
            self._clear_history()
        elif op == "processes":
            if set(command) != {"id", "op"}:
                raise ValueError("进程采样命令不接受参数")
            self._start_processes(command["id"])
        elif op == "shutdown":
            self.shutdown(preserve_intent=True)
        else:
            raise ValueError("未知命令")
        self.status_dirty = True
    def process_command(self, command: Any) -> None:
        if not isinstance(command, dict) or not isinstance(command.get("id"), str) or not command["id"]:
            self.error("命令格式无效")
            return
        command_id, op = command["id"], command.get("op")
        if not isinstance(op, str):
            self._output({
                "kind": "commandResult", "id": command_id, "op": "", "success": False,
                "message": "命令格式无效", "status": self.status(),
            })
            return
        try:
            self.handle_command(command)
            messages = {
                "history": "历史记录已返回", "clearHistory": "本机历史记录已清除",
                "processes": "进程采样已接受", "beginPairing": "登录流程已启动",
                "selectDevice": "设备核验已启动", "testStrategy": "试听策略已开始",
                "shutdown": "后端正在退出",
            }
            message = messages.get(op, self.reason or "命令已完成")
            self._output({
                "kind": "commandResult", "id": command_id, "op": op, "success": True,
                "message": message, "status": self.status(),
            })
        except (ValueError, TypeError) as exception:
            self._output({
                "kind": "commandResult", "id": command_id, "op": op, "success": False,
                "message": str(exception), "status": self.status(),
            })
        except Exception as exception:
            self._output({
                "kind": "commandResult", "id": command_id, "op": op, "success": False,
                "message": f"命令失败（{type(exception).__name__}）", "status": self.status(),
            })

    def shutdown(self, *, preserve_intent: bool) -> None:
        self.cancel_pairing(quiet=True)
        if self.test_session:
            self.finish_test(interrupted=True)
        if self.snapshot is not None:
            self._restore("退出前恢复")
        if not preserve_intent:
            self.intent_enabled = False
        self.persist()
        self.running = False

    def run(self) -> None:
        self.sensor = Sensor(self.events, HOST_SAMPLE_SECONDS)
        try:
            self.sensor.start()
        except Exception as exception:
            self.error(f"温度采集器启动失败（{type(exception).__name__}）")
        threading.Thread(target=self._read_stdin, name="command-reader", daemon=True).start()
        self.connect_device()
        self.log("后端已启动")
        self.emit_status(force=True)
        while self.running:
            try:
                kind, payload = self.events.get(timeout=0.2)
                if kind == "command":
                    self.process_command(payload)
                elif kind == "pairing":
                    if payload.get("session") is not self.pairing:
                        continue
                    phase = payload.get("phase", "error")
                    self.account.update({
                        "phase": phase, "message": payload.get("message", ""),
                        "qrImagePath": payload.get("qrImagePath"), "expiresAt": payload.get("expiresAt"),
                    })
                    if "devices" in payload:
                        self.account["devices"] = payload["devices"]
                    self.busy = phase in ("requesting", "waitingForScan", "loadingDevices", "connecting")
                    if phase in ("idle", "error"):
                        if self.pairing is not None:
                            self.pairing.close()
                        self.pairing = None
                    self.status_dirty = True
                elif kind == "pair_selection":
                    if payload.get("session") is not self.pairing:
                        continue
                    try:
                        self._apply_selection(payload)
                    except Exception as exception:
                        self.account.update({"phase": "error", "message": f"保存设备失败（{type(exception).__name__}）"})
                        self.busy = False
                        self.status_dirty = True
                        if self.pairing is not None:
                            self.pairing.close()
                        self.pairing = None
                elif kind == "sensor":
                    self.handle_sensor(payload)
                elif kind == "processes":
                    self.processes_pending = False
                    self._output(payload)
                elif kind == "sensor_error":
                    self.rule.reset_dwell()
                    self.temperature["stale"] = True
                    self.system["stale"] = True
                    self.reason = "温度采集已中断"
                    self._break_history_segment()
                    self.status_dirty = True
                elif kind == "eof":
                    self.shutdown(preserve_intent=True)
                elif kind == "signal":
                    self.shutdown(preserve_intent=True)
            except queue.Empty:
                pass
            if self.test_session and self.test_session.get("deadline") is not None and time.monotonic() >= self.test_session["deadline"]:
                self.finish_test()
            if time.monotonic() - self.last_device_poll >= max(5.0, self.config.sampleSeconds):
                self.poll_device()
            if self._temperature_stale() and (not self.temperature["stale"] or self.owner):
                self.temperature["stale"] = True
                self._break_history_segment()
                self.rule.reset_dwell()
                if self.owner:
                    self._restore("温度过期恢复")
                self.reason = "温度数据已过期，已停止决策"
                self.status_dirty = True
            self.emit_status()
        if self.sensor:
            self.sensor.stop()
        self.emit_status(force=True)

    def _read_stdin(self) -> None:
        for line in sys.stdin:
            try:
                self.events.put(("command", json.loads(line)))
            except json.JSONDecodeError:
                self.events.put(("command", None))
        self.events.put(("eof", None))


def main() -> int:
    os.umask(0o077)
    LOCAL.mkdir(mode=0o700, parents=True, exist_ok=True)
    LOCAL.chmod(0o700)
    # Force macOS Keychain; never permit keyring's plaintext fallback backends.
    keyring.set_keyring(Keyring())
    lock = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(json.dumps({"kind": "error", "message": "已有后端实例正在运行"}, ensure_ascii=False), flush=True)
        return 2
    worker = Worker()
    def request_stop(_signum: int, _frame: Any) -> None:
        worker.events.put(("signal", None))
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    worker.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
