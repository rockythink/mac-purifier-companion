import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
import time
from unittest.mock import patch

from scripts.history_store import HistoryStore


class HistoryStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = HistoryStore(Path(self.temporary.name) / "history.sqlite3")

    def tearDown(self):
        self.temporary.cleanup()

    def record(self, timestamp, *, device="device-a", session="session-a", cpu=70.0,
               load=50.0, owner=False, mode="enabled", phase="standby", interval=20.0,
               gpu_load=30.0, pressure="normal"):
        self.store.record(
            timestamp=timestamp, device_id=device, session_id=session, cpu=cpu, gpu=55.0,
            cpu_load=load, gpu_load=gpu_load, memory_used=8, memory_total=16, swap_used=1,
            memory_pressure=pressure, thermal_state="nominal",
            mac_fans=[{"name": "Left", "rpm": 1200, "maxRPM": 6000}],
            rpm=1100.0 if device else None, level=7 if device else None,
            device_mode="favorite" if device else None, worker_mode=mode,
            owner=owner, phase=phase, sample_interval=interval, now=timestamp,
        )

    def test_segments_break_across_gaps_restarts_and_control_phases(self):
        self.record(1000)
        self.record(1020)
        self.record(1100)
        self.record(1120, session="session-b")
        self.record(1140, session="session-b", phase="medium", owner=True)
        segments = [point["segment"] for point in self.store.snapshot(device_id="device-a", hours=1, now=1200)["points"]]
        self.assertEqual(segments[0], segments[1])
        self.assertNotEqual(segments[1], segments[2])
        self.assertNotEqual(segments[2], segments[3])
        self.assertNotEqual(segments[3], segments[4])

    def test_snapshot_is_host_wide_and_preserves_device_identity(self):
        self.record(1000, device="device-a", cpu=61)
        self.record(1020, device="device-b", cpu=92)
        self.record(1040, device=None, cpu=None)
        result = self.store.snapshot(device_id="device-a", hours=1, now=1100)
        self.assertEqual(result["totalSamples"], 3)
        self.assertEqual([point["deviceId"] for point in result["points"]], ["device-a", "device-b", None])
        self.assertEqual([point["cpu"] for point in result["points"]], [61, 92, None])

    def test_comparison_requires_real_owned_contiguous_selected_device(self):
        for timestamp in range(1000, 1321, 20):
            self.record(timestamp, cpu=80, load=45)
        for timestamp in range(1340, 1661, 20):
            self.record(timestamp, cpu=72, load=48, owner=True, phase="medium")
        comparison = self.store.snapshot(device_id="device-a", hours=1, now=1700)["comparison"]
        self.assertIsNotNone(comparison)
        self.assertEqual(comparison["baselineCPU"], 80)
        self.assertEqual(comparison["linkedCPU"], 72)
        self.assertEqual(comparison["deltaCPU"], 8)
        self.assertEqual(comparison["baselineLoad"], 45)
        self.assertEqual(comparison["linkedLoad"], 48)
        self.assertIn("不代表", comparison["message"])
        self.assertIsNone(self.store.snapshot(device_id="device-b", hours=1, now=1700)["comparison"])

    def test_offline_or_other_device_samples_cannot_form_cross_device_comparison(self):
        for timestamp in range(1000, 1321, 20):
            self.record(timestamp, device="device-a", cpu=90)
        for timestamp in range(1340, 1661, 20):
            self.record(timestamp, device=None, cpu=60, owner=True, phase="medium")
        self.assertIsNone(self.store.snapshot(device_id="device-a", hours=1, now=1700)["comparison"])
        self.assertIsNone(self.store.snapshot(device_id=None, hours=1, now=1700)["comparison"])

    def test_dry_run_and_gapped_owned_samples_never_produce_comparison(self):
        for timestamp in range(1000, 1321, 20):
            self.record(timestamp)
        for timestamp in range(1340, 1661, 20):
            self.record(timestamp, owner=True, mode="dryRun", phase="medium")
        self.assertIsNone(self.store.snapshot(device_id="device-a", hours=1, now=1700)["comparison"])
        self.store = HistoryStore(Path(self.temporary.name) / "gapped.sqlite3")
        for timestamp in range(2000, 2321, 20):
            self.record(timestamp)
        for timestamp in list(range(2340, 2441, 20)) + list(range(2520, 2701, 20)):
            self.record(timestamp, owner=True, phase="medium")
        self.assertIsNone(self.store.snapshot(device_id="device-a", hours=1, now=2750)["comparison"])

    def test_heavy_load_change_is_explicitly_noncomparable(self):
        for timestamp in range(1000, 1321, 20):
            self.record(timestamp, load=20)
        for timestamp in range(1340, 1661, 20):
            self.record(timestamp, load=85, owner=True, phase="medium")
        comparison = self.store.snapshot(device_id="device-a", hours=1, now=1700)["comparison"]
        self.assertIsNotNone(comparison)
        self.assertIn("不可直接比较", comparison["message"])

    def test_retention_and_clear_remove_samples_and_events(self):
        self.record(1000)
        later = 1000 + 31 * 86400
        self.record(later, cpu=None, device=None)
        self.store.record_event(timestamp=later, kind="wake", label="唤醒", now=later)
        result = self.store.snapshot(device_id="device-a", hours=720, now=later)
        self.assertEqual(result["totalSamples"], 1)
        self.assertEqual(len(result["events"]), 1)
        self.store.clear()
        cleared = self.store.snapshot(device_id="device-a", hours=720, now=later)
        self.assertEqual(cleared["totalSamples"], 0)
        self.assertEqual(cleared["events"], [])

    def test_chart_and_events_are_bounded_while_reporting_raw_count(self):
        for timestamp in range(1000, 1000 + 1000 * 20, 20):
            self.record(timestamp)
        for timestamp in range(1900, 2150):
            self.store.record_event(timestamp=timestamp, kind="connection", label="连接", now=timestamp)
        result = self.store.snapshot(device_id="device-a", hours=6, now=1000 + 1000 * 20)
        self.assertEqual(result["totalSamples"], 1000)
        self.assertLessEqual(len(result["points"]), 720)
        self.assertLessEqual(len(result["events"]), 200)

    def test_sparse_load_cannot_imply_comparable_workload(self):
        for timestamp in range(1000, 1321, 20):
            self.record(timestamp, load=50 if timestamp == 1200 else None)
        for timestamp in range(1340, 1661, 20):
            self.record(timestamp, owner=True, phase="medium")
        comparison = self.store.snapshot(device_id="device-a", hours=1, now=1700)["comparison"]
        self.assertIsNone(comparison["baselineLoad"])
        self.assertIn("负载样本不足", comparison["message"])

    def test_history_preserves_boolean_ownership_and_host_metrics(self):
        self.record(1000, owner=True, phase="medium")
        point = self.store.snapshot(device_id="device-a", hours=1, now=1020)["points"][0]
        self.assertIs(point["owner"], True)
        self.assertEqual(point["gpuLoad"], 30)
        self.assertEqual(point["memoryUsed"], 8)
        self.assertEqual(point["macFans"][0]["maxRPM"], 6000)

    def test_legacy_database_migrates_transactionally_without_inventing_fields(self):
        path = Path(self.temporary.name) / "legacy.sqlite3"
        database = sqlite3.connect(path)
        database.executescript("""
            CREATE TABLE samples (timestamp REAL NOT NULL, device_id TEXT NOT NULL,
              session_id TEXT NOT NULL, cpu REAL NOT NULL, gpu REAL, cpu_load REAL, rpm REAL,
              level INTEGER, device_mode TEXT, worker_mode TEXT NOT NULL, owner INTEGER NOT NULL,
              phase TEXT NOT NULL, segment TEXT NOT NULL, sample_interval REAL NOT NULL);
        """)
        timestamp = time.time()
        database.execute("INSERT INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         (timestamp, "legacy-device", "session", 71, 55, 42, 1200, 7,
                          "favorite", "enabled", 1, "medium", "session:1", 20))
        database.commit()
        database.close()
        migrated = HistoryStore(path)
        result = migrated.snapshot(device_id="legacy-device", hours=1, now=timestamp + 1)
        self.assertEqual(result["totalSamples"], 1)
        point = result["points"][0]
        self.assertEqual((point["cpu"], point["deviceId"], point["owner"]), (71, "legacy-device", True))
        self.assertIsNone(point["gpuLoad"])
        self.assertIsNone(point["memoryUsed"])
        self.assertEqual(point["macFans"], [])
        self.assertEqual(result["events"], [])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(path.parent).st_mode & 0o777, 0o700)

    def test_failed_migration_rolls_back_and_leaves_legacy_rows_usable(self):
        path = Path(self.temporary.name) / "rollback.sqlite3"
        database = sqlite3.connect(path)
        database.executescript("""
            CREATE TABLE samples (timestamp REAL NOT NULL, device_id TEXT NOT NULL,
              session_id TEXT NOT NULL, cpu REAL NOT NULL, gpu REAL, cpu_load REAL, rpm REAL,
              level INTEGER, device_mode TEXT, worker_mode TEXT NOT NULL, owner INTEGER NOT NULL,
              phase TEXT NOT NULL, segment TEXT NOT NULL, sample_interval REAL NOT NULL);
            INSERT INTO samples VALUES (1000,'device','session',71,NULL,NULL,NULL,NULL,NULL,
              'stopped',0,'standby','session:1',20);
        """)
        database.close()
        original = HistoryStore._create_samples
        with patch.object(HistoryStore, "_create_samples", side_effect=sqlite3.OperationalError("forced")):
            with self.assertRaises(sqlite3.OperationalError):
                HistoryStore(path)
        database = sqlite3.connect(path)
        try:
            self.assertEqual(database.execute("SELECT cpu FROM samples").fetchall(), [(71.0,)])
            self.assertNotIn("gpu_load", [row[1] for row in database.execute("PRAGMA table_info(samples)")])
        finally:
            database.close()
        self.assertIsNotNone(original)


if __name__ == "__main__":
    unittest.main()
