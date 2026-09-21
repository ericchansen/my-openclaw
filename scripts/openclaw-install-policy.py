#!/usr/bin/env python3
"""Fail-closed OpenClaw install-policy protocol v1 helper."""

import json
import re
import sys


PROTOCOL_VERSION = 1
MAX_INPUT_BYTES = 256 * 1024
OFFICIAL_NPM_PLUGINS = {
    "@openclaw/brave-plugin": "brave",
    "@openclaw/copilot": "copilot",
    "@openclaw/diagnostics-otel": "diagnostics-otel",
    "@openclaw/discord": "discord",
}
STABLE_SELECTORS = {None, "latest", "stable"}
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


def parse_npm_specifier(specifier: str) -> tuple[str, str | None] | None:
    value = specifier.strip()
    if value.startswith("npm:"):
        value = value[4:]
    split_at = value.rfind("@")
    package, selector = (
        (value[:split_at], value[split_at + 1 :]) if split_at > 0 else (value, None)
    )
    if not re.fullmatch(r"(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*", package):
        return None
    return package, selector


def is_stable_version(version: object) -> bool:
    if not isinstance(version, str):
        return False
    if re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        return True
    # OpenClaw treats YYYY.M.P-N as a stable correction, not a prerelease.
    return re.fullmatch(r"[1-9][0-9]{3}\.(?:[1-9]|1[0-2])\.[1-9][0-9]*-[1-9][0-9]*", version) is not None


def allow_official_npm(request: dict, parsed: tuple[str, str | None] | None) -> bool:
    source, operation = request["source"], request["request"]
    plugin, origin = request.get("plugin"), request["origin"]
    if (
        not parsed
        or parsed[0] not in OFFICIAL_NPM_PLUGINS
        or request["targetType"] != "plugin"
        or operation["kind"] not in {"plugin-npm", "plugin-dir"}
        or source["kind"] != "npm"
        or source["authority"] not in OFFICIAL_AUTHORITIES | {"third-party"}
        or source["mutable"] is not False
        or source["network"] is not True
        or not isinstance(plugin, dict)
    ):
        return False

    package, selector = parsed
    plugin_id = OFFICIAL_NPM_PLUGINS[package]
    exact_version = selector.removeprefix("v") if isinstance(selector, str) else None
    if selector not in STABLE_SELECTORS and not is_stable_version(exact_version):
        return False
    if (
        request["targetName"] != plugin.get("pluginId")
        or plugin.get("pluginId") not in {plugin_id, package}
        or ("manifestId" in plugin and plugin["manifestId"] != plugin_id)
    ):
        return False
    versions = []
    for metadata in (plugin, origin):
        if "packageName" in metadata and metadata["packageName"] != package:
            return False
        if "version" in metadata:
            version = metadata["version"]
            if not is_stable_version(version):
                return False
            if selector not in STABLE_SELECTORS and version != exact_version:
                return False
            versions.append(version)
    if len(set(versions)) > 1:
        return False

    if origin["type"] == "plugin-npm":
        # v1 preflight has no resolved version; the package scan below must follow.
        return (
            plugin.get("contentType") == "package"
            and plugin.get("packageName") == package
            and origin.get("packageName") == package
        )
    if request["sourcePathKind"] != "directory" or plugin.get("pluginId") != plugin_id:
        return False
    if origin["type"] == "plugin-package":
        return (
            plugin.get("contentType") == "package"
            and plugin.get("packageName") == package
            and is_stable_version(plugin.get("version"))
        )
    # Upstream scans the dependency tree after the versioned package scan.
    return (
        origin["type"] == "plugin-dependency-tree"
        and plugin.get("contentType") == "dependency-tree"
    )


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
    if type(request.get("protocolVersion")) is not int or request["protocolVersion"] != PROTOCOL_VERSION:
        block("unsupported install-policy protocol version")
        return 0
    if any(
        not isinstance(request.get(field), str) or not request[field].strip()
        for field in ("openclawVersion", "targetName", "sourcePath")
    ) or request.get("sourcePathKind") not in {"file", "directory"}:
        block("install request metadata is incomplete or unsupported")
        return 0
    if request.get("targetType") not in {"skill", "plugin"}:
        block("unsupported install target")
        return 0

    source = request.get("source")
    operation = request.get("request")
    origin = request.get("origin")
    if (
        not isinstance(source, dict)
        or not isinstance(operation, dict)
        or not isinstance(origin, dict)
        or not isinstance(origin.get("type"), str)
        or not origin["type"].strip()
    ):
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

    if (request["targetType"] == "skill") != (request_kind == "skill-install"):
        block("install target and request kind disagree")
        return 0
    specifier = operation.get("requestedSpecifier")
    if "requestedSpecifier" in operation and (not isinstance(specifier, str) or not specifier.strip()):
        block("invalid requested specifier")
        return 0
    plugin = request.get("plugin")
    if "plugin" in request and (
        not isinstance(plugin, dict)
        or any(
            field in plugin and (not isinstance(plugin[field], str) or not plugin[field])
            for field in ("pluginId", "contentType", "packageName", "manifestId", "version")
        )
        or ("pluginId" in plugin and plugin["pluginId"] != request["targetName"])
    ):
        block("plugin metadata is invalid or disagrees with the target")
        return 0
    parsed_specifier = parse_npm_specifier(specifier) if isinstance(specifier, str) else None

    if kind == "clawhub":
        respond(
            "warn",
            "marketplace content requires explicit operator review; unattended installation is denied",
        )
        return 0

    official_npm_identity = (
        request["targetName"] in OFFICIAL_NPM_PLUGINS
        or request["targetName"] in OFFICIAL_NPM_PLUGINS.values()
        or (
            isinstance(plugin, dict)
            and (
                plugin.get("pluginId") in OFFICIAL_NPM_PLUGINS.values()
                or plugin.get("packageName") in OFFICIAL_NPM_PLUGINS
            )
        )
        or origin.get("packageName") in OFFICIAL_NPM_PLUGINS
        or (
            parsed_specifier is not None
            and parsed_specifier[0] in OFFICIAL_NPM_PLUGINS
        )
    )
    if (
        kind in OFFICIAL_KINDS
        and authority in OFFICIAL_AUTHORITIES
        and mutable is False
        and request_kind != "plugin-npm"
        and not (parsed_specifier and official_npm_identity)
    ):
        respond("allow")
        return 0

    if allow_official_npm(request, parsed_specifier):
        respond("allow")
        return 0

    if official_npm_identity:
        block("official plugin requires consistent registry identity and a stable immutable release")
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
