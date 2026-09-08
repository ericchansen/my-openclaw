#!/usr/bin/env python3
"""Fail-closed OpenClaw 2026.9.2 install-policy protocol v1 helper."""

import json
import sys


PROTOCOL_VERSION = 1
OPENCLAW_VERSION = "2026.9.2"
MAX_INPUT_BYTES = 256 * 1024
EXACT_PACKAGES = {
    "@openclaw/diagnostics-otel": "2026.9.2",
    "@openclaw/copilot": "2026.9.2",
}
EXACT_PLUGIN_IDS = {
    "@openclaw/diagnostics-otel": "diagnostics-otel",
    "@openclaw/copilot": "copilot",
}
OFFICIAL_KINDS = {"bundled", "managed"}
OFFICIAL_AUTHORITIES = {"openclaw", "official"}


def respond(decision: str, reason: str | None = None) -> None:
    payload: dict[str, object] = {
        "protocolVersion": PROTOCOL_VERSION,
        "decision": decision,
    }
    if reason:
        payload["reason"] = reason
    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.write("\n")


def block(reason: str) -> None:
    respond("block", reason)


def parse_exact_npm_specifier(specifier: str) -> tuple[str, str] | None:
    value = specifier.strip()
    if value.startswith("npm:"):
        value = value[4:]
    split_at = value.rfind("@")
    if split_at <= 0 or split_at == len(value) - 1:
        return None
    return value[:split_at], value[split_at + 1 :]


def main() -> int:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        block("policy request exceeds the supported size")
        return 0
    try:
        request = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        block("policy request is not valid UTF-8 JSON")
        return 0
    if not isinstance(request, dict):
        block("policy request must be a JSON object")
        return 0
    if request.get("protocolVersion") != PROTOCOL_VERSION:
        block("unsupported install-policy protocol version")
        return 0
    if request.get("openclawVersion") != OPENCLAW_VERSION:
        block("install policy is pinned to OpenClaw 2026.9.2")
        return 0
    if request.get("targetType") not in {"skill", "plugin"}:
        block("unsupported install target")
        return 0

    source = request.get("source")
    operation = request.get("request")
    if not isinstance(source, dict) or not isinstance(operation, dict):
        block("install source provenance is required")
        return 0
    kind = source.get("kind")
    authority = source.get("authority")
    mutable = source.get("mutable")
    network = source.get("network")
    mode = operation.get("mode")
    request_kind = operation.get("kind")
    if (
        kind
        not in {
            "archive",
            "bundled",
            "clawhub",
            "file",
            "git",
            "local-path",
            "managed",
            "npm",
            "upload",
            "workspace",
        }
        or authority not in {"openclaw", "official", "third-party", "unknown", "user"}
        or not isinstance(mutable, bool)
        or not isinstance(network, bool)
        or mode not in {"install", "update"}
        or request_kind
        not in {
            "skill-install",
            "plugin-dir",
            "plugin-archive",
            "plugin-file",
            "plugin-npm",
            "plugin-git",
        }
    ):
        block("install request provenance is incomplete or unsupported")
        return 0

    if kind == "clawhub":
        respond(
            "warn",
            "marketplace content requires explicit operator review; unattended installation is denied",
        )
        return 0

    if kind in OFFICIAL_KINDS and authority in OFFICIAL_AUTHORITIES and mutable is False:
        respond("allow")
        return 0

    if (
        request_kind == "plugin-npm"
        and kind == "npm"
        and mutable is False
        and network is True
    ):
        specifier = operation.get("requestedSpecifier")
        plugin = request.get("plugin")
        parsed = parse_exact_npm_specifier(specifier) if isinstance(specifier, str) else None
        if parsed:
            package, version = parsed
            expected_plugin_id = EXACT_PLUGIN_IDS.get(package)
            metadata_compatible = (
                not isinstance(plugin, dict)
                or (
                    plugin.get("packageName") in {None, package}
                    and plugin.get("version") in {None, version}
                    and plugin.get("pluginId") in {None, expected_plugin_id, package}
                )
            )
            target_compatible = (
                expected_plugin_id is not None
                and request.get("targetName") in {expected_plugin_id, package}
            )
            if (
                EXACT_PACKAGES.get(package) == version
                and metadata_compatible
                and target_compatible
            ):
                respond("allow")
                return 0

    plugin = request.get("plugin")
    if (
        request_kind in {"plugin-npm", "plugin-dir"}
        and kind == "npm"
        and mutable is False
        and network is True
        and isinstance(plugin, dict)
        and isinstance(plugin.get("packageName"), str)
        and EXACT_PACKAGES.get(plugin["packageName"]) == plugin.get("version")
        and EXACT_PLUGIN_IDS.get(plugin["packageName"]) == plugin.get("pluginId")
        and plugin.get("pluginId") == request.get("targetName")
    ):
        respond("allow")
        return 0

    parsed_specifier = (
        parse_exact_npm_specifier(operation.get("requestedSpecifier"))
        if isinstance(operation.get("requestedSpecifier"), str)
        else None
    )
    if (
        request.get("targetName") in EXACT_PLUGIN_IDS.values()
        or (
            isinstance(plugin, dict)
            and (
                plugin.get("pluginId") in EXACT_PLUGIN_IDS.values()
                or plugin.get("packageName") in EXACT_PACKAGES
            )
        )
        or (
            parsed_specifier is not None
            and parsed_specifier[0] in EXACT_PACKAGES
        )
    ):
        block("official plugin source or version does not match the reviewed immutable pin")
        return 0

    if authority in {"third-party", "unknown", "user"} or mutable:
        respond(
            "warn",
            "source requires explicit interactive owner review; unattended installation is denied",
        )
        return 0

    package_name = plugin.get("packageName") if isinstance(plugin, dict) else None
    plugin_version = plugin.get("version") if isinstance(plugin, dict) else None
    block(
        "source is not in the reviewed install allowlist "
        f"(kind={kind}, request={request_kind}, target={request.get('targetName')}, "
        f"specifier={operation.get('requestedSpecifier')}, package={package_name}, "
        f"version={plugin_version}, mutable={mutable})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        block("install policy evaluation failed")
