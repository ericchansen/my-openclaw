"""Keep ordinary family conversations independent of optional browser startup."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AvailabilityConfigTests(unittest.TestCase):
    def test_template_uses_container_not_shared_uid_process_budget(self):
        config = json.loads((ROOT / "config/openclaw.template.json").read_text())
        docker = config["agents"]["defaults"]["sandbox"]["docker"]
        self.assertNotIn("nproc", docker["ulimits"])
        self.assertGreater(docker["pidsLimit"], 0)
        self.assertEqual(docker["user"], "1000:1000")
        self.assertEqual(docker["capDrop"], ["ALL"])

    def test_overlay_removes_existing_shared_uid_limit(self):
        patch = json.loads((ROOT / "config/openclaw-quality.patch.json").read_text())
        limits = patch["agents"]["defaults"]["sandbox"]["docker"]["ulimits"]
        self.assertIn("nproc", limits)
        self.assertIsNone(limits["nproc"])

    def test_chat_does_not_require_eager_browser_or_tool_directory(self):
        for name in ("openclaw.template.json", "openclaw-quality.patch.json"):
            with self.subTest(name=name):
                config = json.loads((ROOT / "config" / name).read_text())
                sandbox = config["agents"]["defaults"]["sandbox"]
                self.assertEqual(sandbox["mode"], "non-main")
                self.assertFalse(sandbox["browser"]["autoStart"])
                self.assertFalse(sandbox["browser"]["allowHostControl"])
                self.assertFalse(config["tools"]["toolSearch"]["enabled"])

    def test_canary_is_not_a_private_data_or_message_agent(self):
        for name in ("openclaw.template.json", "openclaw-quality.patch.json"):
            with self.subTest(name=name):
                config = json.loads((ROOT / "config" / name).read_text())
                agent = config["agents"]["entries"]["healthcheck"]
                self.assertEqual(agent["tools"]["allow"], ["exec"])
                self.assertFalse(agent["tools"]["elevated"]["enabled"])
                self.assertEqual(agent["sandbox"]["mode"], "all")
                self.assertEqual(agent["sandbox"]["workspaceAccess"], "none")
                self.assertFalse(agent["sandbox"]["browser"]["enabled"])
                self.assertFalse(agent["memory"]["search"]["enabled"])
                self.assertEqual(agent["heartbeat"]["every"], "0m")
                self.assertTrue(agent["workspace"].endswith("workspace-healthcheck"))


if __name__ == "__main__":
    unittest.main()
