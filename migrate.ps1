# Migrate local OpenClaw data to Azure VM
# Usage: .\migrate.ps1 -VmHost "azureuser@<VM_FQDN_OR_IP>"
#
# Transfers your config and workspace so the VM picks up where you left off.
# Requires: ssh + scp available in PATH (OpenSSH client on Windows)

param(
    [Parameter(Mandatory=$true)]
    [string]$VmHost,

    [string]$ConfigDir = "F:\openclaw\config",
    [string]$WorkspaceDir = "F:\openclaw\workspace",
    [string]$SshKeyPath = "$HOME\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"
$sshArgs = @("-i", $SshKeyPath, "-o", "StrictHostKeyChecking=no")

Write-Host "`n=== OpenClaw Migration to Azure VM ===" -ForegroundColor Cyan

# Verify source directories exist
if (-not (Test-Path $ConfigDir)) { Write-Error "Config dir not found: $ConfigDir"; exit 1 }
if (-not (Test-Path $WorkspaceDir)) { Write-Error "Workspace dir not found: $WorkspaceDir"; exit 1 }

# 1. Create target directories on VM
Write-Host "`n[1/4] Creating directories on VM..."
ssh @sshArgs $VmHost "mkdir -p ~/.openclaw/workspace"

# 2. Transfer config (contains openclaw.json, credentials, agents, cron, etc.)
Write-Host "`n[2/4] Uploading config directory..."
scp @sshArgs -r "${ConfigDir}\*" "${VmHost}:~/.openclaw/"

# 3. Transfer workspace (contains memory, identity docs, etc.)
Write-Host "`n[3/4] Uploading workspace directory..."
scp @sshArgs -r "${WorkspaceDir}\*" "${VmHost}:~/.openclaw/workspace/"

# 4. Fix Docker paths in config
Write-Host "`n[4/5] Fixing Docker paths in config..."
ssh @sshArgs $VmHost "sed -i 's|/home/node|/home/`$(whoami)|g' ~/.openclaw/openclaw.json"
ssh @sshArgs $VmHost "sed -i 's|/home/`$(whoami)/repos/openclaw|/home/`$(whoami)/.openclaw/workspace|g' ~/.openclaw/openclaw.json"

# 5. Verify transfer
Write-Host "`n[5/5] Verifying transfer..."
ssh @sshArgs $VmHost @"
echo '--- Config files ---'
ls -la ~/.openclaw/
echo ''
echo '--- Workspace files ---'
ls -la ~/.openclaw/workspace/
echo ''
echo '--- openclaw.json ---'
test -f ~/.openclaw/openclaw.json && echo 'Found' || echo 'MISSING'
"@

Write-Host "`n=== Migration Complete ===" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. SSH into the VM:  ssh $sshArgs $VmHost"
Write-Host "  2. Set gateway token:  export OPENCLAW_GATEWAY_TOKEN='<your-token>'"
Write-Host "  3. Set any other env vars (GITHUB_TOKEN, etc.) in ~/.bashrc"
Write-Host "  4. Start the gateway:  sudo systemctl start openclaw-gateway"
Write-Host "  5. Verify:  openclaw doctor"
Write-Host ""
Write-Host "  To add env vars to the systemd service permanently:" -ForegroundColor DarkYellow
Write-Host "    sudo systemctl edit openclaw-gateway"
Write-Host "    Add: Environment=OPENCLAW_GATEWAY_TOKEN=<your-token>"
Write-Host "    Then: sudo systemctl restart openclaw-gateway"
