import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PersonalConfigTests(unittest.TestCase):
    def test_personal_agents_retain_chosen_host_access(self):
        roster = ["main", "orchestrator", "fitness"]
        for filename in ("openclaw.template.json", "openclaw-quality.patch.json"):
            config = json.loads((ROOT / "config" / filename).read_text())
            entries = config["agents"]["entries"]
            self.assertEqual(set(entries), {*roster, "healthcheck"})
            for agent_id in roster:
                with self.subTest(config=filename, agent=agent_id):
                    agent = entries[agent_id]
                    self.assertEqual(agent["sandbox"]["mode"], "off")
                    self.assertEqual(agent["tools"]["profile"], "full")
                    self.assertEqual(agent["tools"]["exec"]["mode"], "full")
                    self.assertFalse(agent["tools"]["exec"]["strictInlineEval"])
                    self.assertFalse(agent["tools"]["exec"]["applyPatch"]["workspaceOnly"])
                    self.assertFalse(agent["tools"]["fs"]["workspaceOnly"])
                    self.assertTrue(agent["tools"]["elevated"]["enabled"])
            diagnostic = entries["healthcheck"]
            self.assertEqual(diagnostic["sandbox"]["mode"], "all")
            self.assertEqual(diagnostic["sandbox"]["workspaceAccess"], "none")
            self.assertEqual(diagnostic["tools"]["allow"], ["exec"])
            self.assertFalse(diagnostic["tools"]["elevated"]["enabled"])
            self.assertTrue(config["tools"]["exec"]["strictInlineEval"])
        template = json.loads((ROOT / "config/openclaw.template.json").read_text())
        for agent_id in roster:
            self.assertEqual(template["agents"]["entries"][agent_id]["subagents"],
                             {"allowAgents": roster})
        self.assertEqual(template["tools"]["agentToAgent"]["allow"], roster)
        self.assertEqual(template["tools"]["sessions"]["visibility"], "all")
        self.assertEqual(template["tools"]["subagents"]["tools"]["deny"], [])
        self.assertEqual(template["messages"]["groupChat"]["visibleReplies"], "automatic")

    def test_personal_memory_features_remain_enabled(self):
        for filename in ("openclaw.template.json", "openclaw-quality.patch.json"):
            config = json.loads((ROOT / "config" / filename).read_text())
            self.assertEqual(config["plugins"]["slots"]["memory"], "memory-core")
            self.assertTrue(config["plugins"]["entries"]["active-memory"]["enabled"])
            self.assertTrue(config["plugins"]["entries"]["memory-wiki"]["enabled"])
            self.assertTrue(config["agents"]["entries"]["main"]["memory"]["search"]
                            ["rememberAcrossConversations"])


if __name__ == "__main__":
    unittest.main()
