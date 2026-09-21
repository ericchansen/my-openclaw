import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "openclaw-install-policy.py"
OFFICIAL_PLUGIN_PACKAGES = {
    "brave": "@openclaw/brave-plugin",
    "copilot": "@openclaw/copilot",
    "diagnostics-otel": "@openclaw/diagnostics-otel",
    "discord": "@openclaw/discord",
}


class CopilotHarnessPolicyTests(unittest.TestCase):
    def fixture(self, plugin_id="copilot", phase="preflight"):
        name = f"install-policy-allow-diagnostics-{phase}.json"
        data = json.loads((ROOT / "tests" / "fixtures" / name).read_text())
        package = OFFICIAL_PLUGIN_PACKAGES[plugin_id]
        data["targetName"] = plugin_id
        data["request"]["requestedSpecifier"] = f"npm:{package}@2026.9.2"
        for metadata in (data["origin"], data["plugin"]):
            for field, value in (("packageName", package), ("pluginId", plugin_id), ("manifestId", plugin_id)):
                if field in metadata:
                    metadata[field] = value
        return data

    def response(self, raw):
        result = subprocess.run([sys.executable, str(HELPER)], input=raw,
                                capture_output=True, check=True, timeout=10)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        response = json.loads(result.stdout)
        self.assertEqual(response["protocolVersion"], 1)
        return response

    def decision(self, data):
        return self.response(json.dumps(data).encode())["decision"]

    def test_repository_fixtures(self):
        for path in sorted((ROOT / "tests" / "fixtures").glob("install-policy-*.json")):
            with self.subTest(fixture=path.name):
                expected = ("block" if "block-" in path.name else
                            "warn" if "review-" in path.name
                            else "allow")
                self.assertEqual(self.decision(json.loads(path.read_text())), expected)

    def test_exact_official_package_is_allowed(self):
        for plugin_id in OFFICIAL_PLUGIN_PACKAGES:
            for phase in ("preflight", "staged", "stable-dependencies"):
                with self.subTest(plugin_id=plugin_id, phase=phase):
                    self.assertEqual(self.decision(self.fixture(plugin_id, phase)), "allow")

    def test_future_core_versions_do_not_disable_policy(self):
        for version in ("2026.9.4", "2030.1.1", "2030.1.1-1"):
            for fixture, expected in (
                ("install-policy-allow-bundled.json", "allow"),
                ("install-policy-allow-diagnostics-preflight.json", "allow"),
                ("install-policy-review-untrusted.json", "warn"),
                ("install-policy-block-diagnostics-source.json", "block"),
            ):
                with self.subTest(version=version, fixture=fixture):
                    data = json.loads((ROOT / "tests" / "fixtures" / fixture).read_text())
                    data["openclawVersion"] = version
                    self.assertEqual(self.decision(data), expected)

    def test_official_stable_versions_are_not_tied_to_the_baseline(self):
        for plugin_id, package in OFFICIAL_PLUGIN_PACKAGES.items():
            for version in ("2026.9.1", "2026.9.4", "2030.1.1", "2030.1.1-2"):
                for phase in ("preflight", "staged"):
                    with self.subTest(plugin_id=plugin_id, version=version, phase=phase):
                        data = self.fixture(plugin_id, phase)
                        data["request"]["requestedSpecifier"] = f"{package}@{version}"
                        if phase == "staged":
                            data["plugin"]["version"] = data["origin"]["version"] = version
                        self.assertEqual(self.decision(data), "allow")

    def test_stable_selectors_follow_the_complete_policy_lifecycle(self):
        for plugin_id, package in OFFICIAL_PLUGIN_PACKAGES.items():
            for selector in ("", "@latest", "@stable"):
                for phase in ("preflight", "staged", "stable-dependencies"):
                    with self.subTest(plugin_id=plugin_id, selector=selector, phase=phase):
                        data = self.fixture(plugin_id, phase)
                        data["request"].update(mode="update", requestedSpecifier=f"{package}{selector}")
                        self.assertEqual(self.decision(data), "allow")

    def test_official_registry_provenance_and_preflight_aliases(self):
        for authority in ("official", "openclaw", "third-party"):
            for source_path_kind in ("file", "directory"):
                for target in ("copilot", "@openclaw/copilot"):
                    with self.subTest(authority=authority, path_kind=source_path_kind, target=target):
                        data = self.fixture()
                        data["source"]["authority"] = authority
                        data["sourcePathKind"] = source_path_kind
                        data["targetName"] = data["plugin"]["pluginId"] = target
                        data["request"]["requestedSpecifier"] = "npm:@openclaw/copilot@latest"
                        self.assertEqual(self.decision(data), "allow")

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

    def test_nonstable_ranges_and_unsafe_specifiers_are_blocked_even_with_stable_metadata(self):
        selectors = (
            "", "beta", "next", "dev", "canary", "2026.9.4-beta.1", "2026.9.4-rc.1",
            "^2026.9.2", "~2026.9.2", "*", "2026.9.x", "2026.9.2 || 2030.1.1",
            "2026.9.4+build.1", "2026.9.4-0", "2026.13.1-1", "2026.9.0-1",
            "01.2.3", "2026.9.2/extra", "2026.9.2#main", "2026.9.2\nextra",
        )
        specifiers = [f"@openclaw/copilot@{selector}" for selector in selectors] + [
            "file:./copilot", "git+https://example.invalid/copilot",
            "https://example.invalid/copilot.tgz", "./copilot",
            "alias@npm:@openclaw/copilot@2026.9.2", "npm:npm:@openclaw/copilot@2026.9.2",
        ]
        for specifier in specifiers:
            for phase in ("preflight", "staged"):
                with self.subTest(specifier=specifier, phase=phase):
                    data = self.fixture(phase=phase)
                    data["request"]["requestedSpecifier"] = specifier
                    self.assertEqual(self.decision(data), "block")

    def test_stable_selector_rejects_nonstable_resolution_and_needs_staged_version(self):
        for phase in ("preflight", "staged", "stable-dependencies"):
            for version in (None, "", "latest", "2030.1.1-beta.1", "2030.1.1+build", 2030):
                with self.subTest(phase=phase, version=version):
                    data = self.fixture(phase=phase)
                    data["request"]["requestedSpecifier"] = "@openclaw/copilot@latest"
                    data["plugin"]["version"] = data["origin"]["version"] = version
                    self.assertEqual(self.decision(data), "block")
        data = self.fixture(phase="staged")
        data["request"]["requestedSpecifier"] = "@openclaw/copilot"
        del data["plugin"]["version"]
        self.assertEqual(self.decision(data), "block")

    def test_requested_package_or_version_disagreement_has_no_metadata_fallback(self):
        for kind in ("plugin-npm", "plugin-dir"):
            for specifier in (
                "@openclaw/copilot@2030.1.1", "@openclaw/diagnostics-otel@2026.9.2",
                "@untrusted/copilot@2026.9.2", "@untrusted/copilot@latest",
            ):
                with self.subTest(kind=kind, specifier=specifier):
                    data = self.fixture(phase="staged")
                    data["request"].update(kind=kind, requestedSpecifier=specifier)
                    self.assertEqual(self.decision(data), "block")
        data = self.fixture(phase="staged")
        data["request"]["kind"] = "plugin-dir"
        self.assertEqual(self.decision(data), "allow")

    def test_explicit_pins_are_not_reinterpreted_as_stable_selectors(self):
        data = self.fixture(phase="staged")
        data["openclawVersion"] = "2030.1.1"
        self.assertEqual(self.decision(data), "allow")
        data["plugin"]["version"] = data["origin"]["version"] = "2030.1.1"
        self.assertEqual(self.decision(data), "block")
        data["request"]["requestedSpecifier"] = "@openclaw/copilot@v2030.1.1"
        self.assertEqual(self.decision(data), "allow")

    def test_all_supplied_identity_and_version_metadata_must_agree(self):
        for phase in ("preflight", "staged", "stable-dependencies"):
            for section, field, value in (
                ("plugin", "packageName", "@untrusted/copilot"),
                ("origin", "packageName", "@openclaw/diagnostics-otel"),
                ("plugin", "pluginId", "diagnostics-otel"),
                ("plugin", "manifestId", "diagnostics-otel"),
                ("plugin", "version", "2030.1.1"),
                ("origin", "version", "2030.1.1"),
                ("plugin", "version", "2026.9.2-beta.1"),
            ):
                with self.subTest(phase=phase, section=section, field=field, value=value):
                    data = self.fixture(phase=phase)
                    data[section][field] = value
                    self.assertEqual(self.decision(data), "block")
        data = self.fixture(phase="staged")
        data["request"]["requestedSpecifier"] = "@openclaw/copilot@latest"
        data["origin"]["version"] = "2030.1.1"
        self.assertEqual(self.decision(data), "block")

    def test_phase_confusion_or_incomplete_metadata_is_blocked(self):
        for phase in ("preflight", "staged", "stable-dependencies"):
            for section, field, value in (
                ("plugin", "contentType", "bundle"),
                ("plugin", "contentType", "file"),
                ("origin", "type", "unrecognized"),
                ("request", "kind", "plugin-archive"),
            ):
                with self.subTest(phase=phase, section=section, field=field):
                    data = self.fixture(phase=phase)
                    data[section][field] = value
                    self.assertEqual(self.decision(data), "block")
            for metadata in ({}, None, [], "copilot"):
                data = self.fixture(phase=phase)
                data["plugin"] = metadata
                self.assertEqual(self.decision(data), "block")
        for phase in ("staged", "stable-dependencies"):
            data = self.fixture(phase=phase)
            data["sourcePathKind"] = "file"
            self.assertEqual(self.decision(data), "block")

    def test_local_mutable_or_untrusted_provenance_cannot_impersonate_official_npm(self):
        for field, value in (
            ("kind", "local-path"), ("kind", "archive"), ("kind", "git"),
            ("kind", "bundled"), ("kind", "managed"),
            ("mutable", True), ("network", False), ("authority", "user"), ("authority", "unknown"),
        ):
            with self.subTest(field=field, value=value):
                data = self.fixture()
                data["source"][field] = value
                self.assertEqual(self.decision(data), "block")
        for kind in ("bundled", "managed"):
            data = self.fixture(phase="staged")
            data["source"].update(kind=kind, authority="official", network=False)
            data["request"]["kind"] = "plugin-dir"
            for specifier in ("@openclaw/copilot@latest", "@untrusted/copilot@2026.9.2"):
                data["request"]["requestedSpecifier"] = specifier
                self.assertEqual(self.decision(data), "block")
            data["request"]["requestedSpecifier"] = "/official/plugins/copilot"
            self.assertEqual(self.decision(data), "allow")

    def test_allowlist_does_not_expand_to_scope_siblings_or_third_parties(self):
        for package in (
            "@openclaw/other", "@openclaw/brave", "@openclaw/brave-plugin-extra",
            "@openclaw/copilot-extra", "@openclaw/discord-extra", "@github/copilot",
            "@untrusted/copilot",
        ):
            for authority, expected in (("third-party", "warn"), ("official", "block")):
                with self.subTest(package=package, authority=authority):
                    data = self.fixture()
                    data["targetName"] = data["plugin"]["pluginId"] = "other"
                    data["plugin"]["packageName"] = data["origin"]["packageName"] = package
                    data["request"]["requestedSpecifier"] = f"{package}@2030.1.1"
                    data["source"]["authority"] = authority
                    self.assertEqual(self.decision(data), expected)

    def test_protocol_and_request_schema_remain_fail_closed(self):
        original = self.fixture()
        for field, value in (
            ("protocolVersion", True), ("protocolVersion", 1.0), ("protocolVersion", 2),
            ("protocolVersion", "1"), ("openclawVersion", ""), ("openclawVersion", None),
            ("openclawVersion", 2030), ("targetType", "skill"), ("targetType", "unknown"),
            ("targetName", "diagnostics-otel"), ("targetName", None),
            ("source", None), ("request", []), ("origin", None),
            ("sourcePath", ""), ("sourcePathKind", "symlink"),
        ):
            with self.subTest(field=field, value=value):
                data = copy.deepcopy(original)
                data[field] = value
                self.assertEqual(self.decision(data), "block")
        for section, field, value in (
            ("source", "mutable", "false"), ("source", "network", 1),
            ("source", "authority", "trusted"), ("source", "kind", "registry"),
            ("request", "mode", "remove"), ("request", "kind", "skill-install"),
            ("request", "requestedSpecifier", None), ("origin", "type", ""),
        ):
            with self.subTest(section=section, field=field, value=value):
                data = copy.deepcopy(original)
                data[section][field] = value
                self.assertEqual(self.decision(data), "block")
        for field in original:
            data = copy.deepcopy(original)
            del data[field]
            self.assertEqual(self.decision(data), "block", field)

    def test_malformed_or_oversized_input_remains_fail_closed(self):
        for raw in (b"{", b"\xff", b"[]", b"null", b" " * (256 * 1024 + 1)):
            self.assertEqual(self.response(raw)["decision"], "block")

    def test_reproducibility_manifest_pins_still_pass_without_policy_version_constants(self):
        manifest = json.loads((ROOT / "config/runtime-versions.json").read_text())
        for plugin_id in ("copilot", "diagnostics-otel"):
            version = manifest["packages"][f"@openclaw/{plugin_id}"]["version"]
            data = self.fixture(plugin_id, "staged")
            data["request"]["requestedSpecifier"] = f"@openclaw/{plugin_id}@{version}"
            data["plugin"]["version"] = data["origin"]["version"] = version
            data["openclawVersion"] = manifest["openclaw"]["version"]
            self.assertEqual(self.decision(data), "allow")
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
