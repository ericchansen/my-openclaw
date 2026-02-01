# My OpenClaw Docker Setup

Personal OpenClaw Docker Compose configuration with persistent state.

## Quick Start

```powershell
# First time setup:
# 1. Copy template config to volume
Copy-Item openclaw.template.json F:\openclaw\config\openclaw.json

# 2. Run Copilot device login on host (one-time)
openclaw models auth login-github-copilot

# 3. Start the gateway
docker compose up -d openclaw-gateway

# 4. Open dashboard
# http://localhost:18789/?token=REDACTED
```

## Directory Structure

- **This directory**: Docker Compose config and environment variables
- **F:\openclaw\config**: OpenClaw configuration and credentials
- **F:\openclaw\workspace**: Session data and agent workspace
- **~/.openclaw/agents/main/agent/auth-profiles.json**: Copilot credentials (mounted into Docker)

## Common Commands

```powershell
# Interactive CLI
docker compose run --rm openclaw-cli

# Run specific command
docker compose run --rm openclaw-cli channels status

# View gateway logs
docker compose logs -f openclaw-gateway

# Restart gateway
docker compose restart openclaw-gateway

# Stop everything
docker compose down
```

## Re-authenticating Copilot

When the token expires:
```powershell
openclaw models auth login-github-copilot
docker compose restart openclaw-gateway
```

## Configuration

- `.env` - Environment variables (tokens, paths)
- `openclaw.template.json` - Baseline config template
- `F:\openclaw\config\openclaw.json` - Live config (modify via CLI or dashboard)
