# Access and credentials in my setup

This page describes my deployment-specific access choices. OpenClaw's general
security model is documented [upstream](https://docs.openclaw.ai/gateway/security).

## Assistant access

My `main`, `orchestrator`, and `fitness` assistants run on the host with full tools,
unrestricted tool workspace paths, and no per-command approval or inline-eval
gate. They can delegate among the three agents and have shared session visibility.
The general assistant and orchestrator share a workspace; fitness has its own.
Groups use automatic final replies.

This setup trusts every admitted user as an administrator. Telegram/Discord
admission, owner identities, and sender-specific restrictions are configured
separately. With Docker-group membership, the runtime user has effectively
root-equivalent host access. Specialist workspaces are not privacy boundaries
against a host administrator.

The internal `healthcheck` remains sandboxed with network-isolated exec and no
private workspace access, browser, memory search, or messaging tools. The
configuration also retains sandbox resource settings for any sandboxed work.

The [reference configuration](../config/openclaw.template.json) uses placeholders
for private identifiers; the running installation retains its own channel bindings,
credentials, and personal files.

## Azure authority

The Gateway uses token authentication on loopback and Tailscale Serve for remote
access. The public-IP SSH bootstrap path remains part of the infrastructure;
Tailscale Serve does not by itself remove that path.

The VM managed identity has subscription-wide Contributor and Cost Management
Contributor. Key Vault secret reads use the installed
[managed-identity resolver](keyvault-integration.md).

Secrets and personal workspace data are not committed to the repository.
The local telemetry collector exports bounded operational metadata to Azure
Monitor. Content capture is separately enabled; see [telemetry privacy](telemetry-privacy.md).

## Package installation policy

The installed `openclaw-install-policy` helper adds a source/identity check to
OpenClaw's package installation flow. Immutable official bundled/managed content
is allowed. Its npm allowlist is `@openclaw/brave-plugin`, `@openclaw/copilot`,
`@openclaw/diagnostics-otel`, and `@openclaw/discord`, with matching plugin IDs and
network-backed immutable provenance. Other sources require review.

The helper accepts protocol v1, checks request/staged-package identity, and
requires an exact stable resolved version. Registry preflight can resolve bare
names or stable/latest tags, but that does not approve an arbitrary resolved
artifact. It does not replace OpenClaw's own capability and dependency checks.
The separate [manifest](../config/runtime-versions.json) pins what this
repository provisions; the helper does not impose a global core-version veto.
