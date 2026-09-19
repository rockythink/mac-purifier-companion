import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from link_rules import Config, RuleEngine, still_owned


class LinkRulesTests(unittest.TestCase):
    def setUp(self):
        self.config = Config(
            riseSeconds=60, fallSeconds=180, minAdjustSeconds=60,
            mediumLevel=5, highLevel=9,
        )

    def test_dwell_resets_when_condition_breaks(self):
        rules = RuleEngine(self.config)
        self.assertIsNone(rules.update(72, 0))
        self.assertIsNone(rules.update(69, 59))
        self.assertIsNone(rules.update(72, 60))
        self.assertIsNone(rules.update(72, 119))
        decision = rules.update(72, 120)
        self.assertEqual(decision.target, "medium")
    def test_dwell_uses_latest_observed_sample_time(self):
        rules = RuleEngine(self.config)
        rules.update(72, 10)
        rules.update(72, 30)
        self.assertEqual(rules.dwell(), [
            {"name": "medium", "elapsed": 20, "required": 60},
        ])

    def test_high_priority_skips_medium_and_hysteresis_prevents_chatter(self):
        rules = RuleEngine(self.config)
        rules.update(86, 0)
        decision = rules.update(86, 60)
        self.assertEqual(decision.target, "high")
        rules.commit(decision.target, 60)

        # Between down and high thresholds, high remains stable.
        self.assertIsNone(rules.update(80, 240))
        self.assertIsNone(rules.update(78, 241))
        decision = rules.update(78, 421)
        self.assertEqual(decision.target, "medium")

    def test_exit_has_priority_and_ignores_adjust_cooldown(self):
        rules = RuleEngine(self.config, "high")
        rules.commit("medium", 100)
        rules.update(60, 101)
        decision = rules.update(60, 281)
        self.assertEqual(decision.target, "standby")

    def _descending_with_exit_progress(self):
        rules = RuleEngine(self.config, "high")
        self.assertIsNone(rules.update(70, 0))
        for now in range(2, 180, 2):
            self.assertIsNone(rules.update(60, now))
        decision = rules.update(60, 180)
        self.assertEqual(decision.target, "medium")
        rules.commit(decision.target, 180)
        return rules

    def test_continuous_low_temperature_survives_high_to_medium(self):
        rules = self._descending_with_exit_progress()
        decision = rules.update(60, 182)
        self.assertIsNotNone(decision)
        self.assertEqual(decision.target, "standby")

    def test_preserved_exit_progress_still_resets_after_interruption(self):
        for interrupted_temperature in (self.config.exitThreshold + 1, None):
            with self.subTest(temperature=interrupted_temperature):
                rules = self._descending_with_exit_progress()
                self.assertIsNone(rules.update(interrupted_temperature, 182))
                for now in range(184, 364, 2):
                    self.assertIsNone(rules.update(60, now))
                self.assertEqual(rules.update(60, 364).target, "standby")

    def test_stale_gap_and_invalid_sample_reset_dwell(self):
        rules = RuleEngine(self.config)
        rules.update(75, 0)
        self.assertIsNone(rules.update(75, 181))  # discontinuity: starts again
        self.assertIsNone(rules.update(None, 200, valid=False))
        self.assertIsNone(rules.update(75, 201))
        self.assertEqual(rules.update(75, 261).target, "medium")

    def test_transition_requires_commit(self):
        rules = RuleEngine(self.config)
        rules.update(72, 0)
        self.assertEqual(rules.update(72, 60).target, "medium")
        self.assertEqual(rules.phase, "standby")

    def test_ownership_ignores_rpm_but_detects_manual_change(self):
        expected = {"power": True, "mode": "favorite", "level": 9}
        self.assertTrue(still_owned(expected, {**expected, "rpm": 1600}))
        self.assertFalse(still_owned(expected, {**expected, "level": 8, "rpm": 1600}))
        self.assertFalse(still_owned(expected, {**expected, "power": False}))

    def test_config_rejects_unsafe_mapping_and_thresholds(self):
        with self.assertRaises(ValueError):
            Config.from_dict({**self.config.to_dict(), "mediumLevel": 10, "highLevel": 9})
        with self.assertRaises(ValueError):
            Config.from_dict({**self.config.to_dict(), "exitThreshold": 75})


if __name__ == "__main__":
    unittest.main()
