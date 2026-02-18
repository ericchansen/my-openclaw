# My OpenClaw Setup

Personal OpenClaw configuration and operational patterns — Azure VM deployment with Key Vault, Tailscale, and systemd.

## What's Here

This repo contains:
- **Azure VM deployment** — Bicep templates for VM + Key Vault + Tailscale
- **Workspace templates** — Agent configuration files ready to customize
- **Operational docs** — Patterns for agent orchestration, cron, and more

## Directory Structure

```
my-openclaw/
├── config/
│   ├── openclaw.template.json    # Full config template (copy + customize)
│   └── openclaw-gateway.service  # Production systemd service
├── workspace/
│   ├── AGENTS.md                 # Agent instructions (use as-is)
│   ├── SOUL.template.md          # Agent personality (customize)
│   ├── USER.template.md          # Your info (customize)
│   ├── IDENTITY.template.md      # Agent identity (customize)
│   ├── HEARTBEAT.template.md     # Periodic checks (customize)
│   ├── TOOLS.template.md         # Local tool notes (customize)
│   └── skills/
│       └── copilot-cli/          # Copilot CLI orchestration skill
├── docs/
│   ├── orchestrator-pattern.md   # Subagent delegation patterns
│   ├── agent-hierarchy.md        # Main/orchestrator/subagent roles
│   ├── cron-patterns.md          # Scheduled task patterns
│   ├── keyvault-integration.md   # Azure Key Vault usage
│   └── todo-conventions.md       # Task tracking guidelines
├── infra/
│   ├── main.bicep                # Azure resources (VM, Key Vault, VNet)
│   ├── main.bicepparam           # Deployment parameters
│   └── cloud-init.yaml           # VM bootstrap (Node, Tailscale, OpenClaw)
├── azure.yaml                    # azd project manifest
├── deploy.ps1                    # Azure deployment script
└── migrate.ps1                   # Docker → VM migration
```

## Fork & Customize

This repo is meant to be forked and personalized. Here's how:

### 1. Fork the Repository

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/my-openclaw.git
cd my-openclaw
```

### 2. Create Your Config

```bash
# Copy the template
cp config/openclaw.template.json ~/.openclaw/openclaw.json

# Edit with your values:
# - Bot tokens (Telegram, Discord)
# - Gateway token
# - User IDs for allowlists
# - Agent identity
```

### 3. Set Up Your Workspace

```bash
mkdir -p ~/.openclaw/workspace

# Copy AGENTS.md as-is (it's ready to use)
cp workspace/AGENTS.md ~/.openclaw/workspace/

# Copy and customize the templates
cp workspace/SOUL.template.md ~/.openclaw/workspace/SOUL.md
cp workspace/USER.template.md ~/.openclaw/workspace/USER.md
cp workspace/IDENTITY.template.md ~/.openclaw/workspace/IDENTITY.md
cp workspace/HEARTBEAT.template.md ~/.openclaw/workspace/HEARTBEAT.md
cp workspace/TOOLS.template.md ~/.openclaw/workspace/TOOLS.md

# Copy skills
cp -r workspace/skills ~/.openclaw/workspace/
```

### 4. Edit Your Files

- **SOUL.md** — Agent personality and values
- **USER.md** — Your name, timezone, preferences
- **IDENTITY.md** — Agent name, emoji, accounts
- **TOOLS.md** — Local infrastructure notes

### 5. Store Secrets Securely

Never commit secrets. Use:
- **Azure Key Vault** (for VM deployments)
- **Environment variables** (for local setups)
- **`.env` files** (gitignored)

## Azure VM Deployment

### Prerequisites

- Azure CLI (`az`) logged in
- SSH key pair (`~/.ssh/id_ed25519`)

### Deploy with azd

```bash
azd up
```

### Deploy with Script

```powershell
.\deploy.ps1 -SshPublicKeyPath "~\.ssh\id_ed25519.pub"
```

### Post-Deployment

```bash
# SSH in (port forwards gateway)
ssh openclaw

# Wait for cloud-init
cloud-init status --wait

# Join Tailscale
sudo tailscale up

# Load secrets from Key Vault
source openclaw-fetch-secrets <vault-name>

# Start gateway
sudo systemctl start openclaw-gateway
```

### SSH Config

Add to `~/.ssh/config`:

```
Host openclaw
    HostName <VM_FQDN>
    User azureuser
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 18789 127.0.0.1:18789
```

## Key Vault Secrets

Store these in Azure Key Vault:

| Secret | Purpose |
|--------|---------|
| `OPENCLAW-GATEWAY-TOKEN` | Gateway auth |
| `GITHUB-TOKEN` | Repo access |
| `TELEGRAM-BOT-TOKEN` | Telegram bot |
| `DISCORD-BOT-TOKEN` | Discord bot |

```bash
az keyvault secret set --vault-name <vault> --name GITHUB-TOKEN --value "ghp_xxx"
```

## Documentation

See the `docs/` folder for operational patterns:

- **[Orchestrator Pattern](docs/orchestrator-pattern.md)** — Delegate tasks to subagents
- **[Agent Hierarchy](docs/agent-hierarchy.md)** — Main, orchestrator, and subagent roles
- **[Cron Patterns](docs/cron-patterns.md)** — Scheduled automation
- **[Key Vault Integration](docs/keyvault-integration.md)** — Secure secret management
- **[TODO Conventions](docs/todo-conventions.md)** — Task tracking best practices

## Architecture

```
Azure Resource Group
├── VM (Ubuntu 24.04 ARM64)
│   ├── System-assigned managed identity
│   ├── OpenClaw gateway (systemd, loopback)
│   ├── Tailscale (mesh VPN)
│   └── Copilot CLI
├── Key Vault (RBAC, secrets)
├── VNet + NSG (SSH only)
└── Public IP (static, DNS)
```

## License

Personal configuration repository. Fork and customize for your own use.
