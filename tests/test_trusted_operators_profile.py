import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TrustedOperatorProfileTests(unittest.TestCase):
    def test_opt_in_preserves_specialist_identity_and_diagnostic_isolation(self):
        patch = json.loads((ROOT / "config/openclaw-trusted-operators.patch.json").read_text())
        self.assertEqual(set(patch["agents"]["entries"]), {"main", "orchestrator", "fitness"})
        for agent in patch["agents"]["entries"].values():
            for identity in ("workspace", "agentDir", "skills", "model", "memory"):
                self.assertNotIn(identity, agent)
            self.assertEqual(agent["sandbox"], {"mode": "off"})
            self.assertEqual(agent["tools"]["profile"], "full")
            self.assertEqual(agent["tools"]["exec"]["mode"], "full")
            self.assertFalse(agent["tools"]["exec"]["applyPatch"]["workspaceOnly"])
            self.assertFalse(agent["tools"]["fs"]["workspaceOnly"])
            self.assertEqual(agent["tools"]["elevated"], {"enabled": True})
        for guard in ("channels", "commands", "secrets", "auth", "gateway", "browser", "cron", "hooks"):
            self.assertNotIn(guard, patch)
        self.assertNotIn("defaults", patch["agents"])
        self.assertEqual(patch["tools"]["agentToAgent"]["allow"], ["main", "orchestrator", "fitness"])
        self.assertEqual(patch["messages"], {"groupChat": {"visibleReplies": "automatic"}})


if __name__ == "__main__":
    unittest.main()
