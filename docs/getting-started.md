# Recreate my Azure setup

These steps cover my Azure infrastructure and integration choices.
For ordinary OpenClaw usage, see the [upstream documentation](https://docs.openclaw.ai).
Existing installations use [operations](operations.md), not template initialization.

## Accounts and local tools

On your computer, install Git, PowerShell 7, Python 3, OpenSSH,
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), and its
[Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install).
Your Azure account needs deployment and role-assignment permissions at the
resource-group and subscription scopes.

The infrastructure defaults are Ubuntu ARM64 in `centralus`, a
`Standard_E2ps_v6` VM (2 vCPUs, 16 GiB RAM), a 64 GiB OS disk, public bootstrap
SSH, Key Vault, Azure Monitor, and daily incremental disk snapshots retaining
three recovery points. Check regional availability, quota, and
[costs](https://azure.microsoft.com/pricing/calculator/).
The $150 subscription budget is an alert, not a spending cap. The VM identity
receives subscription-wide Contributor and Cost Management Contributor.

The reference configuration uses Telegram, Discord, GitHub Copilot with
GPT-6.1 Sol and `text-embedding-3-small`, Brave Search, and eBird/Pondlog MCP.
Supply your own accounts and channel identifiers. Optional Google tools need
[`gog`](https://github.com/steipete/gogcli) and Google OAuth setup; this repository
does not install `gog` or create a Gmail watcher.

The reference configuration contains my `main`, `orchestrator`, and `fitness`
assistants, automatic recall, Memory Wiki, and the internal `healthcheck`.
The three assistants have my chosen host-administration access; see
[access and credentials](security-model.md).
Private workspace contents and exact channel bindings are maintained separately.

```powershell
git clone https://github.com/ericchansen/my-openclaw.git
Set-Location my-openclaw
az login
az account set --subscription "<subscription-id>"
az bicep version
```

## Deploy

Run from PowerShell on your computer:

```powershell
.\deploy.ps1 -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub" `
  -BudgetContactEmails @("<budget-email>") `
  -DiagnosticsContactEmails @("<diagnostics-email>") `
  -EscalationContactEmails @("<escalation-email>")
```

Review the deployment preview before confirming. Recipient sets are independent;
`@()` declares no explicit recipients for that set. Diagnostic contacts receive
runtime health, disk, and capacity alerts. Escalation contacts receive sustained
VM-availability outage/recovery alerts. Budget contacts receive budget alerts.

Retrieve the host and vault:

```powershell
az network public-ip show -g rg-openclaw -n openclaw-pip --query dnsSettings.fqdn -o tsv
az keyvault list -g rg-openclaw --query "[].{name:name,uri:properties.vaultUri}" -o table
```

Verify the host key independently through Azure Console or Run Command with
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then connect:

```powershell
ssh "azureuser@<verified-vm-fqdn>"
```

On the VM:

```bash
sudo cloud-init status --wait
node --version
openclaw --version
systemctl status openclaw-otel-collector --no-pager
```

Versions should match [the manifest](../config/runtime-versions.json).
The Gateway remains stopped until configuration and authentication are complete.

## Configure credentials and the new installation

Seed the deployed vault through Azure Portal's **Secrets -> Generate/Import**:

| Secret | Used by |
|---|---|
| `OPENCLAW-GATEWAY-TOKEN` | Gateway authentication |
| `TELEGRAM-BOT-TOKEN` | Telegram |
| `DISCORD-BOT-TOKEN` | Discord |
| `BRAVE-API-KEY` | Brave Search |
| `EBIRD-API-KEY` | Both MCP integrations |
| `GOG-KEYRING-PASSWORD` | Optional Google CLI integration |

Fresh native Copilot device login uses OpenClaw's local credential store.
Existing vault-backed profiles can retain their dedicated `GITHUB-COPILOT-TOKEN`.
See [Key Vault integration](keyvault-integration.md) for this installation's
resolver and launchers. Secret values do not belong in commands or Git.
Remove the deployer's temporary Key Vault administrator assignment after seeding
unless continued access is intentional.

On the VM, check out the same commit used for deployment:

```bash
git clone https://github.com/ericchansen/my-openclaw.git "$HOME/my-openclaw"
cd "$HOME/my-openclaw"
git checkout --detach "<deployment-commit>"
umask 077
python3 - <<'PY'
from pathlib import Path
source = Path("config/openclaw.template.json")
target = Path.home() / ".openclaw/openclaw.json"
target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
with target.open("x", encoding="utf-8") as output:
    output.write(source.read_text(encoding="utf-8"))
PY
```

Exclusive creation refuses to replace an existing configuration. Personalize
all `YOUR_*` values and keys, including vault name and Telegram/Discord identities.
Paths assume runtime user `azureuser`; adjust them and the service unit together
if using a different user. The template's access settings are described in
[access and credentials](security-model.md).

Initialize through OpenClaw, which supplies its own workspace files:

```bash
openclaw config set agents.defaults.systemAgent.agentId main
openclaw setup --baseline
openclaw models auth login-github-copilot
openclaw config validate
```

The repository's `workspace/` files are reference templates, not applied during
initialization. Workspace customization follows
[OpenClaw's workspace guidance](https://docs.openclaw.ai/concepts/agent-workspace).

## Install the separately packaged diagnostics plugin

From the VM checkout:

```bash
version="$(node -p "require('./config/runtime-versions.json').packages['@openclaw/diagnostics-otel'].version")"
expected="$(node -p "require('./config/runtime-versions.json').packages['@openclaw/diagnostics-otel'].npmIntegrity")"
actual="$(npm view "@openclaw/diagnostics-otel@$version" dist.integrity --json)"
if test "$(printf '%s' "$actual" | jq -r .)" = "$expected"; then
  openclaw plugins install "npm:@openclaw/diagnostics-otel@$version" --pin --accept-capabilities &&
    openclaw plugins inspect diagnostics-otel --runtime --json
else
  printf 'Diagnostics plugin integrity mismatch.\n' >&2
fi
```

Resolve any failed install or integrity check before starting the Gateway.

## Activate

The installer supplies a system-scope Gateway unit and Tailscale Serve integration.
On the VM:

```bash
sudo tailscale up
sudo tailscale set --operator=azureuser
openclaw config validate
openclaw secrets audit --allow-exec --check
/usr/local/bin/openclaw-gateway-launch --check
sudo systemctl enable --now openclaw-gateway.service
curl --fail --retry 30 --retry-delay 3 --retry-connrefused \
  --max-time 5 --retry-max-time 90 http://127.0.0.1:18789/health
tailscale serve status
```

Use the HTTPS address from Serve on an authorized tailnet device. Device pairing
follows [OpenClaw's Control UI guide](https://docs.openclaw.ai/web/control-ui).
This installation does not expose the Gateway port publicly or use Tailscale Funnel.

Verify a real reply and tool operation through each configured channel, then
check configured search/MCP integrations and memory. Use the
[installation diagnostics](operations.md#diagnostics) for service checks and
[create a recovery snapshot](backup-restore.md#create-and-verify-a-snapshot).
