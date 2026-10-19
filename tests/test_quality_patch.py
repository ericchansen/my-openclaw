import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("quality_patch", ROOT / "scripts/sync-quality-patch.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class QualityPatchTests(unittest.TestCase):
    def setUp(self):
        self.template = json.loads((ROOT / "config/openclaw.template.json").read_text(encoding="utf-8"))

    def test_generation_preserves_committed_migration_semantics(self):
        original = json.loads(json.dumps(self.template))
        expected = json.loads((ROOT / "config/openclaw-quality.patch.json").read_text(encoding="utf-8"))
        self.assertEqual(MODULE.quality_patch(self.template), expected)
        self.assertEqual(self.template, original)
        self.assertIsNone(expected["agents"]["defaults"]["sandbox"]["docker"]["ulimits"]["nproc"])
        self.assertEqual(expected["hooks"]["allowedAgentIds"], ["main"])

    def test_browser_uses_defaults_and_removes_previous_overrides(self):
        self.assertEqual(self.template["browser"], {"headless": True})
        browser = MODULE.quality_patch(self.template)["browser"]
        self.assertTrue(browser["headless"])
        for key in (
            "enabled", "allowSystemProfileImport", "evaluateEnabled", "noSandbox",
            "attachOnly", "defaultProfile", "snapshotDefaults", "tabCleanup",
        ):
            self.assertIn(key, browser)
            self.assertIsNone(browser[key])
        self.assertEqual(browser["extensionRelay"], {"allowLegacyAuth": None})
        self.assertEqual(browser["ssrfPolicy"], {
            "dangerouslyAllowPrivateNetwork": None,
            "allowRfc2544BenchmarkRange": None,
            "allowIpv6UniqueLocalRange": None,
        })
        self.assertNotIn("profiles", browser)

    def test_migration_preserves_personal_paths_and_inherits_delegation_behavior(self):
        result = MODULE.quality_patch(self.template)
        self.assertEqual(set(result["agents"]["entries"]),
                         {"main", "orchestrator", "fitness", "healthcheck"})
        self.assertNotIn("allow", result["tools"]["agentToAgent"])
        self.assertNotIn("visibility", result["tools"]["sessions"])
        self.assertNotIn("deny", result["tools"]["subagents"]["tools"])
        self.assertNotIn("delegationMode", self.template["agents"]["defaults"]["subagents"])
        self.assertIsNone(result["agents"]["defaults"]["subagents"]["delegationMode"])
        for agent_id in ("main", "orchestrator", "fitness"):
            agent = result["agents"]["entries"][agent_id]
            self.assertNotIn("identity", agent)
            self.assertNotIn("workspace", agent)
            self.assertEqual(agent["subagents"], {"delegationMode": None})

    def test_fresh_install_fields_do_not_enter_migration_patch(self):
        result = MODULE.quality_patch(self.template)
        for key in ("channels", "bindings", "secrets", "auth", "mcp", "messages"):
            self.assertNotIn(key, result)
        for path in MODULE.EXCLUDED_PATHS:
            parent = result
            for part in path.split(".")[:-1]:
                parent = parent[part]
            self.assertNotIn(path.split(".")[-1], parent)
        self.template["agents"]["defaults"]["maxConcurrent"] = 3
        self.assertEqual(MODULE.quality_patch(self.template)["agents"]["defaults"]["maxConcurrent"], 3)

    def test_check_rejects_drift_without_writing_and_sync_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            (root / "config/openclaw.template.json").write_text(
                json.dumps(self.template), encoding="utf-8")
            output = root / "config/openclaw-quality.patch.json"
            output.write_text("{}", encoding="utf-8")
            with patch.object(MODULE, "ROOT", root):
                with patch("sys.argv", ["sync-quality-patch.py", "--check"]):
                    with self.assertRaisesRegex(ValueError, "Quality patch is stale"):
                        MODULE.main()
                    self.assertEqual(output.read_text(), "{}")
                with patch("sys.argv", ["sync-quality-patch.py"]):
                    MODULE.main()
                    before = output.stat().st_mtime_ns
                    MODULE.main()
                    self.assertEqual(output.stat().st_mtime_ns, before)
                with patch("sys.argv", ["sync-quality-patch.py", "--check"]):
                    MODULE.main()


if __name__ == "__main__":
    unittest.main()
