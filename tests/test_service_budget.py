import configparser
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ServiceBudgetTests(unittest.TestCase):
    def unit(self, name):
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.read(ROOT / "config" / name)
        return parser["Service"]

    def test_gateway_keeps_administration_headroom_on_capacity_profile(self):
        unit = self.unit("openclaw-gateway.service")
        self.assertEqual(unit["MemoryHigh"], "3G")
        self.assertEqual(unit["MemoryMax"], "4G")
        self.assertEqual(unit["MemorySwapMax"], "512M")
        self.assertEqual(unit["OOMPolicy"], "stop")
        self.assertEqual(unit["TasksMax"], "1024")
        self.assertEqual(unit["RestartPreventExitStatus"], "78")

    def test_background_services_have_explicit_smaller_budgets(self):
        for name, maximum in (
            ("openclaw-health.service", "2G"),
            ("openclaw-backup.service", "2G"),
            ("openclaw-otel-collector.service", "512M"),
        ):
            with self.subTest(unit=name):
                unit = self.unit(name)
                self.assertEqual(unit["MemoryMax"], maximum)
                self.assertIn("MemoryHigh", unit)
                self.assertIn("MemorySwapMax", unit)

    def test_resource_controls_do_not_disable_enabled_features(self):
        for name in ("openclaw.template.json", "openclaw-quality.patch.json"):
            with self.subTest(config=name):
                config = json.loads((ROOT / "config" / name).read_text())
                defaults = config["agents"]["defaults"]
                self.assertEqual(defaults["maxConcurrent"], 2)
                self.assertEqual(defaults["subagents"]["maxConcurrent"], 2)
                self.assertTrue(defaults["sandbox"]["browser"]["enabled"])
                self.assertEqual(defaults["sandbox"]["scope"], "session")
                self.assertEqual(defaults["sandbox"]["prune"]["idleHours"], 1)
                self.assertTrue(config["plugins"]["entries"]["active-memory"]["enabled"])
                self.assertTrue(config["plugins"]["entries"]["memory-core"]["config"]["dreaming"]["enabled"])
                for agent in ("main", "orchestrator"):
                    self.assertEqual(config["agents"]["entries"][agent]["sandbox"]["scope"], "agent")

    def test_managed_mcp_catalog_does_not_inherit_tiny_listing_timeout(self):
        for name in ("openclaw.template.json", "openclaw-mcp-timeouts.patch.json"):
            with self.subTest(config=name):
                config = json.loads((ROOT / "config" / name).read_text())
                for server in ("ebird", "pondlog"):
                    self.assertEqual(config["mcp"]["servers"][server]["requestTimeoutMs"], 60000)
                    self.assertEqual(config["mcp"]["servers"][server]["connectionTimeoutMs"], 30000)


if __name__ == "__main__":
    unittest.main()
