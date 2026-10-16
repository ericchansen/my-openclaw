#!/usr/bin/env python3
"""Derive the repository's migration patch without touching runtime state."""

import argparse
from copy import deepcopy
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SECTIONS = (
    "browser", "commands", "update", "security", "models", "agents", "memory",
    "tools", "approvals", "session", "cron", "gateway", "diagnostics", "logging",
    "plugins",
)
EXCLUDED_PATHS = (
    "commands.native", "commands.nativeSkills",
    "agents.defaults.workspace", "agents.defaults.verboseDefault",
    "agents.entries.main.identity", "agents.entries.orchestrator.workspace",
    "agents.entries.orchestrator.identity", "agents.entries.orchestrator.thinkingDefault",
    "tools.profile", "tools.web.search", "session.identityLinks",
    "gateway.mode", "gateway.auth", "gateway.tailscale",
    "plugins.entries.brave", "plugins.entries.discord", "plugins.entries.telegram",
)


def quality_patch(template: dict) -> dict:
    patch = {name: deepcopy(template[name]) for name in SECTIONS}
    for path in EXCLUDED_PATHS:
        parts = path.split(".")
        parent = patch
        for part in parts[:-1]:
            parent = parent[part]
        del parent[parts[-1]]
    patch["agents"]["defaults"]["sandbox"]["docker"]["ulimits"]["nproc"] = None
    patch["hooks"] = {"defaultSessionKey": "hook:ingress", "allowedAgentIds": ["main"]}
    return patch


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    template = json.loads((ROOT / "config/openclaw.template.json").read_text(encoding="utf-8"))
    path = ROOT / "config/openclaw-quality.patch.json"
    expected = quality_patch(template)
    if path.exists() and json.loads(path.read_text(encoding="utf-8")) == expected:
        return
    if args.check:
        raise ValueError("Quality patch is stale; run python scripts/sync-quality-patch.py")
    path.write_text(json.dumps(expected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
