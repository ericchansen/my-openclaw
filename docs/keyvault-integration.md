# Azure Key Vault SecretRefs

OpenClaw 2026.7.1 should resolve supported secrets on demand through an allowlisted exec provider backed by Azure managed identity. Do not export the vault into the gateway environment.

Official references: [OpenClaw secrets](https://docs.openclaw.ai/gateway/secrets), [SecretRef credential surface](https://docs.openclaw.ai/reference/secretref-credential-surface), and [Azure VM managed identity with Key Vault](https://learn.microsoft.com/azure/key-vault/general/tutorial-net-virtual-machine).

## Provider Contract

The template registers `/usr/local/bin/openclaw-keyvault-resolver` as the `azure-key-vault` exec provider. OpenClaw 2026.7.1 requires an exec provider command to be owned by the gateway user, so the installer uses that owner with mode `0555` inside the root-owned `/usr/local/bin` directory. Keep the resolver's configuration files root-owned and non-writable, keep the command in the allowlisted trusted directory, and use an absolute path.

OpenClaw sends one protocol-v1 JSON request on stdin:

```json
{"protocolVersion":1,"provider":"azure-key-vault","ids":["BRAVE-API-KEY"]}
```

The resolver obtains a managed-identity token directly from Azure Instance Metadata Service (IMDS), calls the Key Vault REST API, reads only requested allowlisted names, and writes one JSON response:

```json
{"protocolVersion":1,"values":{"BRAVE-API-KEY":"<resolved internally>"},"errors":{}}
```

This direct path avoids shared Azure CLI login/cache races during concurrent secret audits. Never log stdin, resolved values, response bodies, tokens, or Key Vault debug payloads. Return generic per-ID errors. Keep output and timeouts bounded. Do not enable insecure paths, symlinked commands, arbitrary vault names, caller-provided shell fragments, or broad `passEnv`.

## Least Privilege

- Grant the VM identity only `secrets/get` for the required vault/scope.
- Allowlist the exact IDs: gateway, Telegram, Discord, GitHub/Copilot, Brave, eBird, and the Gmail keyring credential required by the supervised watcher.
- Use separate identities/vaults for environments where practical.
- Restrict executable ownership and deployment separately from secret-read permission.
- Rotate in Key Vault; do not rewrite configuration for a value change.

## Template References

Supported fields use:

```json
{
  "source": "exec",
  "provider": "azure-key-vault",
  "id": "TELEGRAM-BOT-TOKEN"
}
```

The template covers gateway, Telegram, Discord, and Brave search. For an existing GitHub Copilot auth profile, preserve its saved Copilot token in a dedicated `GITHUB-COPILOT-TOKEN` Key Vault entry and migrate the persisted credential to the profile's supported `tokenRef` surface. Do not substitute a generic GitHub PAT. Confirm model entitlement separately.

OpenClaw 2026.7.1 does not expose the Gmail keyring password as a supported SecretRef field. The gateway must not inherit this credential because host-exec tools inherit its environment. The installer therefore keeps the real `gog` executable at `/usr/local/libexec/gog` and exposes a root-owned `/usr/local/bin/gog` launcher. The launcher resolves only `GOG-KEYRING-PASSWORD` immediately before executing `gog`, so the gateway and unrelated agent subprocesses do not receive it. It must not materialize the value in a file, command line, systemd environment file, or log. If `gog` is installed after initial provisioning, rerun the runtime installer to activate the launcher.

The MCP configuration surface also does not support SecretRefs in 2026.7.1. The runtime
installer pins eBird and Pondlog under `/usr/local/lib/openclaw-mcp` and installs the
root-owned `/usr/local/bin/openclaw-mcp-launch` wrapper. The wrapper accepts only `ebird`
or `pondlog`, resolves `EBIRD-API-KEY` immediately before process execution, and exposes
it only as the child process's `EBIRD_API_KEY`. MCP config must use the launcher with no
`env` block; never use `npx` or store the key in `openclaw.json`.

## Channel-Preserving Migration

Do not replace the live config with the template.

1. Back up the active config and capture non-secret health/channel/cron inventories.
2. Preserve Telegram allowlists/streaming, Discord guild/channel/sender tool restrictions, Gmail hooks, agent bindings, auth profiles, and cron database/state.
3. Install and permission the resolver without retrieving a value in a terminal.
4. Add the provider and SecretRefs as a minimal patch.
5. Dry-run the patch against the installed schema.
6. Audit and validate.
7. Apply during a rollback window; restart only if required.
8. Test each existing channel from its already-onboarded identity. Do not re-onboard or regenerate channel configuration.

## Value-Safe Verification

Run:

```bash
openclaw config patch --stdin --dry-run --json
openclaw config validate --json
openclaw secrets audit --check
```

Use `--allow-exec` only in the controlled provider-validation step after permissions and allowlists are verified. Capture exit status and redacted diagnostics, not stdout containing values. A clean audit means supported plaintext credential fields have been migrated; it does not prove every external channel works.

Verify without `echo`, `printenv`, shell tracing, command substitution, or retrieving a secret through `az keyvault secret show`:

- managed identity metadata and RBAC assignment identify the intended principal;
- resolver file owner/mode/path match OpenClaw's enforced exec policy, and its configuration remains root-owned;
- unknown and disallowed IDs fail safely;
- config validation and secrets audit are clean;
- gateway starts with redacted logs;
- the gateway process environment does not contain `GOG_KEYRING_PASSWORD`;
- the gateway process environment does not contain `EBIRD_API_KEY`;
- `/usr/local/bin/gog` resolves through the launcher while `/usr/local/libexec/gog` is the root-controlled real executable;
- eBird and Pondlog resolve through `/usr/local/bin/openclaw-mcp-launch` to the pinned binaries without `npx`;
- existing Telegram, Discord, Gmail, GitHub/Copilot, and Brave operations succeed;
- logs contain no values or resolver payloads.

If any check fails, restore the last-known-good config and keep existing channel credentials/state intact while diagnosing.
