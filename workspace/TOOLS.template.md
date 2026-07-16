# TOOLS.md — Local Environment Notes

Store only non-secret facts that help operate this specific environment. Tool behavior belongs in skills and official documentation.

## Useful Local Facts

- Hosts and SSH aliases:
- Repository roots and safe worktree parent:
- Service names and health endpoints:
- Preferred browser/device:
- Channel destinations and public IDs:
- Audio, camera, or display names:

## Secret Handling

Record secret **references** and provider/item names only. Never copy values, tokens, recovery codes, cookies, private keys, or connection strings here.

- Secret provider:
- Key Vault name:
- Resolver path:
- Approved SecretRef IDs:

Use managed identity and allowlisted SecretRef resolution. Do not export a vault into the process environment. Verification must check presence, permissions, schema, and service behavior without printing values.

## Operational Notes

- Commands should have bounded timeouts and output.
- Preserve existing channel, Gmail hook, cron, identity, and auth-profile configuration during changes.
- Use native `sessions_spawn` / `sessions_yield` for delegated work. External coding tools run only inside their owning native child.
- Prefer deterministic cron commands for exact jobs and the task ledger for observing detached work.

Keep this file short, current, and safe to read at session start.
