# Application availability and family-channel recovery

## Official-release recovery

Production runs the unmodified [official 2026.9.2 release](https://github.com/openclaw/openclaw/releases/tag/v2026.9.2)
with matching diagnostics plugin and Node 22.23.1, pinned in
[runtime-versions.json](../config/runtime-versions.json). Experimental core patches,
custom browser-egress integration, and the proposed reminder plugin were not promoted.

The current [Astra profile](astra-model.md) uses the official Copilot harness;
exec/history and Telegram workflows worked, with native Sonnet 5 fallback retained.
The [Sonnet recovery overlay](../config/openclaw-model-reliability.patch.json)
remains a baseline without that plugin. Built-in provider trials produced invalid
history arguments; a working harness/fallback does not prove every provider path fixed.
Remove retired `messages.suppressToolErrors` and `gateway.controlUi.toolTitles`
through `openclaw config unset` if present, then validate with the published CLI.

## Failure prevention

Keep [the reviewed baseline controls](../config/openclaw-quality.patch.json):
browser startup is on demand, direct tools avoid the incompatible tool-directory
path, and cgroup PID/CPU/memory limits remain. Do not restore a small shared-UID
`nproc` limit: it counts threads across containers, not just one container
([RLIMIT_NPROC](https://man7.org/linux/man-pages/man2/getrlimit.2.html)).
Preserve [clean-exit restart behavior](operations.md#rollback-and-service-failures)
and never relax authentication, host controls, or SSRF restrictions to restore service.
An explicitly approved [trusted-operator profile](security-model.md#opt-in-trusted-operators)
is a separate access-policy decision, not an outage workaround; its diagnostic
agent remains sandboxed.

## Application canary

The [availability checker](../scripts/openclaw-availability-check.py) uses an isolated
healthcheck agent: empty workspace, no private mount, browser, memory search, or
heartbeat; only sandboxed, network-isolated exec. It requires an unpredictable
token in both a successful tool receipt and final response, not an HTTP success
or echoed prompt. No user conversation is loaded and no chat message is sent.
The probe requests thinking `off`, avoiding a model-specific reasoning level
that the selected model's catalog may reject before any tool runs.
With the optional Astra overlay, the diagnostic agent is pinned to native Luna
with Sonnet fallback so its exec receipts retain the exit-status proof that the
interactive Copilot harness currently omits.

Successful evidence is cached for up to one hour; missing, stale, malformed, or
failed evidence is actionable through the [health helper](../scripts/openclaw-health-check.sh).
Force a fresh check as the configured runtime user after changes/restarts:

```bash
python3 /usr/local/libexec/openclaw-availability-check \
  --status-file /var/lib/openclaw-runtime/health/availability.json --force
```

## Acceptance and remaining boundaries

Require a cold sandbox tool turn, the previously failing existing conversation,
real channel delivery, scheduled execution, a forced canary, and verified backup.
Retain [archive/snapshot recovery points](backup-restore.md). Never automatically
replay missed personal or health-related jobs just to make status green.

The canary does not prove human-client ingress, recipient authorization, browser
hostname navigation, or delivery settlement of every old background task.
Browser navigation must fail closed when strict SSRF/redirect inspection cannot
be enforced over remote CDP; working web fetch or CDP alone is not proof of safety.
Authenticated Control UI pairing and future private-network/NAT/public-IP cutover
remain separate work; the network cutover is deferred, not live.

Under the isolated baseline, keep agent data inside its reviewed workspace
mounts; a missing file does not justify silently disabling isolation. The
separately approved trusted-operator profile permits cross-workspace host access
while retaining specialist instructions and separate conversation histories.
Identity/sharing changes require explicit review in either profile; a runtime
upgrade alone does not grant administration.

## Data-backed group workflows

A group can be admitted to Telegram yet route to a restricted catch-all agent.
For a reported logging failure, inspect the exact group/account binding and its
resolved sandbox/tool policy before treating an acknowledgement as a saved record.
Only explicitly reviewed senders/groups may reach a capable agent. If the
deployment intentionally trusts all admitted contexts, remove wildcard group
admission before switching the catch-all; never grant arbitrary groups access.

The feeding-workflow incident had two independent defects: an omitted group
binding prevented writes, and the reminder's state path used a read-only sandbox
home. Keep the tracker, canonical data and reminder state on the same reviewed
writable workspace. Require a successful tool receipt and persisted readback
before acknowledgement, and use the original inbound timestamp for relative
dates. Recover only evidenced missing entries through the existing idempotent
writer; repeated follow-ups are not additional events.

A failed reminder command is not "nothing due." Verify logging, duplicate
prevention and reminder suppression together on fixtures in the selected runtime,
then inspect the actual scheduled run's exec result. Test the affected group
route as well as the scheduler; a generic main-agent canary cannot prove either.

## Resumed conversations and host data paths

Require successive turns in the affected existing conversation, including a
write, correction, and readback. Check actual delivery receipts for duplicate
or suppressed finals. Fresh-session tools and an isolated canary do not cover
session-resume behavior; an operator-injected turn does not prove human ingress.

Moving execution off a sandbox also changes inherited environment variables.
Use an existing writer's recognized data-file override through supported
[environment configuration](https://docs.openclaw.ai/help/environment), account
for higher-precedence values, and confirm it in the actual exec child after
restart. Point every writer at one regular canonical file. Atomic replacement
of a symlink path replaces the alias, not its target; compatibility read aliases
must not become independent write destinations. Reconcile unique records before
retiring a divergent copy, then check dashboards and scheduled readers too.

Existing integrations need real authenticated operations: a wrapper saying
"token loaded" is not proof of a valid credential. Surface reauthentication or
unsupported strict-browser navigation as separate blockers; do not substitute
accounts, relax SSRF protections, or patch upstream to make the report green.
