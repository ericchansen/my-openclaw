# From a fresh clone to a working OpenClaw

This installs the product described in [README](../README.md), not a reduced
starter. Run PowerShell blocks on your computer and Bash blocks on the VM as
`azureuser`, unless a command explicitly uses `sudo`.

**Already configured?** Do not initialize again or copy templates over your
files. Use [operations](operations.md) for reviewed patches and runtime updates,
or `migrate.ps1` for a verified, staged import of an existing installation.

## 1. Prepare accounts and local tools

Install Git, PowerShell 7, [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
its [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install),
Python 3 (for bundle checks), and OpenSSH. Use an Azure subscription where you
can deploy resources, create subscription budgets, and assign roles at both
resource-group and subscription scope. Resource Contributor alone cannot assign
roles; have the subscription administrator approve the required authority.

The defaults deploy Ubuntu ARM64 in `centralus`, a `Standard_D4ps_v6` VM
(4 vCPUs, 16 GiB RAM), a 64 GiB managed OS disk, a public IP/SSH bootstrap path,
Key Vault, Azure Monitor, and daily incremental snapshots retaining three
recovery points. Confirm regional image/SKU availability and quota first.
Review [Azure pricing](https://azure.microsoft.com/pricing/calculator/):
VM, disk, public IP, logs, snapshots, model usage, and connected services can
incur charges. The $150 subscription budget sends alerts; **it is not a spending
cap**. The VM identity receives subscription-wide Contributor and Cost Management
Contributor, deliberately enabling host-authorized Azure administration.

```powershell
git clone https://github.com/ericchansen/my-openclaw.git
Set-Location my-openclaw
az login
az account set --subscription "<subscription-id>"
az account show --query "{name:name,id:id}" --output table
az bicep version
```

If necessary, run `az bicep install`. If you do not have an SSH key, generate one
with `ssh-keygen -t ed25519`; choose a new filename rather than replacing an
existing key. Only the `.pub` file goes to deployment.

Prepare the accounts and identifiers for the configured integrations:

| Integration | What you supply |
|---|---|
| Native GitHub Copilot | An entitled account with access to GPT-6.1 Sol and the configured embedding model. Device login below authenticates it; a generic PAT is not a substitute. |
| Telegram | Create a bot through [BotFather](https://core.telegram.org/bots/tutorial#obtain-your-bot-token), keep its token private, and obtain your numeric sender ID. |
| Discord | Create a bot in the [Developer Portal](https://discord.com/developers/applications), enable required [intents](https://docs.openclaw.ai/channels/discord), invite it only to the intended server, and use Developer Mode to copy your user, guild, and agent-channel IDs. |
| Brave Search | A [Brave Search API](https://brave.com/search/api/) key. |
| eBird and Pondlog MCP | An [eBird API key](https://ebird.org/api/keygen); both installed launchers resolve `EBIRD-API-KEY`. |
| Tailscale | A tailnet, permission to enroll the VM, and authorized client devices. |
| Gmail/Google tools, when used | `gog` ARM64 installation, Google OAuth client/account authorization, and its keyring password. The repository does not install `gog` or create a Gmail watcher. |

Use your own identities throughout. Channel admission, identity linking, and
administrator grants are separate: see [the access profiles](security-model.md).
Do not broaden a grant just to clear a setup error.

## 2. Deploy and wait for bootstrap

Use the reviewed checkout; default resource group is `rg-openclaw`. Supply each
recipient set independently. `@()` omits explicit email recipients; the budget
also notifies subscription Owners.

```powershell
.\deploy.ps1 -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub" `
  -BudgetContactEmails @("<budget-email>") `
  -DiagnosticsContactEmails @("<diagnostics-email>") `
  -EscalationContactEmails @("<escalation-email>")
```

Review and confirm both deployment scopes. The script checks generated assets;
only maintainers who changed the sources need to regenerate them first.
Read the non-secret deployment outputs in Azure Portal, or retrieve the VM
address and vault name:

```powershell
az network public-ip show -g rg-openclaw -n openclaw-pip --query dnsSettings.fqdn -o tsv
az keyvault list -g rg-openclaw --query "[].{name:name,uri:properties.vaultUri}" -o table
```

Verify the VM's SSH host-key fingerprint independently, for example through the
Azure console/Run Command using `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
Only then accept that matching key when connecting:

```powershell
ssh "azureuser@<vm-fqdn>"
```

On the VM:

```bash
sudo cloud-init status --wait
node --version
openclaw --version
systemctl status openclaw-otel-collector --no-pager
```

Expect the versions in [runtime-versions.json](../config/runtime-versions.json).
An Azure deployment succeeding does not prove cloud-init succeeded. If bootstrap
fails, inspect `sudo cloud-init status --long` and
`sudo journalctl -u cloud-final --no-pager`; keep output private. Resolve the
reported dependency, permission, or network failure before activation.

**The Gateway is deliberately not running yet.** Configuration and the
diagnostics plugin are completed below. The health-probe timer can report
unhealthy while this initial setup is incomplete.

## 3. Seed secrets without putting values in commands

In Azure Portal, open the deployed Key Vault -> **Secrets** -> **Generate/Import**.
Use manual entry in that authenticated UI; never put values in deployment
parameters, shell history, Git, chat, or diagnostic output.

| Secret name | Purpose |
|---|---|
| `OPENCLAW-GATEWAY-TOKEN` | A newly generated strong random Gateway token, stored in your password manager and vault. |
| `TELEGRAM-BOT-TOKEN` | BotFather token. |
| `DISCORD-BOT-TOKEN` | Discord bot token. |
| `BRAVE-API-KEY` | Brave search credential. |
| `EBIRD-API-KEY` | Credential used by both MCP launchers. |
| `GITHUB-COPILOT-TOKEN` | For an existing vault-backed Copilot auth profile; fresh device login uses OpenClaw's protected local store instead. |
| `GITHUB-TOKEN` | Only for separately configured GitHub/Copilot CLI tooling, not native provider inference. |
| `GOG-KEYRING-PASSWORD` | Only when using the Google keyring integration. |

The VM's managed identity and installed resolver read only allowlisted names.
Do not run the resolver manually: its stdout contains resolved values.
If writes are denied, check the deployer's Key Vault administrator assignment
and allow RBAC propagation; do not grant the VM vault administration.
After seeding, remove the deployer's temporary Key Vault administrator assignment
through a reviewed role-management action unless continued access is intended.

## 4. Initialize only a new configuration

On the VM, clone this repository into an unused directory and check out the
same reviewed commit used for deployment:

```bash
git clone https://github.com/ericchansen/my-openclaw.git "$HOME/my-openclaw"
cd "$HOME/my-openclaw"
git checkout --detach "<reviewed-commit>"
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

Exclusive creation fails if the config already exists; **do not delete it to
retry**. Inspect the existing installation and use the update/migration path.

With your preferred editor, personalize the new `~/.openclaw/openclaw.json`:

- Replace every `YOUR_*` placeholder with the vault name, agent name, account
  name, and exact Telegram/Discord IDs. Replace placeholders in object keys too.
- Keep the channel, owner-command, elevated-exec, and identity-link entries
  consistent with the reviewed users; they serve different purposes.
- Keep the committed model/defaults and SecretRefs. If the runtime user is not
  `azureuser`, reconcile all absolute workspace/wiki paths and the installed
  systemd unit rather than leaving mixed home directories.

Find remaining placeholders without printing credentials:

```bash
python3 - <<'PY'
from pathlib import Path
import re
text = (Path.home() / ".openclaw/openclaw.json").read_text()
remaining = sorted(set(re.findall(r"YOUR_[A-Z0-9_]+", text)))
if remaining:
    raise SystemExit("Unresolved placeholders: " + ", ".join(remaining))
PY
```

Copy the repository's workspace templates **before** baseline setup; preserve
any file already present. From the VM checkout:

```bash
python3 - <<'PY'
from pathlib import Path
workspace = Path.home() / ".openclaw/workspace"
workspace.mkdir(mode=0o700, parents=True, exist_ok=True)
sources = [Path("workspace/AGENTS.md"), *Path("workspace").glob("*.template.md"),
           Path("workspace/skills/copilot-cli/SKILL.md")]
for source in sources:
    relative = source.relative_to("workspace")
    target = workspace / str(relative).replace(".template.md", ".md")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        output = target.open("x", encoding="utf-8")
    except FileExistsError:
        print(f"Preserved existing {target.name}")
        continue
    with output:
        output.write(source.read_text(encoding="utf-8"))
PY
openclaw config set agents.defaults.systemAgent.agentId main
openclaw setup --baseline
openclaw config validate
```

Fill in `USER.md`, `IDENTITY.md`, and non-secret `TOOLS.md` facts. The new
multi-agent installation needs an explicit system-agent owner (`main`); baseline
setup does not infer one. It creates runtime directories without launching
onboarding or installing another daemon. Existing installations must not repeat
this template-initialization path or replace their owner setting.
The [trusted-operator overlay](security-model.md#opt-in-trusted-operators) remains
an explicit reviewed grant, not something applied silently by setup.

## 5. Authenticate and install the deferred plugin

As the runtime user in an interactive SSH terminal:

```bash
openclaw models auth login-github-copilot
```

Complete the browser device flow with the intended account. Do not add `--yes`
or `--set-default`: preserve existing credentials and the configured Sol default.
The [native provider](https://docs.openclaw.ai/providers/github-copilot) stores a
protected local `tokenRef` for fresh login. To preserve/migrate an existing
vault-backed profile, follow [Key Vault integration](keyvault-integration.md)
and `openclaw secrets configure`; do not export the local store or substitute a PAT.

From the VM checkout, install the separately packaged diagnostics plugin:

```bash
version="$(node -p "require('./config/runtime-versions.json').packages['@openclaw/diagnostics-otel'].version")"
expected="$(node -p "require('./config/runtime-versions.json').packages['@openclaw/diagnostics-otel'].npmIntegrity")"
actual="$(npm view "@openclaw/diagnostics-otel@$version" dist.integrity --json)"
if test "$(printf '%s' "$actual" | jq -r .)" = "$expected"; then
  openclaw plugins install "npm:@openclaw/diagnostics-otel@$version" --pin --accept-capabilities &&
    openclaw plugins inspect diagnostics-otel --runtime --json
else
  printf 'Diagnostics plugin integrity mismatch; do not activate the Gateway.\n' >&2
fi
```

Stop on a failed install or integrity comparison. Confirm the plugin is enabled,
the source is npm, and resolved version/integrity match the manifest. Never use a
mutable package tag or force a replacement to suppress an error.

For Google tools, install `gog` using its
[upstream instructions](https://github.com/steipete/gogcli), complete its Google
OAuth/keyring setup privately as the runtime user, and seed the keyring secret.
Finish initial Gateway activation first. Then create and independently verify a
current-OS-disk snapshot and use the guarded
[runtime application](../README.md#apply-runtime-assets) to activate its existing
launcher before testing Google tools. Do not bypass the launcher by placing the
keyring password in the Gateway environment. Gmail hooks/watchers require their separately configured
account, destinations, and renewal schedule; they are not created by this template.

## 6. Enroll Tailscale and activate the existing Gateway

Enroll only in your intended tailnet, review its access policy and HTTPS/Serve
settings, and authorize the runtime user to manage this VM's Serve claim:

```bash
sudo tailscale up
sudo tailscale set --operator=azureuser
tailscale status
openclaw config validate
openclaw secrets audit --allow-exec --check
/usr/local/bin/openclaw-gateway-launch --check
sudo systemctl enable --now openclaw-gateway.service
curl --fail --retry 30 --retry-delay 3 --retry-connrefused \
  --max-time 5 --retry-max-time 90 http://127.0.0.1:18789/health &&
  tailscale serve status
```

If health retries fail, inspect `sudo journalctl -u openclaw-gateway --no-pager`
before continuing.

Complete Tailscale's interactive authorization when prompted. Enable HTTPS in
the tailnet if Serve requests it. Keep Funnel off. Do not expose port 18789
publicly, disable authentication, or run `openclaw gateway install`: the
repository already installed the system-scope service.

Open the HTTPS address reported by Serve from an authorized tailnet device.
Verified Tailscale identity plus browser device identity can authenticate the
Control UI without pasting a shared token. If pairing is requested:

```bash
openclaw devices list
openclaw devices approve "<reviewed-request-id>"
```

Verify the requesting device/scopes before approval. For limited-access repair,
follow the pinned [Control UI pairing guide](https://github.com/openclaw/openclaw/blob/v2026.10.3/docs/web/control-ui/connect-and-pair.md);
never share dashboard pairing links or put them in logs.

## 7. Prove the product works

Use [operations diagnostics](operations.md#health-and-incidents), then:

1. Send a harmless request from each intended real Telegram/Discord identity.
   Require one delivered reply and a successful tool receipt/readback, not
   merely an HTTP health response.
2. Verify native Sol inference and embedding/memory functionality. Exercise Brave
   and both MCP integrations; authenticate any configured Google operations.
3. Force the isolated [application canary](availability-recovery.md#application-canary).
   Test one disposable, explicitly approved automation and inspect execution
   and delivery separately; never replay personal jobs as a setup test.
4. Check `systemctl list-timers --all`, collector status, and
   [metadata ingestion](telemetry-privacy.md). Content capture stays off.
5. Run `sudo systemctl start openclaw-vm-snapshot.service` and inspect its journal.
   Independently confirm the snapshot is `Succeeded` for the current OS disk
   using [the recovery procedure](backup-restore.md#pre-change-recovery-point).

If any check fails, stop at that step, retain private diagnostics, and follow
[operations and recovery](operations.md). Do not rerun onboarding, replace the
config with a template, relax access controls, or claim completion based only on
a running service.
