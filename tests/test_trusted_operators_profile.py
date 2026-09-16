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

    def test_inline_eval_override_is_explicit_and_limited_to_trusted_agents(self):
        patch = json.loads((ROOT / "config/openclaw-trusted-operators.patch.json").read_text())
        self.assertNotIn("exec", patch["tools"])
        for filename in ("openclaw.template.json", "openclaw-quality.patch.json"):
            baseline = json.loads((ROOT / "config" / filename).read_text())
            global_exec = baseline["tools"]["exec"]
            self.assertTrue(global_exec["strictInlineEval"])
            for agent_id in ("main", "orchestrator", "fitness", "healthcheck"):
                with self.subTest(baseline=filename, agent=agent_id):
                    baseline_agent = baseline["agents"]["entries"].get(agent_id, {})
                    overlay_agent = patch["agents"]["entries"].get(agent_id, {})
                    effective_exec = {
                        **global_exec,
                        **baseline_agent.get("tools", {}).get("exec", {}),
                        **overlay_agent.get("tools", {}).get("exec", {}),
                    }
                    if agent_id == "healthcheck":
                        self.assertTrue(effective_exec["strictInlineEval"])
                    else:
                        self.assertIs(overlay_agent["tools"]["exec"]["strictInlineEval"], False)
                        self.assertIs(effective_exec["strictInlineEval"], False)


if __name__ == "__main__":
    unittest.main()
