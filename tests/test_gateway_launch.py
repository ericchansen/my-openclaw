import configparser
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import types
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "openclaw-gateway-launch.py"


def load_launcher():
    spec = importlib.util.spec_from_file_location("openclaw_gateway_launch", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    modules = {}
    if os.name == "nt":
        modules["pwd"] = types.SimpleNamespace(getpwnam=lambda _: None)
    with mock.patch.dict(sys.modules, modules):
        spec.loader.exec_module(module)
    return module


class GatewayTelemetryPreflightTests(unittest.TestCase):
    def setUp(self):
        self.scratch = ROOT / ".gateway-launch-test"
        shutil.rmtree(self.scratch, ignore_errors=True)
        self.scratch.mkdir()
        self.config_path = self.scratch / "openclaw.json"
        self.config_path.write_text("{}\n", encoding="utf-8")
        self.launcher = load_launcher()
        self.previous_config = os.environ.get("OPENCLAW_CONFIG_PATH")
        os.environ["OPENCLAW_CONFIG_PATH"] = str(self.config_path)

    def tearDown(self):
        if self.previous_config is None:
            os.environ.pop("OPENCLAW_CONFIG_PATH", None)
        else:
            os.environ["OPENCLAW_CONFIG_PATH"] = self.previous_config
        shutil.rmtree(self.scratch, ignore_errors=True)

    def safe_otel(self, **overrides):
        value = {
            "enabled": True,
            "endpoint": "http://127.0.0.1:4318",
            "tracesEndpoint": "http://127.0.0.1:4318/v1/traces",
            "metricsEndpoint": "http://127.0.0.1:4318/v1/metrics",
            "logsEndpoint": "http://127.0.0.1:4318/v1/logs",
            "protocol": "http/protobuf",
            "logsExporter": "otlp",
            "captureContent": False,
        }
        value.update(overrides)
        return value

    def cli_result(self, otel=None, *, returncode=0, stderr=b""):
        stdout = json.dumps(otel if otel is not None else self.safe_otel()).encode()
        return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)

    def validate_with(self, otel=None):
        result = self.cli_result(otel)
        with mock.patch.object(self.launcher.subprocess, "run", return_value=result) as run:
            actual = self.launcher._validate_canonical_config()
        return actual, run

    def test_uses_exact_bounded_read_only_cli_and_persistent_config(self):
        before = self.config_path.read_bytes()
        actual, run = self.validate_with()
        self.assertEqual(actual, self.config_path.resolve())
        self.assertEqual(self.config_path.read_bytes(), before)
        args, kwargs = run.call_args
        self.assertEqual(
            args[0],
            [
                self.launcher.OPENCLAW_PATH,
                "config",
                "get",
                "diagnostics.otel",
                "--json",
            ],
        )
        self.assertEqual(
            kwargs["env"]["OPENCLAW_CONFIG_PATH"], str(self.config_path.resolve())
        )
        self.assertEqual(kwargs["timeout"], 15)
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)

    def test_include_override_is_checked_from_cli_effective_value(self):
        include = self.scratch / "telemetry.json"
        include.write_text(json.dumps({"endpoint": "https://unsafe.invalid"}))
        self.config_path.write_text(
            json.dumps({"diagnostics": {"otel": {"$include": include.name}}})
        )
        effective = self.safe_otel(endpoint="https://unsafe.invalid")
        with mock.patch.object(
            self.launcher.subprocess, "run", return_value=self.cli_result(effective)
        ):
            with self.assertRaisesRegex(ValueError, "unsafe diagnostics.otel.endpoint"):
                self.launcher._validate_canonical_config()

    def test_interpolated_effective_endpoint_is_accepted(self):
        self.config_path.write_text(
            json.dumps(
                {
                    "diagnostics": {
                        "otel": {
                            **self.safe_otel(),
                            "endpoint": "${LOCAL_OTLP_ENDPOINT}",
                        }
                    }
                }
            )
        )
        actual, _ = self.validate_with()
        self.assertEqual(actual, self.config_path.resolve())

    def test_enabled_otel_rejects_non_loopback_endpoint(self):
        with mock.patch.object(
            self.launcher.subprocess,
            "run",
            return_value=self.cli_result(
                self.safe_otel(endpoint="https://collector.invalid:4318")
            ),
        ):
            with self.assertRaisesRegex(ValueError, "unsafe diagnostics.otel.endpoint"):
                self.launcher._validate_canonical_config()

    def test_each_signal_endpoint_is_required_and_exact(self):
        for key in self.launcher.LOCAL_SIGNAL_ENDPOINTS:
            with self.subTest(key=key, case="missing"):
                effective = self.safe_otel()
                effective.pop(key)
                with mock.patch.object(
                    self.launcher.subprocess,
                    "run",
                    return_value=self.cli_result(effective),
                ):
                    with self.assertRaisesRegex(ValueError, f"unsafe diagnostics.otel.{key}"):
                        self.launcher._validate_canonical_config()
            with self.subTest(key=key, case="remote"):
                effective = self.safe_otel(**{key: "https://collector.invalid/v1/data"})
                with mock.patch.object(
                    self.launcher.subprocess,
                    "run",
                    return_value=self.cli_result(effective),
                ):
                    with self.assertRaisesRegex(ValueError, f"unsafe diagnostics.otel.{key}"):
                        self.launcher._validate_canonical_config()

    def test_environment_endpoint_protocol_and_preload_bypasses_are_cleared(self):
        overrides = {
            key: "unsafe-value"
            for key in self.launcher.OTEL_ENV_OVERRIDES
            | self.launcher.PRELOAD_ENV_OVERRIDES
        }
        with mock.patch.dict(os.environ, {**overrides, "SAFE_VALUE": "kept"}, clear=False):
            environment = self.launcher._sanitized_environment()
        self.assertEqual(environment["SAFE_VALUE"], "kept")
        for key in overrides:
            self.assertNotIn(key, environment)

    def test_content_requires_approval_and_collector_readiness(self):
        effective = self.safe_otel(captureContent=True)
        result = self.cli_result(effective)
        with mock.patch.object(self.launcher.subprocess, "run", return_value=result):
            with mock.patch.object(self.launcher, "_secure_marker", return_value=False):
                with self.assertRaisesRegex(ValueError, "root approval"):
                    self.launcher._validate_canonical_config()
            with mock.patch.object(self.launcher, "_secure_marker", return_value=True):
                with mock.patch.object(self.launcher, "_collector_ready", return_value=False):
                    with self.assertRaisesRegex(ValueError, "collector gate"):
                        self.launcher._validate_canonical_config()
                with mock.patch.object(self.launcher, "_collector_ready", return_value=True):
                    self.assertEqual(
                        self.launcher._validate_canonical_config(),
                        self.config_path.resolve(),
                    )

    def test_valid_unset_telemetry_allows_migration_startup(self):
        failure = {
            "ok": False,
            "error": {
                "type": "cli_error",
                "message": (
                    "Config path is valid but unset: diagnostics.otel. "
                    "The runtime default applies until an authored value is set."
                ),
            },
        }
        result = subprocess.CompletedProcess(
            [], 1, stdout=json.dumps(failure).encode(), stderr=b""
        )
        with mock.patch.object(self.launcher.subprocess, "run", return_value=result):
            self.assertEqual(
                self.launcher._validate_canonical_config(),
                self.config_path.resolve(),
            )

    def test_legacy_missing_telemetry_allows_pre_update_startup(self):
        result = subprocess.CompletedProcess(
            [],
            1,
            stdout=b"",
            stderr=b"Config path not found: diagnostics.otel. Run config validate.",
        )
        with mock.patch.object(self.launcher.subprocess, "run", return_value=result):
            self.assertEqual(
                self.launcher._validate_canonical_config(),
                self.config_path.resolve(),
            )

    def test_unresolved_or_oversized_cli_output_fails_closed(self):
        cases = [
            self.cli_result(returncode=1, stderr=b"invalid config"),
            subprocess.CompletedProcess([], 0, stdout=b"not-json", stderr=b""),
            subprocess.CompletedProcess(
                [],
                0,
                stdout=b"{" + b" " * self.launcher.CONFIG_QUERY_MAX_BYTES + b"}",
                stderr=b"",
            ),
        ]
        for result in cases:
            with self.subTest(result=result):
                with mock.patch.object(self.launcher.subprocess, "run", return_value=result):
                    with self.assertRaises(ValueError):
                        self.launcher._validate_canonical_config()

    def test_unsafe_effective_telemetry_exits_with_ex_config(self):
        executable = self.scratch / "openclaw"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o700)
        result = self.cli_result(self.safe_otel(protocol="grpc"))
        with mock.patch.object(self.launcher, "OPENCLAW_PATH", str(executable)):
            with mock.patch.object(self.launcher.subprocess, "run", return_value=result):
                with mock.patch.object(self.launcher.sys, "argv", ["launcher", "--check"]):
                    self.assertEqual(self.launcher.main(), self.launcher.EX_CONFIG)

    def test_metadata_only_start_does_not_depend_on_collector_readiness(self):
        before = self.config_path.read_bytes()
        with (
            mock.patch.object(self.launcher.os.path, "isfile", return_value=True),
            mock.patch.object(self.launcher.os, "access", return_value=True),
            mock.patch.object(
                self.launcher.subprocess, "run", return_value=self.cli_result()
            ),
            mock.patch.object(
                self.launcher, "_collector_ready", return_value=False
            ) as ready,
            mock.patch.object(self.launcher.sys, "argv", ["launcher"]),
            mock.patch.object(self.launcher.os, "execve") as execute,
        ):
            self.launcher.main()
        ready.assert_not_called()
        execute.assert_called_once()
        executable, arguments, environment = execute.call_args.args
        self.assertEqual(executable, self.launcher.OPENCLAW_PATH)
        self.assertEqual(arguments[1:3], ["gateway", "run"])
        self.assertEqual(
            environment["OPENCLAW_CONFIG_PATH"], str(self.config_path.resolve())
        )
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_content_start_without_collector_fails_before_exec(self):
        with (
            mock.patch.object(self.launcher.os.path, "isfile", return_value=True),
            mock.patch.object(self.launcher.os, "access", return_value=True),
            mock.patch.object(
                self.launcher.subprocess,
                "run",
                return_value=self.cli_result(self.safe_otel(captureContent=True)),
            ),
            mock.patch.object(self.launcher, "_secure_marker", return_value=True),
            mock.patch.object(self.launcher, "_collector_ready", return_value=False),
            mock.patch.object(self.launcher.sys, "argv", ["launcher"]),
            mock.patch.object(self.launcher.os, "execve") as execute,
        ):
            self.assertEqual(self.launcher.main(), self.launcher.EX_TEMPFAIL)
        execute.assert_not_called()

    def test_transient_config_query_does_not_permanently_disable_service(self):
        for failure in (
            subprocess.TimeoutExpired("openclaw config get", 15),
            OSError("temporarily unavailable"),
        ):
            with (
                self.subTest(failure=type(failure).__name__),
                mock.patch.object(self.launcher.os.path, "isfile", return_value=True),
                mock.patch.object(self.launcher.os, "access", return_value=True),
                mock.patch.object(self.launcher.subprocess, "run", side_effect=failure),
                mock.patch.object(self.launcher.sys, "argv", ["launcher"]),
                mock.patch.object(self.launcher.os, "execve") as execute,
            ):
                self.assertEqual(self.launcher.main(), self.launcher.EX_TEMPFAIL)
                execute.assert_not_called()

    def test_known_invalid_config_remains_a_permanent_startup_failure(self):
        result = self.cli_result({
            "ok": False, "error": {
                "type": "cli_error", "message": "OpenClaw config is invalid: fixture"}
        }, returncode=1)
        with (
            mock.patch.object(self.launcher.os.path, "isfile", return_value=True),
            mock.patch.object(self.launcher.os, "access", return_value=True),
            mock.patch.object(self.launcher.subprocess, "run", return_value=result),
            mock.patch.object(self.launcher.sys, "argv", ["launcher"]),
            mock.patch.object(self.launcher.os, "execve") as execute,
        ):
            self.assertEqual(self.launcher.main(), self.launcher.EX_CONFIG)
            execute.assert_not_called()


class GatewayServiceIsolationTests(unittest.TestCase):
    def service_settings(self):
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.read(ROOT / "config" / "openclaw-gateway.service")
        return parser["Service"]

    def test_clean_supervisor_exit_automatically_restarts_gateway(self):
        service = self.service_settings()
        self.assertEqual(service["Restart"], "always")
        self.assertIn("0", service["SuccessExitStatus"].split())
        self.assertNotIn("0", service["RestartPreventExitStatus"].split())
        self.assertNotIn("143", service["RestartPreventExitStatus"].split())
        self.assertEqual(service["RestartSec"], "30")

    def test_configuration_errors_still_prevent_restart_loops(self):
        service = self.service_settings()
        self.assertEqual(service["RestartPreventExitStatus"].split(), ["78"])
        self.assertEqual(service["KillMode"], "control-group")

    def test_collector_is_ordered_but_not_a_runtime_requirement(self):
        unit = (ROOT / "config" / "openclaw-gateway.service").read_text()
        self.assertIn("Wants=openclaw-otel-collector.service", unit.splitlines())
        self.assertIn("After=openclaw-otel-collector.service", unit.splitlines())
        self.assertNotIn("Requires=", unit)
        self.assertNotIn("BindsTo=", unit)
        self.assertIn("RestartPreventExitStatus=78", unit.splitlines())


if __name__ == "__main__":
    unittest.main()
