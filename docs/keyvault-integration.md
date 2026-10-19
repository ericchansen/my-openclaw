# Azure Key Vault integration

This deployment uses a managed-identity-backed exec provider named
`azure-key-vault`. For SecretRef syntax and general credential management, see
[OpenClaw secrets](https://docs.openclaw.ai/gateway/secrets).

## Installed components

| Component | Deployment-specific behavior |
|---|---|
| `/usr/local/bin/openclaw-keyvault-resolver` | Reads requested allowlisted secret names from the configured vault through Azure IMDS and the Key Vault REST API |
| `/usr/local/bin/gog` | Resolves `GOG-KEYRING-PASSWORD` only for the real Google CLI at `/usr/local/libexec/gog` |
| `/usr/local/bin/openclaw-mcp-launch` | Accepts `ebird` or `pondlog`, resolves `EBIRD-API-KEY`, and supplies it only to that child process |

The resolver avoids a shared Azure CLI login/cache. Its stdout is the protocol
response containing credentials, not diagnostic output. The launchers keep the
Google keyring password and eBird key out of the Gateway environment and
unrelated tool processes. The pinned MCP binaries live under
`/usr/local/lib/openclaw-mcp`.

The installer places executables in root-controlled directories. The exec
provider command is owned by the Gateway user with mode `0555`; its configuration
declares `/usr/local/bin` as a trusted directory.

## Vault entries

The reference setup uses `OPENCLAW-GATEWAY-TOKEN`, `TELEGRAM-BOT-TOKEN`,
`DISCORD-BOT-TOKEN`, `BRAVE-API-KEY`, and `EBIRD-API-KEY`.
Optional Google tooling adds `GOG-KEYRING-PASSWORD`. Existing vault-backed
Copilot profiles can retain `GITHUB-COPILOT-TOKEN`; fresh native device login
uses OpenClaw's protected local credential store instead.
`GITHUB-TOKEN` is reserved for separately configured GitHub tooling.

Seed and rotate values through Azure Portal or your approved credential process.
The VM requires secret-read access, not vault administration. The deployer's
temporary administrator assignment is for initial seeding.

## Configuration

The template contains the exec provider and channel/search references.
MCP configuration calls the launcher, not `npx`, and carries no inline credential
environment block.

Google tools need a separately installed ARM64 `gog` and Google OAuth/keyring
setup. If installed after provisioning, use
[runtime application](operations.md#runtime-updates) to activate the launcher.
A Gmail watcher, its account, destinations, and renewal schedule are not
provided by this repository.

For an existing installation, merge only the intended provider/reference
changes. The configuration template is not a replacement for existing accounts,
channel routing, auth profiles, or automation state.

## Verification

Use OpenClaw config validation and secret auditing as the runtime user, including
`--allow-exec` when intentionally checking the provider. Inspect the resolver's
file ownership, executable mode, trusted path, managed identity, and vault scope
without printing values. Verify that the Gateway environment contains neither
`GOG_KEYRING_PASSWORD` nor `EBIRD_API_KEY`.

Finally, perform a real operation through each configured integration. A resolved
credential or successful audit alone does not show that the external account
accepts it. Keep credential responses, tokens, and account contents out of Git,
chat, and diagnostic logs.
