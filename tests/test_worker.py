import builtins
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import worker


class _Mode:
    def __init__(self, value):
        self.value = value


class _Status:
    def __init__(self, device):
        self.is_on = device.power
        self.mode = _Mode(device.mode)
        self.favorite_level = device.level
        self.motor_speed = 1200


class FakePurifier:
    def __init__(self, mode="favorite", level=9):
        self.power = True
        self.mode = mode
        self.level = level
        self.writes = []

    def info(self):
        return SimpleNamespace(model="zhimi.airpurifier.m1", firmware_version="1.4.3_100")

    def status(self):
        return _Status(self)

    def set_mode(self, mode):
        self.writes.append(("mode", mode.value))
        self.mode = mode.value

    def set_favorite_level(self, level):
        self.writes.append(("level", level))
        self.level = level

class MemoryKeyring:
    def __init__(self):
        self.values = {}

    def set_keyring(self, backend):
        return None

    def get_password(self, service, account):
        return self.values.get((service, account))

    def set_password(self, service, account, value):
        self.values[(service, account)] = value

    def delete_password(self, service, account):
        self.values.pop((service, account), None)

class WorkerSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.memory_keyring = MemoryKeyring()
        (root / "device.json").write_text('{"credentialId":"test-device"}')
        self.patches = (
            patch.object(worker, "LOCAL", root),
            patch.object(worker, "STATE_PATH", root / "state.json"),
            patch.object(worker, "DEVICE_PATH", root / "device.json"),
            patch.object(worker, "keyring", self.memory_keyring),
            patch.object(worker, "Keyring", return_value=self.memory_keyring),
        )
        for item in self.patches:
            item.start()
        self.instance = worker.Worker()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def test_restore_only_when_expected_state_is_still_owned(self):
        purifier = FakePurifier(level=9)
        subject = self.instance
        subject.device = purifier
        subject.device_view.update({"reachable": True, "power": True, "mode": "favorite", "level": 9, "rpm": 1200})
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        subject.owner = True

        self.assertTrue(subject._restore("测试恢复"))
        self.assertEqual(purifier.writes, [("level", 6)])
        self.assertFalse(subject.owner)

        purifier.level = 8
        subject.device_view["level"] = 8
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        subject.owner = True
        self.assertFalse(subject._restore("不得覆盖"))
        self.assertEqual(purifier.writes, [("level", 6)])

    def test_broken_stdout_restores_the_owned_device_before_exit(self):
        subject = self.instance
        purifier = FakePurifier(level=9)
        subject.device = purifier
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        subject.owner = True
        with patch.object(builtins, "print", side_effect=BrokenPipeError):
            subject._output({"kind": "status"})
        self.assertEqual(purifier.level, 6)
        self.assertFalse(subject.running)

    def test_refresh_recovers_an_initial_connection_failure_without_writing(self):
        metadata = Path(self.temporary.name) / "device.json"
        metadata.write_text('{"model":"zhimi.airpurifier.m1","ip":"192.168.8.152"}')
        purifier = FakePurifier(level=6)
        with (
            patch.object(worker, "DEVICE_PATH", metadata),
            patch.object(worker, "read_token", return_value="a" * 32),
            patch.object(worker, "AirPurifier", side_effect=[OSError("network unavailable"), purifier]),
        ):
            self.instance.connect_device()
            self.assertFalse(self.instance.device_view["reachable"])
            self.instance.handle_command({"op": "refresh"})
        self.assertTrue(self.instance.device_view["reachable"])
        self.assertEqual(self.instance.device_view["level"], 6)
        self.assertEqual(purifier.writes, [])
    def test_failed_command_emits_one_correlated_result_with_authoritative_status(self):
        emitted = []
        self.instance._output = emitted.append
        self.instance.process_command({"id": "request-1", "op": "unknown"})

        self.assertEqual(len(emitted), 1)
        result = emitted[0]
        self.assertEqual((result["kind"], result["id"], result["op"]),
                         ("commandResult", "request-1", "unknown"))
        self.assertFalse(result["success"])
        self.assertEqual(result["status"]["kind"], "status")

    def test_real_fresh_paired_sample_records_load_without_device_writes(self):
        subject = self.instance
        subject.account["paired"] = True
        subject.device_view.update({"reachable": True, "rpm": 1200, "level": 8, "mode": "favorite"})
        subject.device_observed_mono = 100
        with patch.object(worker.time, "monotonic", return_value=100), patch.object(worker.time, "time", return_value=1000):
            subject.handle_sensor({"timestamp": 1000, "cpu_active_ratio": 0.42,
                                   "temp": {"cpu_temp_avg": 71, "gpu_temp_avg": 55}})
        snapshot = subject.history.snapshot(device_id=subject.history_device_identity, hours=1, now=1000)
        self.assertEqual(snapshot["totalSamples"], 1)
        self.assertEqual(snapshot["points"][0]["cpuLoad"], 42)
        self.assertEqual(subject.temperature["cpuLoad"], 42)

    def test_host_metrics_record_while_unpaired_and_cpu_temperature_is_absent(self):
        subject = self.instance
        subject.account["paired"] = False
        payload = {
            "timestamp": 1000, "gpu_active_ratio": 0.375,
            "memory": {"ram_total": 16, "ram_usage": 9, "swap_total": 4, "swap_usage": 1},
            "fans": [{"name": "Left", "rpm": 1234, "max_rpm": 6000}],
            "temp": {"cpu_temp_avg": None, "gpu_temp_avg": 51},
        }
        with (patch.object(worker, "read_system_conditions", return_value={
                "memoryPressure": "warning", "thermalState": "fair"}),
              patch.object(worker.time, "monotonic", return_value=100),
              patch.object(worker.time, "time", return_value=1000)):
            subject.handle_sensor(payload)
            status = subject.status()
            self.assertFalse(status["system"]["stale"])
        self.assertEqual(status["system"]["gpuLoad"], 37.5)
        self.assertEqual(status["system"]["memory"]["usedBytes"], 9)
        self.assertEqual(status["system"]["fans"][0]["maxRPM"], 6000)
        snapshot = subject.history.snapshot(device_id=subject.history_device_identity, hours=1, now=1000)
        self.assertEqual(snapshot["totalSamples"], 1)
        point = snapshot["points"][0]
        self.assertIsNone(point["cpu"])
        self.assertIsNone(point["deviceId"])
        self.assertIs(point["owner"], False)
        self.assertEqual(point["memoryPressure"], "warning")

    def test_host_history_uses_twenty_second_cadence_but_records_pressure_transition(self):
        subject = self.instance
        payload = {"cpu_active_ratio": 0.5, "temp": {"cpu_temp_avg": 70}}
        with patch.object(worker, "read_system_conditions", return_value={"memoryPressure": "normal"}):
            for timestamp in (1000, 1002, 1004):
                payload["timestamp"] = timestamp
                with (patch.object(worker.time, "monotonic", return_value=timestamp),
                      patch.object(worker.time, "time", return_value=timestamp)):
                    subject.handle_sensor(payload)
        self.assertEqual(subject.history.snapshot(device_id=None, hours=1, now=1010)["totalSamples"], 1)
        payload["timestamp"] = 1006
        with (patch.object(worker, "read_system_conditions", return_value={"memoryPressure": "critical"}),
              patch.object(worker.time, "monotonic", return_value=1006),
              patch.object(worker.time, "time", return_value=1006)):
            subject.handle_sensor(payload)
        result = subject.history.snapshot(device_id=None, hours=1, now=1010)
        self.assertEqual(result["totalSamples"], 2)
        self.assertEqual(result["points"][-1]["memoryPressure"], "critical")

    def test_invalid_optional_host_metrics_are_not_fabricated_as_zero(self):
        payload = {
            "timestamp": 1000, "gpu_active_ratio": 2,
            "memory": {"ram_total": 16, "ram_usage": "bad", "swap_total": 4, "swap_usage": 1},
            "fans": [{"name": "Left", "rpm": "bad"}],
            "temp": {"cpu_temp_avg": 70},
        }
        with (patch.object(worker, "read_system_conditions", side_effect=RuntimeError("private detail")),
              patch.object(worker.time, "monotonic", return_value=100),
              patch.object(worker.time, "time", return_value=1000)):
            self.instance.handle_sensor(payload)
        system = self.instance.status()["system"]
        self.assertIsNone(system["gpuLoad"])
        self.assertIsNone(system["memory"])
        self.assertEqual(system["fans"], [])
        self.assertIsNone(system["memoryPressure"])
        self.assertIsNone(system["thermalState"])

    def test_process_request_is_acknowledged_then_returns_sanitized_correlated_result(self):
        emitted = []
        self.instance._output = emitted.append
        sampled = {
            "timestamp": 123.0, "error": None,
            "processes": [
                {"pid": 7, "name": "/private/path/App", "cpuPercent": 150.5},
                {"pid": 8, "name": "Other", "cpuPercent": 12.0},
            ],
        }
        with patch.object(worker, "sample_top_processes", return_value=sampled):
            self.instance.process_command({"id": "process-1", "op": "processes"})
            kind, result = self.instance.events.get(timeout=2)
        self.assertEqual((emitted[0]["kind"], emitted[0]["success"]), ("commandResult", True))
        self.assertEqual(kind, "processes")
        self.assertEqual((result["kind"], result["requestId"]), ("processes", "process-1"))
        self.assertEqual(result["processes"][0], {"pid": 7, "name": "App", "cpuPercent": 150.5})
        self.assertNotIn("private", json.dumps(result))
        self.instance.processes_pending = False

    def test_process_requests_are_single_flight_and_accept_no_arguments(self):
        self.instance.processes_pending = True
        with self.assertRaisesRegex(ValueError, "正在进行"):
            self.instance.handle_command({"id": "second", "op": "processes"})
        self.instance.processes_pending = False
        with self.assertRaisesRegex(ValueError, "不接受参数"):
            self.instance.handle_command({"id": "args", "op": "processes", "limit": 5})
    def test_history_reply_uses_only_its_request_id_and_is_acknowledged(self):
        emitted = []
        self.instance._output = emitted.append
        self.instance.process_command({"id": "history-1", "op": "history", "hours": 24})

        self.assertEqual([item["kind"] for item in emitted], ["history", "commandResult"])
        self.assertEqual(emitted[0]["requestId"], "history-1")
        self.assertNotIn("id", emitted[0])
        self.assertTrue(emitted[1]["success"])

    def test_automatic_mode_is_restored_after_takeover(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=6)
        subject.device = purifier
        subject.poll_device()
        self.assertTrue(subject._write_level(8))
        self.assertEqual((purifier.mode, purifier.level), ("favorite", 8))
        self.assertTrue(subject._restore("恢复自动模式"))
        self.assertEqual((purifier.mode, purifier.level), ("auto", 6))
        events = subject.history.snapshot(
            device_id=subject.history_device_identity, hours=1, now=worker.time.time()
        )["events"]
        self.assertEqual([event["kind"] for event in events], ["connection", "takeover", "restore"])

    def test_manual_change_before_adjustment_is_not_overwritten(self):
        subject = self.instance
        purifier = FakePurifier(level=8)
        subject.device = purifier
        subject.device_view.update({"reachable": True, "power": True, "mode": "favorite", "level": 9})
        subject.owner = True
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        self.assertFalse(subject._write_level(10))
        self.assertEqual(purifier.level, 8)
        self.assertEqual(purifier.writes, [])

    def test_unreachable_restore_keeps_evidence_instead_of_claiming_no_control(self):
        subject = self.instance
        purifier = FakePurifier(level=9)
        subject.device = purifier
        subject.owner = True
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        with patch.object(purifier, "status", side_effect=OSError):
            self.assertFalse(subject._restore("恢复"))
        self.assertEqual(subject.command_state, "unknown")
        self.assertEqual(subject.snapshot["level"], 6)
        self.assertEqual(purifier.writes, [])

    def test_invalid_samples_after_expiry_restore_owned_device(self):
        subject = self.instance
        purifier = FakePurifier(level=9)
        subject.device = purifier
        subject.owner = True
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        subject.sensor_received_mono = 0
        subject.sensor_source_wall = 0
        with patch.object(worker.time, "monotonic", return_value=200), patch.object(worker.time, "time", return_value=200):
            subject.handle_sensor({"temp": {"cpu_temp_avg": None}})
        self.assertEqual(purifier.level, 6)
        self.assertFalse(subject.owner)

    def test_calibration_is_verified_only_after_owned_restore(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=6)
        subject.device = purifier
        subject.start_test(8)
        self.assertEqual((purifier.mode, purifier.level), ("favorite", 8))
        self.assertEqual(subject.verified, set())
        self.assertTrue(subject.owner)
        self.assertIsNotNone(subject.snapshot)
        subject.finish_test()
        self.assertEqual((purifier.mode, purifier.level), ("auto", 6))
        self.assertEqual(subject.verified, {8})
        self.assertFalse(subject.owner)
        self.assertIsNone(subject.snapshot)

    def test_calibration_yields_to_manual_changes_without_marking_verified(self):
        subject = self.instance
        purifier = FakePurifier(level=6)
        subject.device = purifier
        subject.start_test(8)
        purifier.level = 10
        subject.finish_test()
        self.assertEqual(purifier.level, 10)
        self.assertEqual(subject.verified, set())
        self.assertFalse(subject.owner)
        self.assertFalse(subject.busy)

    def test_two_level_strategy_restores_between_levels_and_verifies_in_order(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=6)
        subject.device = purifier
        subject.start_test_strategy([8, 10])
        self.assertEqual((purifier.mode, purifier.level), ("favorite", 8))

        subject.finish_test()
        self.assertEqual((purifier.mode, purifier.level), ("favorite", 10))
        self.assertEqual(subject.verified, {8})
        self.assertTrue(subject.busy)

        subject.finish_test()
        self.assertEqual((purifier.mode, purifier.level), ("auto", 6))
        self.assertEqual(subject.verified, {8, 10})
        self.assertFalse(subject.busy)

    def test_manual_change_during_first_level_cancels_second_level(self):
        subject = self.instance
        purifier = FakePurifier(level=6)
        subject.device = purifier
        subject.start_test_strategy([8, 10])
        purifier.level = 11
        subject.finish_test()
        self.assertEqual(purifier.level, 11)
        self.assertEqual(subject.verified, set())
        self.assertIsNone(subject.test_session)
        self.assertNotIn(("level", 10), purifier.writes)
    def test_calibration_recovers_after_restart_without_marking_verified(self):
        purifier = FakePurifier(mode="auto", level=6)
        self.instance.device = purifier
        self.instance.start_test(8)
        restarted = worker.Worker()
        restarted.device = purifier
        restarted.poll_device(check_ownership=False)
        restarted._reconcile_cold_snapshot()
        self.assertEqual((purifier.mode, purifier.level), ("auto", 6))
        self.assertEqual(restarted.verified, set())


    def test_pending_restore_blocks_enable_until_explicit_stop_recovers(self):
        subject = self.instance
        purifier = FakePurifier(level=9)
        subject.device = purifier
        subject.config = worker.Config(mediumLevel=8, highLevel=10)
        subject.verified = {8, 10}
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()
        subject.owner = True
        subject.snapshot = {"power": True, "mode": "favorite", "level": 6}
        subject.expected = {"power": True, "mode": "favorite", "level": 9}
        with patch.object(purifier, "status", side_effect=OSError):
            subject._restore("恢复")
        subject.poll_device()
        with self.assertRaises(ValueError):
            subject.handle_command({"op": "enable"})
        self.assertEqual(purifier.level, 9)
        subject.handle_command({"op": "stop"})
        self.assertEqual(purifier.level, 6)
        subject.handle_command({"op": "enable"})
        self.assertEqual(subject.mode, "enabled")


    def test_changed_device_never_replays_previous_device_snapshot(self):
        self.instance.snapshot = {"power": True, "mode": "favorite", "level": 2}
        self.instance.expected = {"power": True, "mode": "favorite", "level": 8}
        self.instance.verified = {5, 6}
        self.instance.config = worker.Config(mediumLevel=5, highLevel=6)
        self.instance.persist()
        worker.DEVICE_PATH.write_text(json.dumps({"credentialId": "different-device"}))
        restarted = worker.Worker()
        purifier = FakePurifier(level=8)
        restarted.device = purifier
        restarted.poll_device(check_ownership=False)
        restarted._reconcile_cold_snapshot()
        self.assertEqual(purifier.level, 8)
        self.assertEqual(purifier.writes, [])
        self.assertEqual(restarted.verified, set())
        self.assertIsNone(restarted.config.mediumLevel)
        self.assertEqual(restarted.mode, "paused")

    def test_manual_purifier_accepts_unverified_bounds_then_restores_original_favorite_state(self):
        subject = self.instance
        purifier = FakePurifier(mode="favorite", level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.verified = {5, 6}
        subject.config = worker.Config(mediumLevel=0, highLevel=17)
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()
        emitted = []
        subject._output = emitted.append

        subject.process_command({"id": "manual-0", "op": "manualPurifier", "level": 0})
        subject.process_command({"id": "manual-17", "op": "manualPurifier", "level": 17})
        subject.process_command({"id": "release", "op": "releaseManualPurifier"})

        self.assertEqual([item["success"] for item in emitted], [True, True, True])
        self.assertEqual(emitted[0]["status"]["device"]["level"], 0)
        self.assertEqual(emitted[1]["status"]["device"]["level"], 17)
        self.assertEqual((purifier.mode, purifier.level), ("favorite", 4))
        self.assertEqual((subject.mode, subject.intent_enabled, subject.manual_paused),
                         ("paused", False, True))
        self.assertFalse(subject.owner)
        self.assertIsNone(subject.snapshot)
        self.assertEqual(subject.verified, {5, 6})
        self.assertFalse(subject.can_enable())
        events = subject.history.snapshot(
            device_id=subject.history_device_identity, hours=1, now=worker.time.time()
        )["events"]
        self.assertEqual([event["kind"] for event in events],
                         ["connection", "takeover", "manual", "manual", "restore"])

    def test_enable_from_manual_restores_original_state_before_automatic(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.config = worker.Config(mediumLevel=5, highLevel=6)
        subject.verified = {5, 6}
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()

        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        subject.handle_command({"op": "enable"})

        self.assertEqual((purifier.mode, purifier.level), ("auto", 4))
        self.assertEqual((subject.mode, subject.intent_enabled, subject.manual_paused),
                         ("enabled", True, False))
        self.assertFalse(subject.owner)
        self.assertIsNone(subject.snapshot)

    def test_enable_from_manual_restore_failure_keeps_evidence_and_stays_paused(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.config = worker.Config(mediumLevel=5, highLevel=6)
        subject.verified = {5, 6}
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()
        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        snapshot, expected = dict(subject.snapshot), dict(subject.expected)
        purifier.writes.clear()

        with patch.object(purifier, "status", side_effect=OSError), self.assertRaises(ValueError):
            subject.handle_command({"op": "enable"})

        self.assertEqual((subject.mode, subject.intent_enabled, subject.manual_paused),
                         ("paused", False, True))
        self.assertEqual((subject.snapshot, subject.expected), (snapshot, expected))
        self.assertEqual(purifier.writes, [])

    def test_enable_from_manual_does_not_power_on_an_off_device(self):
        subject = self.instance
        purifier = FakePurifier(level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.config = worker.Config(mediumLevel=5, highLevel=6)
        subject.verified = {5, 6}
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()
        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        purifier.writes.clear()
        purifier.power = False

        with self.assertRaises(ValueError):
            subject.handle_command({"op": "enable"})

        self.assertFalse(purifier.power)
        self.assertEqual(purifier.writes, [])
        self.assertNotEqual(subject.mode, "enabled")

    def test_enable_after_external_change_does_not_overwrite_device(self):
        subject = self.instance
        purifier = FakePurifier(level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.config = worker.Config(mediumLevel=5, highLevel=6)
        subject.verified = {5, 6}
        subject.sensor_received_mono = worker.time.monotonic()
        subject.sensor_source_wall = worker.time.time()
        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        purifier.writes.clear()
        purifier.level = 7

        subject.handle_command({"op": "enable"})

        self.assertEqual(purifier.level, 7)
        self.assertEqual(purifier.writes, [])
        self.assertEqual(subject.mode, "enabled")
        self.assertFalse(subject.owner)

    def test_manual_purifier_rejects_invalid_levels_and_unavailable_device_without_writes(self):
        subject = self.instance
        purifier = FakePurifier(level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.verified = {5}

        for level in (True, -1, 18, 5.0):
            with self.subTest(level=level), self.assertRaises(ValueError):
                subject.handle_command({"id": "invalid", "op": "manualPurifier", "level": level})
        self.assertEqual(purifier.writes, [])
        subject.account["paired"] = False
        with self.assertRaisesRegex(ValueError, "连接"):
            subject.handle_command({"id": "unpaired", "op": "manualPurifier", "level": 5})
        purifier.power = False
        subject.account["paired"] = True
        with self.assertRaisesRegex(ValueError, "开启"):
            subject.handle_command({"id": "off", "op": "manualPurifier", "level": 5})
        self.assertEqual(purifier.writes, [])

    def test_manual_purifier_yields_to_external_change_without_overwriting_it(self):
        subject = self.instance
        purifier = FakePurifier(level=4)
        subject.device = purifier
        subject.account["paired"] = True
        subject.verified = {5}
        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        purifier.writes.clear()

        purifier.level = 7
        self.assertTrue(subject.poll_device())

        self.assertEqual(purifier.level, 7)
        self.assertEqual(purifier.writes, [])
        self.assertEqual((subject.mode, subject.intent_enabled, subject.manual_paused),
                         ("paused", False, True))
        self.assertFalse(subject.owner)
        self.assertIsNone(subject.snapshot)

    def test_switching_from_automatic_takeover_to_manual_preserves_original_snapshot(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=6)
        subject.device = purifier
        subject.account["paired"] = True
        subject.verified = {5}
        subject.mode = "enabled"
        subject.intent_enabled = True
        subject.poll_device()
        self.assertTrue(subject._write_level(8))

        subject.handle_command({"id": "manual", "op": "manualPurifier", "level": 5})
        self.assertEqual(subject.snapshot, {"power": True, "mode": "auto", "level": 6})
        self.assertEqual((subject.mode, subject.intent_enabled), ("manual", False))
        subject.handle_command({"id": "release", "op": "releaseManualPurifier"})

        self.assertEqual((purifier.mode, purifier.level), ("auto", 6))
        self.assertEqual(subject.mode, "paused")

    def test_manual_write_failure_is_not_acknowledged_and_keeps_recovery_evidence(self):
        subject = self.instance
        purifier = FakePurifier(mode="auto", level=6)
        subject.device = purifier
        subject.account["paired"] = True
        subject.verified = {5}
        emitted = []
        subject._output = emitted.append

        def fail_after_write(level):
            purifier.writes.append(("level", level))
            purifier.level = level
            raise OSError("feedback lost")

        with patch.object(purifier, "set_favorite_level", side_effect=fail_after_write):
            subject.process_command({"id": "manual-failure", "op": "manualPurifier", "level": 5})

        self.assertEqual(len(emitted), 1)
        self.assertEqual((emitted[0]["id"], emitted[0]["success"]), ("manual-failure", False))
        self.assertEqual(subject.command_state, "unknown")
        self.assertEqual(subject.snapshot, {"power": True, "mode": "auto", "level": 6})
        self.assertEqual(subject.expected, {"power": True, "mode": "favorite", "level": 5})
        self.assertEqual((subject.mode, subject.intent_enabled, subject.manual_paused),
                         ("paused", False, True))

if __name__ == "__main__":
    unittest.main()
