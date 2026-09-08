import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "openclaw-install-policy.py"


class CopilotHarnessPolicyTests(unittest.TestCase):
    def fixture(self):
        data = json.loads((ROOT / "tests/fixtures/install-policy-allow-diagnostics-preflight.json").read_text())
        data["targetName"] = "copilot"
        data["request"]["requestedSpecifier"] = "npm:@openclaw/copilot@2026.9.2"
        data["origin"]["packageName"] = "@openclaw/copilot"
        data["plugin"] = {"pluginId": "copilot", "contentType": "package", "packageName": "@openclaw/copilot"}
        return data

    def decision(self, data):
        result = subprocess.run([sys.executable, str(HELPER)], input=json.dumps(data),
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)["decision"]

    def test_exact_official_package_is_allowed(self):
        self.assertEqual(self.decision(self.fixture()), "allow")

    def test_clawhub_marketplace_requires_review_even_with_official_provenance(self):
        data = json.loads((ROOT / "tests/fixtures/install-policy-review-clawhub.json").read_text())
        for mode in ("install", "update"):
            for authority in ("openclaw", "official", "third-party"):
                with self.subTest(mode=mode, authority=authority):
                    data["request"]["mode"] = mode
                    data["source"]["authority"] = authority
                    self.assertEqual(self.decision(data), "warn")
        for kind in ("bundled", "managed"):
            data["source"].update(kind=kind, authority="openclaw", network=False)
            self.assertEqual(self.decision(data), "allow")

    def test_unreviewed_package_versions_and_tags_are_blocked(self):
        for version in ("latest", "2026.9.1", "2026.9.3"):
            data = self.fixture()
            data["request"]["requestedSpecifier"] = f"npm:@openclaw/copilot@{version}"
            self.assertEqual(self.decision(data), "block")

    def test_local_mutable_or_mismatched_plugin_cannot_impersonate_pin(self):
        original = self.fixture()
        for change in ("local", "mutable", "identity", "version"):
            data = copy.deepcopy(original)
            if change == "local":
                data["source"]["kind"] = "local-path"
            elif change == "mutable":
                data["source"]["mutable"] = True
            else:
                data["plugin"] = {"packageName": "@openclaw/copilot", "pluginId": "copilot", "version": "2026.9.2"}
                data["plugin"]["pluginId" if change == "identity" else "version"] = "unexpected"
            self.assertEqual(self.decision(data), "block")

    def test_policy_and_optional_harness_manifest_versions_agree(self):
        spec = importlib.util.spec_from_file_location("policy", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = json.loads((ROOT / "config/runtime-versions.json").read_text())
        self.assertEqual(module.EXACT_PACKAGES["@openclaw/copilot"],
                         manifest["packages"]["@openclaw/copilot"]["version"])
        self.assertIn(
            f'@openclaw/diagnostics-otel@{manifest["packages"]["@openclaw/diagnostics-otel"]["version"]}',
            (ROOT / "docs/telemetry-privacy.md").read_text(),
        )

    def test_astra_overlay_is_model_scoped_and_preserves_working_fallback(self):
        patch = json.loads((ROOT / "config/openclaw-astra.patch.json").read_text())
        defaults = patch["agents"]["defaults"]
        self.assertEqual(defaults["model"]["primary"], "github-copilot/gpt-6-astra")
        self.assertEqual(defaults["model"]["fallbacks"], ["github-copilot/claude-sonnet-5"])
        self.assertEqual(defaults["models"], {
            "github-copilot/gpt-6-astra": {"alias": "astra", "agentRuntime": {"id": "copilot"}}})
        self.assertNotIn("allow", patch["plugins"])
        for unrelated in ("channels", "tools", "commands", "session", "secrets", "cron", "hooks"):
            self.assertNotIn(unrelated, patch)

    def test_astra_canary_retains_native_exit_status_receipts(self):
        patch = json.loads((ROOT / "config/openclaw-astra.patch.json").read_text())
        self.assertEqual(patch["agents"]["entries"]["healthcheck"], {"model": {
            "primary": "github-copilot/gpt-5.6-luna",
            "fallbacks": ["github-copilot/claude-sonnet-5"],
        }})
        for model in ("github-copilot/gpt-5.6-luna", "github-copilot/claude-sonnet-5"):
            self.assertNotIn(model, patch["agents"]["defaults"]["models"])

    def test_cli_environment_override_is_explicit_and_has_no_credentials(self):
        text = (ROOT / "config/openclaw-copilot.conf").read_text()
        self.assertEqual(text.splitlines(), [
            "[Service]", "Environment=COPILOT_CLI_PATH=/usr/local/libexec/copilot"])


if __name__ == "__main__":
    unittest.main()
