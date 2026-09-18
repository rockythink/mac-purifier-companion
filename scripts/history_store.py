"""Bounded local SQLite storage for host and cooling observations."""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
import json
import math
from pathlib import Path
import sqlite3
import threading
import time
from typing import Any, Iterable
import uuid

RETENTION_DAYS = 30
MAX_CHART_POINTS = 720
MAX_QUERY_SAMPLES = 150_000
MAX_EVENTS = 200
MIN_COMPARISON_SECONDS = 300.0
MIN_COVERAGE = 0.8
EVENT_KINDS = frozenset({"enable", "pause", "stop", "takeover", "restore", "manual", "wake", "connection"})


@dataclass(frozen=True)
class Sample:
    timestamp: float
    device_id: str | None
    cpu: float | None
    gpu: float | None
    cpu_load: float | None
    gpu_load: float | None
    memory_used: float | None
    memory_total: float | None
    swap_used: float | None
    memory_pressure: str | None
    thermal_state: str | None
    mac_fans: list[dict[str, Any]]
    rpm: float | None
    level: int | None
    device_mode: str | None
    mode: str
    owner: bool
    segment: str
    session: str
    phase: str
    interval: float


class HistoryStore:
    """Stores host/device observations; credentials never enter this schema."""

    _sample_columns = (
        "timestamp", "device_id", "session_id", "cpu", "gpu", "cpu_load", "gpu_load",
        "memory_used", "memory_total", "swap_used", "memory_pressure", "thermal_state",
        "mac_fans", "rpm", "level", "device_mode", "worker_mode", "owner", "phase",
        "segment", "sample_interval",
    )

    def __init__(self, path: Path, *, retention_days: int = RETENTION_DAYS) -> None:
        self.path = path
        self.retention_days = retention_days
        self._lock = threading.Lock()
        self._last_key: tuple[str | None, str, str, str, bool] | None = None
        self._last_timestamp: float | None = None
        self._segment_number = 0
        self._last_prune: float | None = None
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.parent.chmod(0o700)
        with closing(self._connect()) as database:
            self._initialize(database)
            cutoff = time.time() - retention_days * 86400
            with database:
                database.execute("DELETE FROM samples WHERE timestamp < ?", (cutoff,))
                database.execute("DELETE FROM events WHERE timestamp < ?", (cutoff,))
        self.path.chmod(0o600)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=0.05)
        connection.execute("PRAGMA busy_timeout=50")
        connection.execute("PRAGMA secure_delete=ON")
        return connection

    @staticmethod
    def _create_samples(database: sqlite3.Connection, name: str = "samples") -> None:
        database.execute(f"""CREATE TABLE {name} (
            timestamp REAL NOT NULL,
            device_id TEXT,
            session_id TEXT NOT NULL,
            cpu REAL,
            gpu REAL,
            cpu_load REAL,
            gpu_load REAL,
            memory_used REAL,
            memory_total REAL,
            swap_used REAL,
            memory_pressure TEXT,
            thermal_state TEXT,
            mac_fans TEXT NOT NULL DEFAULT '[]',
            rpm REAL,
            level INTEGER,
            device_mode TEXT,
            worker_mode TEXT NOT NULL,
            owner INTEGER NOT NULL,
            phase TEXT NOT NULL,
            segment TEXT NOT NULL,
            sample_interval REAL NOT NULL
        )""")

    def _initialize(self, database: sqlite3.Connection) -> None:
        """Create or atomically migrate the legacy schema without risking source rows."""
        database.execute("BEGIN IMMEDIATE")
        try:
            exists = database.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='samples'"
            ).fetchone()
            if not exists:
                self._create_samples(database)
            else:
                info = database.execute("PRAGMA table_info(samples)").fetchall()
                columns = {row[1]: row for row in info}
                current = all(column in columns for column in self._sample_columns)
                nullable_identity = current and columns["device_id"][3] == 0 and columns["cpu"][3] == 0
                if not nullable_identity:
                    self._create_samples(database, "samples_migrating")
                    expressions: list[str] = []
                    defaults = {
                        "timestamp": "0", "device_id": "NULL", "session_id": "''", "cpu": "NULL",
                        "gpu": "NULL", "cpu_load": "NULL", "gpu_load": "NULL", "memory_used": "NULL",
                        "memory_total": "NULL", "swap_used": "NULL", "memory_pressure": "NULL",
                        "thermal_state": "NULL", "mac_fans": "'[]'", "rpm": "NULL", "level": "NULL",
                        "device_mode": "NULL", "worker_mode": "'stopped'", "owner": "0", "phase": "'standby'",
                        "segment": "''", "sample_interval": "20.0",
                    }
                    for column in self._sample_columns:
                        expressions.append(column if column in columns else defaults[column])
                    database.execute(
                        f"INSERT INTO samples_migrating ({','.join(self._sample_columns)}) "
                        f"SELECT {','.join(expressions)} FROM samples"
                    )
                    database.execute("DROP TABLE samples")
                    database.execute("ALTER TABLE samples_migrating RENAME TO samples")
            database.execute("""CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                label TEXT NOT NULL,
                device_id TEXT
            )""")
            database.execute("CREATE INDEX IF NOT EXISTS samples_time ON samples(timestamp)")
            database.execute("CREATE INDEX IF NOT EXISTS samples_device_time ON samples(device_id, timestamp)")
            database.execute("CREATE INDEX IF NOT EXISTS events_time ON events(timestamp)")
            database.execute("PRAGMA user_version=2")
            database.commit()
        except Exception:
            database.rollback()
            raise

    @staticmethod
    def _optional_number(value: Any) -> float | None:
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return None
        return float(value)

    def record(
        self, *, timestamp: float, device_id: str | None, session_id: str,
        cpu: float | None, gpu: float | None, cpu_load: float | None,
        gpu_load: float | None = None, memory_used: float | None = None,
        memory_total: float | None = None, swap_used: float | None = None,
        memory_pressure: str | None = None, thermal_state: str | None = None,
        mac_fans: list[dict[str, Any]] | None = None, rpm: float | None,
        level: int | None, device_mode: str | None, worker_mode: str,
        owner: bool, phase: str, sample_interval: float, now: float | None = None,
    ) -> None:
        """Record one real host sample, optionally paired with a fresh device observation."""
        if not session_id or not math.isfinite(timestamp):
            raise ValueError("invalid history sample")
        interval = sample_interval if math.isfinite(sample_interval) and sample_interval > 0 else 20.0
        cpu_value = self._optional_number(cpu)
        gpu_value = self._optional_number(gpu)
        load = self._percentage(cpu_load)
        gpu_load_value = self._percentage(gpu_load)
        memory_used_value = self._nonnegative(memory_used)
        memory_total_value = self._nonnegative(memory_total)
        swap_used_value = self._nonnegative(swap_used)
        pressure = memory_pressure if memory_pressure in ("normal", "warning", "critical") else None
        thermal = thermal_state if thermal_state in ("nominal", "fair", "serious", "critical") else None
        fans = self._fans(mac_fans)
        rpm_value = self._optional_number(rpm)
        level_value = level if isinstance(level, int) and not isinstance(level, bool) else None
        mode_value = device_mode if isinstance(device_mode, str) else None
        identity = device_id if isinstance(device_id, str) and device_id else None
        key = (identity, session_id, phase, worker_mode, bool(owner))
        gap_limit = max(60.0, interval * 2.5)
        with self._lock:
            if (self._last_key != key or self._last_timestamp is None
                    or timestamp <= self._last_timestamp or timestamp - self._last_timestamp > gap_limit):
                self._segment_number += 1
            segment = f"{session_id}:{self._segment_number}"
            cutoff = (time.time() if now is None else now) - self.retention_days * 86400
            values = (
                timestamp, identity, session_id, cpu_value, gpu_value, load, gpu_load_value,
                memory_used_value, memory_total_value, swap_used_value, pressure, thermal,
                json.dumps(fans, separators=(",", ":")), rpm_value, level_value, mode_value,
                worker_mode, int(bool(owner)), phase, segment, interval,
            )
            with closing(self._connect()) as database, database:
                if self._last_prune is None or cutoff - self._last_prune >= 3600.0:
                    database.execute("DELETE FROM samples WHERE timestamp < ?", (cutoff,))
                    database.execute("DELETE FROM events WHERE timestamp < ?", (cutoff,))
                    self._last_prune = cutoff
                database.execute(
                    f"INSERT INTO samples ({','.join(self._sample_columns)}) VALUES ({','.join('?' for _ in values)})",
                    values,
                )
            self._last_key = key
            self._last_timestamp = timestamp

    @classmethod
    def _percentage(cls, value: Any) -> float | None:
        number = cls._optional_number(value)
        return number if number is not None and 0 <= number <= 100 else None

    @classmethod
    def _nonnegative(cls, value: Any) -> float | None:
        number = cls._optional_number(value)
        return number if number is not None and number >= 0 else None

    @classmethod
    def _fans(cls, value: Any) -> list[dict[str, Any]]:
        if not isinstance(value, list):
            return []
        result: list[dict[str, Any]] = []
        for item in value:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                continue
            rpm = cls._nonnegative(item.get("rpm"))
            maximum = cls._nonnegative(item.get("maxRPM"))
            if rpm is None:
                continue
            result.append({"name": item["name"], "rpm": rpm, "maxRPM": maximum})
        return result

    def record_event(self, *, timestamp: float, kind: str, label: str, device_id: str | None = None,
                     now: float | None = None) -> None:
        if not math.isfinite(timestamp) or kind not in EVENT_KINDS or not isinstance(label, str) or not label:
            raise ValueError("invalid history event")
        identity = device_id if isinstance(device_id, str) and device_id else None
        cutoff = (time.time() if now is None else now) - self.retention_days * 86400
        with self._lock, closing(self._connect()) as database, database:
            database.execute("DELETE FROM events WHERE timestamp < ?", (cutoff,))
            database.execute(
                "INSERT INTO events VALUES (?, ?, ?, ?, ?)",
                (uuid.uuid4().hex, timestamp, kind, label, identity),
            )

    def clear(self) -> None:
        with self._lock:
            with closing(self._connect()) as database, database:
                database.execute("DELETE FROM samples")
                database.execute("DELETE FROM events")
            self._last_key = None
            self._last_timestamp = None
            self._segment_number += 1

    def break_segment(self) -> None:
        with self._lock:
            self._last_key = None
            self._last_timestamp = None

    def snapshot(self, *, device_id: str | None, hours: float, now: float | None = None) -> dict[str, Any]:
        if isinstance(hours, bool) or not isinstance(hours, (int, float)) or not math.isfinite(hours):
            raise ValueError("invalid history query")
        selected_device = device_id if isinstance(device_id, str) and device_id else None
        bounded_hours = min(max(float(hours), 1.0), self.retention_days * 24.0)
        end = time.time() if now is None else now
        start = end - bounded_hours * 3600
        select = """SELECT timestamp, device_id, cpu, gpu, cpu_load, gpu_load, memory_used,
                    memory_total, swap_used, memory_pressure, thermal_state, mac_fans, rpm, level,
                    device_mode, worker_mode, owner, segment, session_id, phase, sample_interval
                    FROM samples WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp DESC LIMIT ?"""
        with self._lock, closing(self._connect()) as database:
            total = int(database.execute(
                "SELECT COUNT(*) FROM samples WHERE timestamp BETWEEN ? AND ?", (start, end)
            ).fetchone()[0])
            recording_since = database.execute("SELECT MIN(timestamp) FROM samples").fetchone()[0]
            rows = database.execute(select, (start, end, MAX_QUERY_SAMPLES)).fetchall()
            event_rows = database.execute(
                "SELECT id,timestamp,kind,label,device_id FROM events WHERE timestamp BETWEEN ? AND ? "
                "ORDER BY timestamp DESC LIMIT ?", (start, end, MAX_EVENTS),
            ).fetchall()
        samples = [self._sample(row) for row in reversed(rows)]
        comparison_samples = [sample for sample in samples if selected_device is not None and sample.device_id == selected_device]
        return {
            "hours": bounded_hours, "retentionDays": self.retention_days, "totalSamples": total,
            "selectedDeviceId": selected_device,
            "recordingSince": recording_since, "points": [self._point(sample) for sample in self._downsample(samples, MAX_CHART_POINTS)],
            "comparison": self._comparison(comparison_samples), "events": [
                {"id": row[0], "timestamp": row[1], "kind": row[2], "label": row[3], "deviceId": row[4]}
                for row in reversed(event_rows)
            ], "error": None,
        }

    @staticmethod
    def _sample(row: tuple[Any, ...]) -> Sample:
        values = list(row)
        try:
            fans = json.loads(values[11])
        except (TypeError, ValueError, json.JSONDecodeError):
            fans = []
        values[11] = fans if isinstance(fans, list) else []
        values[16] = bool(values[16])
        return Sample(*values)

    @staticmethod
    def _point(sample: Sample) -> dict[str, Any]:
        return {
            "timestamp": sample.timestamp, "cpu": sample.cpu, "gpu": sample.gpu,
            "cpuLoad": sample.cpu_load, "rpm": sample.rpm, "level": sample.level,
            "deviceMode": sample.device_mode, "mode": sample.mode, "owner": bool(sample.owner),
            "segment": sample.segment, "gpuLoad": sample.gpu_load, "memoryUsed": sample.memory_used,
            "memoryTotal": sample.memory_total, "swapUsed": sample.swap_used,
            "memoryPressure": sample.memory_pressure, "thermalState": sample.thermal_state,
            "macFans": sample.mac_fans, "deviceId": sample.device_id,
        }

    @staticmethod
    def _downsample(samples: list[Sample], limit: int) -> list[Sample]:
        if len(samples) <= limit:
            return samples
        groups: list[list[Sample]] = []
        for sample in samples:
            if not groups or groups[-1][-1].segment != sample.segment:
                groups.append([])
            groups[-1].append(sample)
        if len(groups) >= limit:
            return [group[-1] for group in groups[-limit:]]
        selected: list[Sample] = []
        remaining = limit
        remaining_weight = sum(len(group) for group in groups)
        for index, group in enumerate(groups):
            groups_left = len(groups) - index - 1
            minimum = 2 if len(group) > 1 else 1
            allocation = min(len(group), max(minimum, round(remaining * len(group) / remaining_weight)))
            allocation = min(allocation, remaining - groups_left)
            if allocation >= len(group):
                selected.extend(group)
            elif allocation == 1:
                selected.append(group[-1])
            else:
                indices = {round(position * (len(group) - 1) / (allocation - 1)) for position in range(allocation)}
                selected.extend(group[position] for position in sorted(indices))
            remaining -= allocation
            remaining_weight -= len(group)
        return selected[:limit]

    @classmethod
    def _comparison(cls, samples: list[Sample]) -> dict[str, Any] | None:
        usable = [sample for sample in samples if sample.cpu is not None]
        runs: list[list[Sample]] = []
        for sample in usable:
            if not (sample.owner and sample.mode == "enabled"):
                continue
            if (not runs or runs[-1][-1].segment != sample.segment or runs[-1][-1].session != sample.session):
                runs.append([])
            runs[-1].append(sample)
        for owned in reversed(runs):
            if owned[-1].timestamp - owned[0].timestamp < MIN_COMPARISON_SECONDS:
                continue
            owned_start = owned[0].timestamp
            interval = owned[0].interval
            gap_limit = max(60.0, interval * 2.5)
            owned = [sample for sample in owned if sample.timestamp < owned_start + MIN_COMPARISON_SECONDS]
            baseline = [sample for sample in usable if sample.session == owned[0].session
                        and owned_start - MIN_COMPARISON_SECONDS <= sample.timestamp < owned_start]
            if (not baseline or any(sample.owner or sample.mode == "dryRun" for sample in baseline)
                    or owned_start - baseline[-1].timestamp > gap_limit
                    or not cls._covered(baseline) or not cls._covered(owned)):
                continue
            baseline_cpu = sum(sample.cpu for sample in baseline if sample.cpu is not None) / len(baseline)
            linked_cpu = sum(sample.cpu for sample in owned if sample.cpu is not None) / len(owned)
            baseline_load = cls._average_optional(sample.cpu_load for sample in baseline)
            linked_load = cls._average_optional(sample.cpu_load for sample in owned)
            message = "相邻两个约五分钟窗口的实测温差；受负载、室温与 Mac 自身温控影响，不代表净化器造成了该温差。"
            if baseline_load is None or linked_load is None:
                message = "负载样本不足，无法判断前后工作负载是否相近；温差不能归因于净化器。"
            elif abs(linked_load - baseline_load) >= 10.0:
                message = "前后 CPU 活跃占比变化较大，温差不可直接比较；这不是净化器降温效果估算。"
            return {
                "baselineCPU": baseline_cpu, "linkedCPU": linked_cpu,
                "deltaCPU": baseline_cpu - linked_cpu, "baselineLoad": baseline_load,
                "linkedLoad": linked_load, "baselineCount": len(baseline), "linkedCount": len(owned),
                "start": baseline[0].timestamp, "end": owned[-1].timestamp, "message": message,
            }
        return None

    @staticmethod
    def _covered(samples: list[Sample]) -> bool:
        if len(samples) < 2:
            return False
        interval = max(1.0, samples[0].interval)
        if samples[-1].timestamp - samples[0].timestamp < MIN_COMPARISON_SECONDS * MIN_COVERAGE:
            return False
        if any(right.timestamp - left.timestamp > max(60.0, interval * 2.5)
               for left, right in zip(samples, samples[1:])):
            return False
        expected = math.ceil(MIN_COMPARISON_SECONDS / interval)
        return len(samples) >= math.ceil(expected * MIN_COVERAGE)

    @staticmethod
    def _average_optional(values: Iterable[float | None]) -> float | None:
        sequence = list(values)
        present = [value for value in sequence if value is not None]
        return sum(present) / len(present) if present and len(present) >= math.ceil(len(sequence) * MIN_COVERAGE) else None
