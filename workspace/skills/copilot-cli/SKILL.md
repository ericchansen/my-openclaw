---
name: copilot-cli
description: How GitHub Copilot CLI works when you choose to use it for repository work.
---

# Copilot CLI

Copilot CLI is an optional coding agent you can launch from this host. Use it when a repo change benefits from its codebase tools. Skip it for a small edit you can do yourself. You choose when and how to use it.

## What it is

- A local CLI that runs in a repository directory.
- Typical non-interactive form: `copilot --continue --allow-all-tools -p "<brief>"` (flags vary by installed version; check `--help`).
- It can edit files, run commands, and take a while. Give it a bounded prompt: objective, paths, tests, and whether commit/push/PR is allowed.

## Practical notes

- Run it from the intended repo or worktree. Inspect `git status` first so you do not smash unrelated work.
- Prefer a feature branch over a default branch.
- After it exits, read the actual diff yourself and run the tests that matter. Copilot output is evidence, not proof.
- Do not put secrets, tokens, or private transcripts in the prompt.
- Stop the process if it hangs. Check `--help` for the installed timeout/autopilot flags.

OpenClaw also has native `sessions_spawn` / `sessions_yield` if you want a child lane. That is available, not mandatory, for Copilot CLI.
