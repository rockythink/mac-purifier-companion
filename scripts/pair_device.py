"""Cancellable Xiaomi QR pairing and transactional local device selection.

This module never prints authentication payloads and never writes to a device.  It
is usable as a library by ``worker.py``; its small CLI is diagnostic-only.
"""

from __future__ import annotations

import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import threading
import time
from typing import Any, Callable
from urllib.parse import urlparse
import uuid

import keyring
from keyring.backends.macOS import Keyring
import requests
from miio import AirPurifier
from miio.integrations.airpurifier.zhimi.airpurifier import SUPPORTED_MODELS

ROOT = Path(__file__).resolve().parents[1]
RESOURCE_DIR = Path(os.environ.get("MACFANLINK_RESOURCE_DIR", ROOT / "Resources"))
DATA_DIR = Path(os.environ.get(
    "MACFANLINK_DATA_DIR",
    Path.home() / "Library" / "Application Support" / "cc.ss-data.MacFanLink",
))
DEVICE_PATH = DATA_DIR / "device.json"
SERVICE = os.environ.get("MACFANLINK_KEYCHAIN_SERVICE", "cc.ss-data.mac-xiaomi-fan-link")
ACCOUNT = "purifier"
REGIONS = frozenset(("cn", "de", "us", "ru", "tw", "sg", "in", "i2"))
TOKEN_PATTERN = re.compile(r"[a-fA-F0-9]{32}")
SUPPORTED = frozenset(SUPPORTED_MODELS)
EventSink = Callable[[str, dict[str, Any]], None]


class PairingError(Exception):
    pass


def _private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def _private_write(path: Path, content: bytes) -> None:
    _private_directory(path.parent)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def _cloud_result(response: Any) -> dict[str, Any]:
    if not isinstance(response, dict) or response.get("code") != 0:
        raise PairingError("cloud_query_failed")
    result = response.get("result")
    if not isinstance(result, dict):
        raise PairingError("cloud_response_invalid")
    return result


def _valid_local_ip(value: Any) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise PairingError("local_address_invalid") from error
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_unspecified:
        raise PairingError("local_address_invalid")
    return str(address)


def _valid_token(value: Any) -> str:
    if not isinstance(value, str) or not TOKEN_PATTERN.fullmatch(value) or set(value) == {"0"}:
        raise PairingError("local_token_unavailable")
    return value.lower()


def _device_record(raw: dict[str, Any]) -> dict[str, Any] | None:
    model = raw.get("model")
    if not isinstance(model, str) or "airpurifier" not in model.lower():
        return None
    supported = model in SUPPORTED
    ip = raw.get("localip") if isinstance(raw.get("localip"), str) else ""
    return {
        "id": str(raw.get("did", "")),
        "name": str(raw.get("name") or model),
        "model": model,
        "ip": ip,
        "supported": supported,
        "reason": "SDK 协议兼容，仍需本地状态核验" if supported else "当前 SDK 不支持此型号协议",
        "imageURL": None,
    }


class XiaomiSession(requests.Session):
    """Bound requests and reject redirects outside Xiaomi HTTPS services."""

    def send(self, request: requests.PreparedRequest, **kwargs: Any):
        url = urlparse(request.url)
        host = url.hostname or ""
        if url.scheme != "https" or not any(
            host == domain or host.endswith("." + domain) for domain in ("xiaomi.com", "mi.com")
        ):
            raise PairingError("unexpected_auth_host")
        kwargs["timeout"] = min(float(kwargs.get("timeout") or 20), 20)
        return super().send(request, **kwargs)


def _load_upstream() -> Any:
    path = RESOURCE_DIR / "vendor" / "token_extractor.py"
    if not path.is_file():
        raise PairingError("vendored_qr_backend_missing")
    spec = importlib.util.spec_from_file_location("macfanlink_token_extractor", path)
    if spec is None or spec.loader is None:
        raise PairingError("vendored_qr_backend_invalid")
    module = importlib.util.module_from_spec(spec)
    original = sys.argv
    try:
        # The pinned upstream module parses argv at import time.  Its main(), image
        # server and password login paths are never invoked.
        sys.argv = [str(path)]
        spec.loader.exec_module(module)
    finally:
        sys.argv = original
    module.print_if_interactive = lambda *args, **kwargs: None
    return module


class PairingSession:
    """One QR authorization session. Call ``run`` on a background thread."""

    def __init__(self, region: str, emit: EventSink) -> None:
        if region not in REGIONS:
            raise ValueError("不支持的米家地区")
        self.region = region
        self.emit = emit
        self.cancelled = threading.Event()
        self.connector: Any = None
        self.qr_path: Path | None = None
        self.raw_devices: dict[str, dict[str, Any]] = {}
        self.account_label = "米家账号"

    def cancel(self) -> None:
        self.cancelled.set()
        connector = self.connector
        if connector is not None:
            try:
                connector._session.close()
            except Exception:
                pass
        self._remove_qr()

    def _remove_qr(self) -> None:
        if self.qr_path is not None:
            self.qr_path.unlink(missing_ok=True)
            try:
                self.qr_path.parent.rmdir()
            except OSError:
                pass
            self.qr_path = None

    def run(self) -> list[dict[str, Any]]:
        module = _load_upstream()
        owner = self

        class Connector(module.QrCodeXiaomiCloudConnector):
            def __init__(self) -> None:
                super().__init__()
                self._session.close()
                self._session = XiaomiSession()

            def login_step_2(self) -> bool:
                if owner.cancelled.is_set():
                    raise PairingError("cancelled")
                response = self._session.get(self._qr_image_url)
                response.raise_for_status()
                if owner.cancelled.is_set():
                    raise PairingError("cancelled")
                qr_dir = DATA_DIR / "pairing" / uuid.uuid4().hex
                owner.qr_path = qr_dir / "qr.png"
                _private_write(owner.qr_path, response.content)
                expires = time.time() + min(float(self._timeout), 180.0)
                owner.emit("waitingForScan", {
                    "message": "请使用米家扫码并确认登录",
                    "qrImagePath": str(owner.qr_path),
                    "expiresAt": expires,
                })
                return True

            def login_step_3(self) -> bool:
                deadline = time.monotonic() + min(float(self._timeout), 180.0)
                while time.monotonic() < deadline:
                    if owner.cancelled.is_set():
                        raise PairingError("cancelled")
                    try:
                        response = self._session.get(
                            self._long_polling_url,
                            timeout=max(0.1, min(5.0, deadline - time.monotonic())),
                        )
                    except requests.Timeout:
                        continue
                    if response.status_code != 200:
                        raise PairingError("qr_poll_failed")
                    data = self.to_json(response.text)
                    if not all(data.get(key) for key in ("userId", "ssecurity", "location")):
                        raise PairingError("qr_not_authorized")
                    self.userId = data["userId"]
                    self._ssecurity = data["ssecurity"]
                    self._location = data["location"]
                    return True
                raise PairingError("qr_expired")

        self.emit("requesting", {"message": "正在请求米家登录二维码"})
        connector = Connector()
        self.connector = connector
        try:
            if not connector.login():
                raise PairingError("login_failed")
            self._remove_qr()
            if self.cancelled.is_set():
                raise PairingError("cancelled")
            self.emit("loadingDevices", {"message": "正在读取净化器列表"})
            homes = _cloud_result(connector.get_homes(self.region))
            for home in homes.get("homelist") or []:
                if self.cancelled.is_set():
                    raise PairingError("cancelled")
                result = _cloud_result(connector.get_devices(self.region, home.get("id"), connector.userId))
                for raw in result.get("device_info") or []:
                    if isinstance(raw, dict):
                        record = _device_record(raw)
                        if record and record["id"]:
                            self.raw_devices[record["id"]] = raw
            devices = [_device_record(raw) for raw in self.raw_devices.values()]
            return [device for device in devices if device is not None]
        except Exception:
            self._remove_qr()
            raise

    def candidate_secret(self, device_id: str) -> tuple[dict[str, Any], str]:
        if self.cancelled.is_set():
            raise PairingError("cancelled")
        raw = self.raw_devices.get(device_id)
        if raw is None:
            raise PairingError("device_not_in_authorized_list")
        record = _device_record(raw)
        if record is None or not record["supported"]:
            raise PairingError("unsupported_model")
        token = _valid_token(raw.get("token"))
        metadata = {
            "id": record["id"], "name": record["name"], "model": record["model"],
            "ip": _valid_local_ip(raw.get("localip")), "region": self.region,
            "accountLabel": self.account_label,
        }
        return metadata, token

    def close(self) -> None:
        self._remove_qr()
        if self.connector is not None:
            self.connector._session.close()


def verify_candidate(metadata: dict[str, Any], token: str, *, purifier_factory: Any = AirPurifier) -> dict[str, Any]:
    """Read-only identity/status validation via the exact supported interface."""
    model = metadata.get("model")
    if model not in SUPPORTED:
        raise PairingError("unsupported_model")
    purifier = purifier_factory(metadata["ip"], token, timeout=3, model=model)
    info = purifier.info()
    if info.model != model:
        raise PairingError("local_model_mismatch")
    status = purifier.status()
    level = status.favorite_level
    if isinstance(level, bool) or not isinstance(level, int) or not 0 <= level <= 17:
        raise PairingError("favorite_level_out_of_range")
    return {"firmware": info.firmware_version, "status": status, "purifier": purifier}


def read_token(metadata: dict[str, Any], *, keyring_module: Any = keyring) -> str | None:
    credential_id = metadata.get("credentialId")
    stored = keyring_module.get_password(SERVICE, ACCOUNT)
    if not credential_id or not stored:
        return None
    try:
        records = json.loads(stored)
        token = records.get(credential_id)
    except (ValueError, AttributeError):
        raise PairingError("credential_store_invalid") from None
    return _valid_token(token) if token else None


def commit_credentials(
    metadata: dict[str, Any], token: str, *, path: Path = DEVICE_PATH, keyring_module: Any = keyring,
) -> dict[str, Any]:
    """Keep old credentials usable until the new metadata pointer is committed."""
    stored = keyring_module.get_password(SERVICE, ACCOUNT)
    records = json.loads(stored) if stored else {}
    if not isinstance(records, dict):
        raise PairingError("credential_store_invalid")
    credential_id = uuid.uuid4().hex
    committed = {**metadata, "credentialId": credential_id}
    staged = path.with_name(f".{path.name}.{credential_id}.pending")
    _private_write(staged, json.dumps(committed, ensure_ascii=False, separators=(",", ":")).encode())
    try:
        keyring_module.set_password(SERVICE, ACCOUNT, json.dumps({**records, credential_id: token}))
        os.replace(staged, path)
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    try:
        keyring_module.set_password(SERVICE, ACCOUNT, json.dumps({credential_id: token}))
    except Exception:
        # The selected credential is already valid; logout removes the whole item.
        committed["credentialCleanupPending"] = True
    return committed


def delete_local_credentials(*, path: Path = DEVICE_PATH, keyring_module: Any = keyring) -> None:
    """Delete only this Mac's credential and metadata; no cloud unbind request exists here."""
    old_metadata = path.read_bytes() if path.exists() else None
    old_token = keyring_module.get_password(SERVICE, ACCOUNT)
    try:
        keyring_module.delete_password(SERVICE, ACCOUNT)
    except keyring.errors.PasswordDeleteError:
        pass
    try:
        path.unlink(missing_ok=True)
    except Exception:
        if old_token is not None:
            keyring_module.set_password(SERVICE, ACCOUNT, old_token)
        if old_metadata is not None and not path.exists():
            _private_write(path, old_metadata)
        raise


def migrate_legacy_data(source: Path, *, destination: Path = DATA_DIR) -> bool:
    """Explicitly migrate one complete legacy profile into an empty destination."""
    source = source.expanduser().resolve()
    destination = destination.expanduser().resolve()
    if source == destination or not (source / "device.json").is_file():
        return False
    if destination.exists() and any(destination.iterdir()):
        return False
    metadata = json.loads((source / "device.json").read_text())
    stored = keyring.get_password(SERVICE, ACCOUNT)
    if stored and TOKEN_PATTERN.fullmatch(stored):
        token = _valid_token(stored)
    else:
        token = _valid_token(json.loads(stored or "{}").get("legacy"))
    metadata["credentialId"] = "legacy"
    stage = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.migration")
    _private_directory(stage)
    try:
        _private_write(stage / "device.json", json.dumps(metadata).encode())
        if (source / "worker_state.json").is_file():
            state = json.loads((source / "worker_state.json").read_text())
            state["deviceIdentity"] = "legacy"
            _private_write(stage / "worker_state.json", json.dumps(state).encode())
        keyring.set_password(SERVICE, ACCOUNT, json.dumps({"legacy": token}))
        os.replace(stage, destination)
    finally:
        if stage.exists():
            for item in stage.iterdir():
                item.unlink()
            stage.rmdir()
    return True


def diagnose() -> dict[str, Any]:
    metadata = json.loads(DEVICE_PATH.read_text())
    token = read_token(metadata)
    if not token:
        raise PairingError("keychain_token_missing")
    result = verify_candidate(metadata, token)
    status = result["status"]
    return {
        "model": metadata["model"], "firmware": result["firmware"],
        "power": status.is_on, "mode": getattr(status.mode, "value", str(status.mode)),
        "favoriteLevel": status.favorite_level,
    }


def main() -> int:
    os.umask(0o077)
    _private_directory(DATA_DIR)
    keyring.set_keyring(Keyring())
    if len(sys.argv) == 2 and sys.argv[1] == "--diagnose":
        print(json.dumps(diagnose(), ensure_ascii=False, separators=(",", ":")))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--migrate-legacy":
        print(json.dumps({"migrated": migrate_legacy_data(Path(sys.argv[2]))}, separators=(",", ":")))
        return 0
    raise PairingError("usage: pair_device.py --diagnose | --migrate-legacy PATH")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PairingError as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False, separators=(",", ":")))
        raise SystemExit(1)
    except Exception as error:
        # External exception text may contain auth URLs, cloud replies or tokens.
        print(json.dumps({"error": type(error).__name__, "message": "凭据相关详情已隐藏"}, ensure_ascii=False))
        raise SystemExit(1)
