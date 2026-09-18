from pathlib import Path
import json
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import pair_device
import worker


class MemoryKeyring:
    def __init__(self, token=None):
        self.token = token
        self.fail_new_once = False

    def get_password(self, service, account):
        return self.token

    def set_password(self, service, account, token):
        self.token = token
        if self.fail_new_once:
            self.fail_new_once = False
            raise OSError("keychain rejected commit")

    def delete_password(self, service, account):
        self.token = None


class AccountPersistenceTests(unittest.TestCase):
    def test_failed_keychain_commit_leaves_previous_device_usable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device.json"
            original = {"model": "zhimi.airpurifier.m1", "ip": "192.168.1.2", "credentialId": "old"}
            path.write_text(json.dumps(original))
            keys = MemoryKeyring(json.dumps({"old": "a" * 32}))
            keys.fail_new_once = True
            with self.assertRaises(OSError):
                pair_device.commit_credentials(
                    {"model": "zhimi.airpurifier.m2", "ip": "192.168.1.3"},
                    "b" * 32, path=path, keyring_module=keys,
                )
            current = json.loads(path.read_text())
            self.assertEqual(current["model"], "zhimi.airpurifier.m1")
            self.assertEqual(pair_device.read_token(current, keyring_module=keys), "a" * 32)

    def test_committed_account_resolves_only_its_own_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device.json"
            keys = MemoryKeyring(json.dumps({"old": "a" * 32}))
            metadata = {"model": "zhimi.airpurifier.m2", "ip": "192.168.1.3", "region": "sg"}
            pair_device.commit_credentials(metadata, "b" * 32, path=path, keyring_module=keys)
            current = json.loads(path.read_text())
            self.assertEqual(pair_device.read_token(current, keyring_module=keys), "b" * 32)
            self.assertIsNone(pair_device.read_token({"credentialId": "old"}, keyring_module=keys))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_interrupted_metadata_commit_preserves_previous_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device.json"
            previous = {"model": "zhimi.airpurifier.m1", "credentialId": "old"}
            path.write_text(json.dumps(previous))
            keys = MemoryKeyring(json.dumps({"old": "a" * 32}))
            replace = pair_device.os.replace
            def interrupt(source, destination):
                if destination == path:
                    raise SystemExit(1)
                return replace(source, destination)
            with patch.object(pair_device.os, "replace", side_effect=interrupt), self.assertRaises(SystemExit):
                pair_device.commit_credentials({"model": "zhimi.airpurifier.m2"}, "b" * 32, path=path, keyring_module=keys)
            self.assertEqual(pair_device.read_token(json.loads(path.read_text()), keyring_module=keys), "a" * 32)

    def test_explicit_migration_never_merges_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "legacy", Path(directory) / "new"
            source.mkdir()
            destination.mkdir()
            (source / "device.json").write_text('{"model":"old"}')
            (source / "worker_state.json").write_text('{"version":1}')
            (destination / "device.json").write_text('{"model":"current"}')
            self.assertFalse(pair_device.migrate_legacy_data(source, destination=destination))
            self.assertEqual(json.loads((destination / "device.json").read_text())["model"], "current")
            self.assertFalse((destination / "worker_state.json").exists())

    def test_explicit_migration_preserves_paused_calibrated_strategy(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "legacy", Path(directory) / "new"
            source.mkdir()
            (source / "device.json").write_text('{"model":"zhimi.airpurifier.m1"}')
            (source / "worker_state.json").write_text(json.dumps({
                "config": worker.Config(mediumLevel=5, highLevel=6).to_dict(),
                "verifiedLevels": [5, 6], "manualPaused": True, "intentEnabled": True,
            }))
            keys = MemoryKeyring("a" * 32)
            with (
                patch.object(pair_device.keyring, "get_password", side_effect=keys.get_password),
                patch.object(pair_device.keyring, "set_password", side_effect=keys.set_password),
            ):
                self.assertTrue(pair_device.migrate_legacy_data(source, destination=destination))
            with (
                patch.object(worker, "STATE_PATH", destination / "worker_state.json"),
                patch.object(worker, "DEVICE_PATH", destination / "device.json"),
            ):
                restored = worker.Worker()
            self.assertEqual((restored.config.mediumLevel, restored.config.highLevel), (5, 6))
            self.assertEqual(restored.verified, {5, 6})
            self.assertEqual(restored.mode, "paused")
            self.assertEqual(pair_device.read_token(json.loads((destination / "device.json").read_text()), keyring_module=keys), "a" * 32)

    def test_unknown_air_purifier_protocol_is_listed_but_cannot_be_selected(self):
        session = pair_device.PairingSession("cn", lambda phase, fields: None)
        session.raw_devices["unknown"] = {
            "did": "unknown", "name": "Future Purifier", "model": "vendor.airpurifier.future",
            "localip": "192.168.1.8", "token": "a" * 32,
        }
        with self.assertRaisesRegex(pair_device.PairingError, "unsupported_model"):
            session.candidate_secret("unknown")


class PairingCancellationTests(unittest.TestCase):
    def test_qr_expiry_removes_private_temporary_image(self):
        class Response:
            content = b"png"
            status_code = 200
            def raise_for_status(self):
                pass

        class HTTP:
            def __init__(self):
                self.calls = 0

            def close(self):
                pass

            def get(self, url, **kwargs):
                self.calls += 1
                if self.calls == 1:
                    return Response()
                raise pair_device.requests.Timeout()

        class InitialSession:
            def close(self):
                pass

        class BaseConnector:
            def __init__(self):
                self._session = InitialSession()
                self._qr_image_url = "https://account.xiaomi.com/qr"
                self._long_polling_url = "https://account.xiaomi.com/lp"
                self._timeout = 0.01

            def login(self):
                return self.login_step_2() and self.login_step_3()

        module = SimpleNamespace(QrCodeXiaomiCloudConnector=BaseConnector)
        events = []
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(pair_device, "DATA_DIR", Path(directory)),
                patch.object(pair_device, "_load_upstream", return_value=module),
                patch.object(pair_device, "XiaomiSession", HTTP),
            ):
                session = pair_device.PairingSession("cn", lambda phase, fields: events.append((phase, fields)))
                with self.assertRaisesRegex(pair_device.PairingError, "qr_expired"):
                    session.run()
                self.assertFalse(any(Path(directory).rglob("*.png")))
        self.assertEqual(events[-1][0], "waitingForScan")

    def test_worker_cancel_is_nonblocking_and_keeps_existing_pairing(self):
        started = threading.Event()

        class BlockingSession:
            def __init__(self, region, emit):
                self.cancelled = threading.Event()

            def run(self):
                started.set()
                self.cancelled.wait(2)
                raise pair_device.PairingError("cancelled")

            def cancel(self):
                self.cancelled.set()

            def close(self):
                self.cancel()

        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(worker, "LOCAL", Path(directory)),
                patch.object(worker, "STATE_PATH", Path(directory) / "state.json"),
                patch.object(worker, "DEVICE_PATH", Path(directory) / "device.json"),
                patch.object(worker, "PairingSession", BlockingSession),
            ):
                subject = worker.Worker()
                subject.begin_pairing("cn")
                self.assertTrue(started.wait(1))
                before = time.monotonic()
                subject.cancel_pairing()
                self.assertLess(time.monotonic() - before, 0.2)
                self.assertEqual(subject.account["phase"], "idle")
                self.assertIsNone(subject.pairing)


class AccountSwitchSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.patches = (
            patch.object(worker, "LOCAL", self.root),
            patch.object(worker, "STATE_PATH", self.root / "state.json"),
            patch.object(worker, "DEVICE_PATH", self.root / "device.json"),
        )
        for item in self.patches:
            item.start()
        self.subject = worker.Worker()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def test_restore_failure_blocks_logout_before_credential_deletion(self):
        purifier = SimpleNamespace(status=lambda: (_ for _ in ()).throw(OSError("offline")))
        self.subject.device = purifier
        self.subject.owner = True
        self.subject.snapshot = {"power": True, "mode": "favorite", "level": 5}
        self.subject.expected = {"power": True, "mode": "favorite", "level": 8}
        with patch.object(worker, "delete_local_credentials") as delete:
            with self.assertRaisesRegex(ValueError, "恢复结果未决"):
                self.subject.logout()
        delete.assert_not_called()
        self.assertIsNotNone(self.subject.snapshot)

    def test_new_device_cannot_inherit_verified_levels_or_mapping(self):
        self.subject.verified = {5, 6, 8}
        self.subject.config = worker.Config(mediumLevel=5, highLevel=6)
        (self.root / "device.json").write_text(json.dumps({"model": "zhimi.airpurifier.m1", "credentialId": "old"}))
        status = SimpleNamespace(
            is_on=True, mode=SimpleNamespace(value="favorite"), favorite_level=3,
            motor_speed=900,
        )
        payload = {
            "metadata": {
                "id": "new", "name": "Bedroom", "model": "zhimi.airpurifier.m2",
                "ip": "192.168.1.9", "region": "cn", "accountLabel": "米家账号",
            },
            "token": "b" * 32,
            "checked": {"firmware": "1.0", "status": status, "purifier": object()},
        }
        keys = MemoryKeyring(json.dumps({"old": "a" * 32}))
        with (
            patch.object(worker.keyring, "get_password", side_effect=keys.get_password),
            patch.object(worker.keyring, "set_password", side_effect=keys.set_password),
        ):
            self.subject._apply_selection(payload)
        self.assertEqual(self.subject.verified, set())
        self.assertIsNone(self.subject.config.mediumLevel)
        self.assertIsNone(self.subject.config.highLevel)


if __name__ == "__main__":
    unittest.main()
