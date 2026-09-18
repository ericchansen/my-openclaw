# Runtime security model

The reproducible deployment baseline is pinned in [runtime-versions.json](../config/runtime-versions.json).
The runtime upgrade preserves existing approved routing, credentials, and data.
The isolated baseline and explicitly opted-in trusted-operator profile below are
different deployment policies, not requirements of the upstream runtime.
See upstream [security](https://github.com/openclaw/openclaw/blob/v2026.9.2/docs/gateway/security/index.md)
and [sandboxing](https://github.com/openclaw/openclaw/blob/v2026.9.2/docs/gateway/sandboxing.md).

## Isolated baseline

The baseline assumes one administrator. `agent:main:main` is the capable owner session.
Channel admission, identity links, or family membership do not grant administration.
`commands.ownerAllowFrom` and elevated grants must identify only the reviewed owner.
Resolve [reference placeholders](../config/openclaw-quality.patch.json) explicitly;
do not apply templates wholesale. Review persisted exec host/node overrides and
clear unauthorized overrides through supported APIs without deleting history.

Non-family/default contexts retain separate agents/workspaces and private recall
boundaries. Separate session keys or containers alone do not make shared files private.
Public/unapproved groups must not inherit private mounts or owner command authority.

### Trusted-family sharing

Only the existing explicitly approved cohort shares its reviewed family data.
Main's shared workspace and approved history are family-readable, not private owner
storage. Keep secrets and unrelated private records outside that boundary.
Preserve separate conversation keys, sender attribution, and sandboxed family
sessions; never route peers into the unsandboxed owner session.
New identities, channels, groups/topics, or sharing changes require explicit review.
Allowlisting or linking an identity does not implicitly expand the family cohort.

History is retained, not automatically migrated. Any future import requires separate,
content-scoped approval, read-only source access, and approved visible conversation
text only. Exclude hidden reasoning, tool payloads, credentials, and unrelated private
material. Never cross privacy boundaries or rewrite source databases.
Shared memory does not bypass native group/channel or cross-agent recall restrictions.

### Sandbox and tool controls

The [reviewed controls](../config/openclaw-quality.patch.json) retain sandboxed
non-owner sessions and an always-sandboxed orchestrator, bounded resources,
read-only roots, dropped capabilities, and no default network. Writable access is
limited to the selected workspace; never add arbitrary host binds or a Docker socket.
Browser CDP uses its reviewed dedicated network; host-browser control stays disabled.
Preserve private-network/SSRF restrictions and fail closed on unsupported navigation
or backend failure, rather than executing on the host.

Owner host exec remains [approval-gated](https://github.com/openclaw/openclaw/blob/v2026.9.2/docs/tools/exec-approvals.md),
with deny fallback when approval is unavailable. Session tools remain tree-scoped;
same-agent memory exceptions retain upstream privacy guards. Approvals are safety
gates, not multi-user authorization. [Astra](astra-model.md) broadens no permissions.

## Opt-in trusted operators

For a deployment whose admitted people are all trusted administrators, the
[trusted-operator overlay](../config/openclaw-trusted-operators.patch.json)
deliberately removes conversation-specific permission boundaries for `main`,
`orchestrator`, and `fitness`. This is the explicitly selected production posture,
not a safe multi-tenant default. The base configuration remains isolated.

These active assistants execute on the host with full tools and no per-command
approval prompts. Both general filesystem access and
[apply-patch workspace confinement](https://docs.openclaw.ai/tools/apply-patch)
are disabled explicitly: `tools.fs.workspaceOnly: false` alone does not remove
`tools.exec.applyPatch.workspaceOnly`. Host execution has the runtime user's
OS privileges and connected-account authority; with Docker membership, treat
this as host-administrator trust, not merely shared file access.

The overlay also sets `tools.exec.strictInlineEval: false` on each of those
three agents. This is independent of `exec.mode: full`: an inherited
`strictInlineEval: true` still requires reviewer or human approval for inline
interpreters such as `node -e` and `python -c`, including within pipelines.
Disabling it is intentional for these reviewed host administrators, not a
general recommendation. The global baseline keeps the gate enabled, so the
healthcheck and any separately configured isolated agents do not inherit this
exemption.

Specialist workspaces remain their instruction, skill, and default-directory
locations, not security boundaries. The overlay does not replace workspace,
agent-directory, skill, model, or memory settings. Conversation keys and original
history stay separate; session visibility is shared and the active agents can
delegate to one another. The healthcheck agent remains sandboxed and exec-only.
The production roster is `main`, `orchestrator`, `fitness`, and `healthcheck`.
Legacy isolated agents and their housekeeping jobs are retired with operator
approval; recovery history belongs in private backups, not unused live agents.
Use the [retirement procedure](operations.md#retiring-unused-agents) rather than
deleting database files or dropping agent definitions alone.

Normal requests in the trusted groups use
[automatic final replies](https://docs.openclaw.ai/channels/groups#visible-replies).
Tool-only delivery is an explicit ambient-room behavior, not a permission control;
it can hide a completed answer when the model omits the messaging tool. Preserve
intentional silence for background jobs rather than forcing every event to speak.

Before applying this profile, explicitly review every admitted sender and group.
Set `commands.ownerAllowFrom` and channel-specific elevated grants to the exact
reviewed operators; identity links or DM admission alone do not confer authority.
Remove wildcard group admission before an admitted-context catch-all selects a
capable agent. Keep explicit specialist bindings, authentication, SecretRefs,
untrusted-content handling, resource budgets, and backups. The public overlay
contains no real identities and intentionally does not automate these grants or
channel changes. Update existing workspace instructions that still impose the
superseded owner-only policy without replacing specialist instructions.

Use the pinned CLI's `config patch --dry-run` and `config validate` before
activation. Inspect `exec-policy show`, persisted session/approval overrides,
and actual cross-workspace file-edit/exec receipts. Exercise connected-service
tools without exposing account contents. Authorization checks must use the
registered channel plugin; a bare helper import has no channel normalization.
Do not equate CLI/operator checks with observed human-client ingress.

### Administration from trusted conversations

Full host access does not remove every upstream model-tool restriction. In
2026.9.2, the native `automations` tool still restricts cross-conversation and
operator-created jobs; its Gateway-wide management grant is specific to an
authenticated Control UI administrator turn. Owner allowlists, session visibility,
and filesystem access are not substitutes for that grant.

The trusted-operator profile already permits a separate supported route: use
ordinary host `exec` to run the installed, authenticated `openclaw automations`
CLI. Install the [trusted-operator administration skill](../workspace/skills/trusted-operator-admin/SKILL.md)
only in the reviewed active workspaces and reference it in their existing
instructions. Do not copy it over specialist instructions or apply it as a
permission grant to the isolated baseline. Agents sharing a workspace share its
skill; retain separate copies for specialists with distinct workspaces.

This route keeps real job ownership and scheduled execution policy intact.
Never forge a Control UI identity, remove caller metadata, inject an operator
token, or rewrite SQLite to defeat the native tool's scope. An authorization
failure from the configured CLI remains a blocker.

The pinned Copilot harness also rejects the delegated `openclaw` expert's
in-memory turn with `canonical transcript persistence requires an exact runtime
session target`. Interactive Astra conversations and ordinary host CLI execution
are separate paths. Use the supported CLI for authorized administration without
claiming the delegated expert is repaired or changing the default model/runtime.

## Host, Azure, and telemetry risks

[Docker-group access](https://docs.docker.com/engine/install/linux-postinstall/) is
root-equivalent; native plugins also execute within the Gateway boundary. Keep
the [install policy](../scripts/openclaw-install-policy.py) and explicit plugin
allowlisting; append reviewed entries rather than replacing existing lists.
The VM identity retains subscription-wide Contributor and Cost Management Contributor
by owner decision. Keep host/Azure mutations trusted-operator-triggered and identity-audited.
Future private-endpoint/NAT cutover is deferred, not a deployed isolation guarantee.

Preserve deployed metadata OTel, its collector, and [launcher guards](../scripts/openclaw-gateway-launch.py).
Content capture needs separate approval; redaction is not guaranteed PII removal.
See [telemetry privacy](telemetry-privacy.md). Never disable authentication for recovery.

Validate with the exact CLI and inspect `openclaw sandbox explain`. For the
isolated baseline, require denied host/private-network access and preserved
owner/family/non-family routing. For the trusted profile, require intended
host access, retained specialist identity, and rejected unapproved senders;
browser SSRF policy remains independent. Follow [operations](operations.md) and
[availability acceptance](availability-recovery.md); a passing canary does not
establish perfect isolation.

### Install policy versus reproducibility pins

The helper enforces **protocol v1, source trust, and identity consistency**, not a
particular OpenClaw release. A newer core version does not disable plugin or skill
installation. Unknown protocols and malformed provenance still fail closed.
OpenClaw itself retains package compatibility, integrity, capability-consent, and
dependency-boundary checks; allowing a policy request does not bypass those checks.

The npm allowlist is only `@openclaw/copilot` (`copilot`) and
`@openclaw/diagnostics-otel` (`diagnostics-otel`), not the whole `@openclaw` scope.
They require immutable, network-backed npm provenance. The upstream `third-party`
authority label is accepted for these exact registry identities because direct
npm installs use it; unknown/user provenance, local copies, git/URL/alias sources,
version ranges, and non-stable tags/releases do not gain unattended approval.
Exact stable versions, including OpenClaw's numeric calendar correction releases
(for example `2030.1.1-1`), need no policy edit.

Bare package names and `@latest`/`@stable` (with an optional `npm:` prefix) may enter
the normal registry resolver. Protocol v1 npm preflight omits the resolved version,
so preflight approval is **not approval of an arbitrary resolved artifact**:
the subsequent `plugin-package` check requires an exact stable package version.
Every supplied package name, plugin/manifest ID, target, and version must agree.
An exact requested version must match the staged package; it is never treated as
`latest`. The later `plugin-dependency-tree` check omits the version again and
relies on OpenClaw's preceding package scan. The helper does not resolve tags or
fetch packages itself; staged package versions refer to `package.json`, not the
independently versioned `openclaw.plugin.json` manifest.

Immutable official bundled/managed content remains allowed. ClawHub content and
other untrusted/third-party sources still require explicit operator review;
`warn` denies unattended installation, rather than silently allowing it.

The manifest's exact versions and checksums serve reproducible provisioning,
testing, and rollback, not a global runtime update veto. Updating an official
stable release does not require copying its version into this policy. Separately,
explicit user pins in runtime configuration remain binding: this helper neither
edits configuration nor removes pins, and the repository's pinned provisioning
and maintenance scripts continue to use the manifest.
