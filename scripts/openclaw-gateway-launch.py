#!/usr/bin/python3
import os
import json
import pathlib
import pwd
import socket
import stat
import subprocess
import sys


OPENCLAW_PATH = "/usr/local/libexec/openclaw"
EX_CONFIG = 78
EX_TEMPFAIL = 75
COLLECTOR_MARKER = pathlib.Path("/run/openclaw-otel/ready")
CONTENT_ENABLE_MARKER = pathlib.Path("/etc/openclaw/telemetry-content.enabled")
DEFAULT_CONFIG_PATH = "~/.openclaw/openclaw.json"
CONFIG_QUERY_TIMEOUT_SECONDS = 15
CONFIG_QUERY_MAX_BYTES = 64 * 1024
LOCAL_OTLP_ENDPOINT = "http://127.0.0.1:4318"
LOCAL_SIGNAL_ENDPOINTS = {
    "tracesEndpoint": f"{LOCAL_OTLP_ENDPOINT}/v1/traces",
    "metricsEndpoint": f"{LOCAL_OTLP_ENDPOINT}/v1/metrics",
    "logsEndpoint": f"{LOCAL_OTLP_ENDPOINT}/v1/logs",
}
OTEL_ENV_OVERRIDES = {
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL",
    "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL",
    "OTEL_TRACES_EXPORTER",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
}
PRELOAD_ENV_OVERRIDES = {
    "NODE_OPTIONS",
    "NODE_PATH",
    "LD_PRELOAD",
    "DYLD_INSERT_LIBRARIES",
}


class TemporaryPreflightError(ValueError):
    """A dependency is unavailable; no unvalidated Gateway may start."""


def _secure_marker(path: pathlib.Path, expected_uid: int) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == expected_uid
        and metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0
    )


def _collector_ready() -> bool:
    try:
        collector_uid = pwd.getpwnam("openclaw-otel").pw_uid
    except KeyError:
        return False
    if not _secure_marker(COLLECTOR_MARKER, collector_uid):
        return False
    try:
        with socket.create_connection(("127.0.0.1", 4318), timeout=1):
            return True
    except OSError:
        return False


def _sanitized_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in OTEL_ENV_OVERRIDES | PRELOAD_ENV_OVERRIDES:
        environment.pop(key, None)
    return environment


def _read_effective_otel(
    source: pathlib.Path, environment: dict[str, str]
) -> dict[str, object]:
    query_environment = environment.copy()
    query_environment["OPENCLAW_CONFIG_PATH"] = str(source)
    try:
        result = subprocess.run(
            [OPENCLAW_PATH, "config", "get", "diagnostics.otel", "--json"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=CONFIG_QUERY_TIMEOUT_SECONDS,
            check=False,
            close_fds=True,
            env=query_environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TemporaryPreflightError("config-query-unavailable") from error
    if result.returncode != 0:
        legacy_error = result.stderr.decode("utf-8", errors="replace").strip()
        if legacy_error.startswith("Config path not found: diagnostics.otel."):
            return {"enabled": False, "captureContent": False}
        try:
            failure = json.loads(result.stdout.decode("utf-8", errors="strict"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            failure = None
        message = (
            failure.get("error", {}).get("message")
            if isinstance(failure, dict) and isinstance(failure.get("error"), dict)
            else None
        )
        if (
            failure
            and failure.get("ok") is False
            and failure["error"].get("type") == "cli_error"
            and isinstance(message, str)
            and message.startswith("Config path is valid but unset: diagnostics.otel.")
        ):
            return {"enabled": False, "captureContent": False}
        if isinstance(message, str) and message.startswith("OpenClaw config is invalid:"):
            raise ValueError("OpenClaw config is invalid")
        raise TemporaryPreflightError("config-query-failed")
    if (
        len(result.stdout) > CONFIG_QUERY_MAX_BYTES
        or len(result.stderr) > CONFIG_QUERY_MAX_BYTES
    ):
        raise ValueError("OpenClaw config query output exceeded its bound")
    try:
        otel = json.loads(result.stdout.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("OpenClaw returned unresolved telemetry JSON") from error
    if not isinstance(otel, dict):
        raise ValueError("diagnostics.otel must be an object")
    return otel


def _validate_canonical_config(environment: dict[str, str] | None = None) -> pathlib.Path:
    source = pathlib.Path(
        os.path.expanduser(os.environ.get("OPENCLAW_CONFIG_PATH", DEFAULT_CONFIG_PATH))
    ).resolve(strict=True)
    otel = _read_effective_otel(
        source, _sanitized_environment() if environment is None else environment
    )

    enabled = otel.get("enabled", False)
    capture_content = otel.get("captureContent", False)
    if not isinstance(enabled, bool) or not isinstance(capture_content, bool):
        raise ValueError("telemetry enabled and captureContent must be booleans")
    if capture_content and not enabled:
        raise ValueError("content telemetry cannot be requested while OTel is disabled")
    if enabled:
        required = {
            "endpoint": LOCAL_OTLP_ENDPOINT,
            "protocol": "http/protobuf",
            "logsExporter": "otlp",
            **LOCAL_SIGNAL_ENDPOINTS,
        }
        for key, expected in required.items():
            if otel.get(key) != expected:
                raise ValueError(f"unsafe diagnostics.otel.{key}")
    if capture_content:
        if not _secure_marker(CONTENT_ENABLE_MARKER, 0):
            raise ValueError("content telemetry lacks root approval")
        if not _collector_ready():
            raise TemporaryPreflightError("content telemetry collector gate is not ready")
    return source


def main() -> int:
    check_only = sys.argv[1:] == ["--check"]
    if sys.argv[1:] and not check_only:
        return 64
    if not os.path.isfile(OPENCLAW_PATH) or not os.access(OPENCLAW_PATH, os.X_OK):
        print("OpenClaw gateway executable validation failed.", file=sys.stderr)
        return EX_CONFIG
    try:
        environment = _sanitized_environment()
        source = _validate_canonical_config(environment)
    except TemporaryPreflightError as error:
        print(f"OpenClaw preflight dependency unavailable: {error}.", file=sys.stderr)
        return EX_TEMPFAIL
    except (ValueError, OSError) as error:
        print(f"OpenClaw Gateway preflight failed closed: {error}.", file=sys.stderr)
        return EX_CONFIG
    if check_only:
        print("OpenClaw gateway executable validation succeeded.")
        return 0
    environment["OPENCLAW_CONFIG_PATH"] = str(source)
    os.execve(
        OPENCLAW_PATH,
        [
            OPENCLAW_PATH,
            "gateway",
            "run",
            "--bind",
            "loopback",
            "--port",
            "18789",
        ],
        environment,
    )
    return EX_CONFIG


if __name__ == "__main__":
    raise SystemExit(main())
