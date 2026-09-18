import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import host_metrics


class ProcessCalculationTests(unittest.TestCase):
    def test_ranks_top_three_and_uses_one_logical_core_as_100_percent(self):
        first = {
            10: ((1, 0), "one-core", 0),
            20: ((2, 0), "two-core", 0),
            30: ((3, 0), "half-core", 0),
            40: ((4, 0), "idle", 0),
        }
        second = {
            10: ((1, 0), "one-core", 24_000_000),
            20: ((2, 0), "two-core", 48_000_000),
            30: ((3, 0), "half-core", 12_000_000),
            40: ((4, 0), "idle", 0),
        }

        result = host_metrics._calculate_processes(first, second, 1.0, (125, 3))

        self.assertEqual([item["pid"] for item in result], [20, 10, 30])
        self.assertEqual([item["cpuPercent"] for item in result], [200.0, 100.0, 50.0])

    def test_ignores_exits_pid_reuse_counter_reset_and_nonfinite_counters(self):
        first = {
            1: ((1, 0), "exited", 10),
            2: ((2, 0), "old-process", 10),
            3: ((3, 0), "reset", 10),
            4: ((4, 0), "nonfinite", 10),
            5: ((5, 0), "valid", 10),
        }
        second = {
            2: ((20, 0), "new-process", 100),
            3: ((3, 0), "reset", 9),
            4: ((4, 0), "nonfinite", math.inf),
            5: ((5, 0), "valid", 20),
        }

        result = host_metrics._calculate_processes(first, second, 1.0, (1, 1))

        self.assertEqual(result, [{"pid": 5, "name": "valid", "cpuPercent": 0.000001}])
        self.assertEqual(host_metrics._calculate_processes(first, second, math.nan, (1, 1)), [])
        self.assertEqual(host_metrics._calculate_processes(first, second, 0, (1, 1)), [])

    def test_valid_idle_sample_is_not_reported_as_unavailable(self):
        readings = {
            1: ((1, 0), "idle-a", 100),
            2: ((2, 0), "idle-b", 200),
        }
        with (
            patch.object(host_metrics.sys, "platform", "darwin"),
            patch.object(host_metrics, "_read_processes", side_effect=[readings, readings]),
            patch.object(host_metrics, "_mach_timebase", return_value=(125, 3)),
            patch.object(host_metrics.time, "sleep"),
            patch.object(host_metrics.time, "monotonic", side_effect=[10.0, 11.0]),
            patch.object(host_metrics.time, "time", return_value=1234.0),
        ):
            result = host_metrics.sample_top_processes()

        self.assertEqual(result["timestamp"], 1234.0)
        self.assertIsNone(result["error"])
        self.assertEqual(
            result["processes"],
            [
                {"pid": 1, "name": "idle-a", "cpuPercent": 0.0},
                {"pid": 2, "name": "idle-b", "cpuPercent": 0.0},
            ],
        )

    def test_failure_does_not_expose_exception_details(self):
        with (
            patch.object(host_metrics.sys, "platform", "darwin"),
            patch.object(
                host_metrics,
                "_read_processes",
                side_effect=OSError("private path /Users/person/secret"),
            ),
        ):
            result = host_metrics.sample_top_processes()

        self.assertEqual(result["timestamp"], None)
        self.assertEqual(result["processes"], [])
        self.assertTrue(result["error"])
        self.assertNotIn("/Users/person/secret", result["error"])

    def test_unsupported_platform_reports_unavailable(self):
        with patch.object(host_metrics.sys, "platform", "linux"):
            self.assertEqual(
                host_metrics.sample_top_processes(),
                {
                    "timestamp": None,
                    "processes": [],
                    "error": "unsupported platform",
                },
            )
            self.assertEqual(
                host_metrics.read_system_conditions(),
                {"thermalState": None, "memoryPressure": None},
            )


class MemoryPressureTests(unittest.TestCase):
    def test_maps_public_dispatch_flags_not_internal_kernel_levels(self):
        for value, expected in ((1, "normal"), (2, "warning"), (4, "critical"), (0, None), (3, None), (None, None)):
            with self.subTest(value=value), patch.object(host_metrics.sys, "platform", "darwin"), patch.object(host_metrics, "_thermal_state", return_value="nominal"), patch.object(host_metrics, "_read_int_sysctl", return_value=value):
                self.assertEqual(host_metrics.read_system_conditions()["memoryPressure"], expected)


if __name__ == "__main__":
    unittest.main()
