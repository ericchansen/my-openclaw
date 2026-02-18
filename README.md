# My OpenClaw Setup

Personal OpenClaw configuration — Azure VM deployment with Key Vault, Tailscale, and systemd.

## Azure VM Deployment (Recommended)

Deploys a VM with Key Vault for secret management, Tailscale for secure access, and systemd for the gateway service.

### Prerequisites

- Azure CLI (`az`) logged in
- SSH key pair (`~/.ssh/id_ed25519`)

### Deploy with azd

```bash
azd up
```

### Deploy with scripts

```powershell
# Basic deploy
.\deploy.ps1 -SshPublicKeyPath "~\.ssh\id_ed25519.pub"

# Deploy and seed Key Vault secrets
.\deploy.ps1 -SshPublicKeyPath "~\.ssh\id_ed25519.pub" -GatewayToken "mytoken" -GitHubToken "ghp_xxx"
```

### Post-deployment

```bash
# 1. SSH in (port forwards the gateway automatically)
ssh openclaw

# 2. Wait for cloud-init
cloud-init status --wait

# 3. Join Tailscale
sudo tailscale up

# 4. Load secrets from Key Vault
source openclaw-fetch-secrets <vault-name>

# 5. Run onboarding or start gateway
openclaw onboard
sudo systemctl start openclaw-gateway
```

### Migrate from Docker

```powershell
.\migrate.ps1 -VmHost "azureuser@<VM_FQDN>"
```

Copies config + workspace from `F:\openclaw\` to the VM and fixes Docker-specific paths.

### SSH config

Add to `~/.ssh/config` for easy access:

```
Host openclaw
    HostName <VM_FQDN>
    User azureuser
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 18789 127.0.0.1:18789
```

Then `ssh openclaw` gives you a shell + gateway at `http://127.0.0.1:18789`.

### Key Vault

Secrets are stored in Azure Key Vault and fetched via managed identity:

- `OPENCLAW-GATEWAY-TOKEN` — gateway auth token
- `GITHUB-TOKEN` — GitHub PAT for repo access

Add/update secrets:
```bash
az keyvault secret set --vault-name <vault-name> --name OPENCLAW-GATEWAY-TOKEN --value "mytoken"
az keyvault secret set --vault-name <vault-name> --name GITHUB-TOKEN --value "ghp_xxx"
```

### Architecture

```
Azure Resource Group (rg-openclaw)
├── VM (Standard_B2pls_v2, Ubuntu 24.04 ARM64)
│   ├── System-assigned managed identity
│   ├── OpenClaw gateway (systemd, loopback-only)
│   ├── Tailscale (mesh VPN)
│   └── Copilot CLI (prerelease)
├── Key Vault (RBAC, secrets for gateway + GitHub)
├── VNet + NSG (SSH only, no public gateway ports)
└── Public IP (static, DNS label)
```

## Directory Structure

```
my-openclaw/
├── azure.yaml              # azd project manifest
├── deploy.ps1              # Azure VM deployment script
├── migrate.ps1             # Docker → VM data migration
├── infra/
│   ├── main.bicep          # VM + Key Vault + VNet + NSG
│   ├── main.bicepparam     # Parameters file
│   └── cloud-init.yaml     # VM bootstrap (Node, Tailscale, Azure CLI, OpenClaw)
└── openclaw.template.json  # Baseline config template
```
