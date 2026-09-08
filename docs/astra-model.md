# GPT-6 Astra through the official Copilot harness

Production selects `github-copilot/gpt-6-astra` through official
`@openclaw/copilot@2026.9.2` with SDK **1.0.11**, on unmodified OpenClaw 2026.9.2.
Exec/history and Telegram workflows worked with this integration; that does not
establish that all built-in provider schema issues are fixed.
See the [official Copilot integration](https://docs.openclaw.ai/plugins/copilot)
and [package versions/integrities](../config/runtime-versions.json).

The [Astra overlay](../config/openclaw-astra.patch.json) sets model-specific
`agentRuntime: {"id": "copilot"}` only for Astra. Sonnet 5 remains fallback on the
built-in runtime. The default template and [Sonnet recovery overlay](../config/openclaw-model-reliability.patch.json)
remain valid baselines until the official plugin and CLI-path prerequisites exist.

The isolated healthcheck explicitly uses native Luna with native Sonnet fallback,
not the interactive default. The deployed Copilot SDK receipt omits the native
exec exit-code/status fields required by the [canary](../scripts/openclaw-availability-check.py).
Keep that proof strict rather than treating echoed output as successful execution.
This diagnostic exception does not change the active assistants' Astra selection.

## Install prerequisites, then apply

1. Retain a verified native archive, succeeded current-OS-disk snapshot, and
   current model/plugin configuration; follow [maintenance guards](operations.md#stable-updates).
2. Deploy the current [install-policy helper](../scripts/openclaw-install-policy.py).
   Verify the exact Copilot package's npm integrity against the manifest and
   review its capabilities before accepting them.
3. In the controlled plugin-maintenance window, install the official pinned package:

   ```bash
   openclaw plugins install npm:@openclaw/copilot@2026.9.2 \
     --pin --force --accept-capabilities
   ```

4. Append `copilot` to `plugins.allow` if absent. Preserve all existing reviewed
   entries; the plugin ID is not the npm package name. The overlay does not
   replace the allowlist.
5. The existing reviewed CLI is `@github/copilot@1.0.83`. Create/verify the
   root-owned `/usr/local/libexec/copilot` shim pointing to its root-owned
   entrypoint; do not point it at a user-writable executable.
6. Install [openclaw-copilot.conf](../config/openclaw-copilot.conf) as a root-owned
   drop-in for `openclaw-gateway.service`, then run `systemctl daemon-reload`.
   It supplies `COPILOT_CLI_PATH=/usr/local/libexec/copilot`, needed because SDK
   automatic discovery did not locate the existing platform CLI.
7. Dry-run the overlay with `openclaw config patch --file <astra-patch> --dry-run`,
   apply using the supported CLI, and validate configuration. Review any existing
   agent-specific model overrides separately; leave utility, heartbeat, and
   managed background models unchanged, except for the explicit native
   healthcheck assignment above.
8. Perform one controlled Gateway restart to load the environment. Exercise
   real exec/history and channel delivery, inspecting effective model,
   `agentHarnessId: "copilot"`, and successful tool receipts.

A successful fallback is not proof Astra ran. Keep authentication, host approvals,
sandboxing, family command ownership, and private-data routing unchanged.
The collector and existing launcher remain deployed prerequisites, not things to
remove when introducing this systemd drop-in.

## Provenance

The published plugin manifest reports **2026.6.2** while resolved npm package
version is **2026.9.2**. Check `install.resolvedVersion` and `install.integrity`
against the repository pins; do not relabel or edit that manifest field.
SDK 1.0.11 describes the deployed plugin dependency, not a separate SDK pin
in the repository manifest. Neither SDK nor CLI source was patched.

## Fallback and rollback

Restore saved default and affected agent model settings to return to Sonnet;
validate, restart if needed, and confirm the effective model on a real turn.
Do not delete conversations, remove authentication, or relax isolation to switch
models. Removing the optional plugin or persisted SDK state is a separate reviewed
operation. For package/state recovery use [the rollback layers](backup-restore.md#rollback-layers).
