# OpenClaw Azure VM Deployment
# Usage: .\deploy.ps1 -SshPublicKeyPath "~\.ssh\id_ed25519.pub"
# Optionally seed Key Vault: .\deploy.ps1 -SshPublicKeyPath "~\.ssh\id_ed25519.pub" -GatewayToken "mytoken" -GitHubToken "ghp_xxx"

param(
    [Parameter(Mandatory=$true)]
    [string]$SshPublicKeyPath,

    [string]$ResourceGroupName = "rg-openclaw",
    [string]$Location = "centralus",
    [string]$GatewayToken = "",
    [string]$GitHubToken = ""
)

$ErrorActionPreference = "Stop"

# Read SSH public key
$sshKey = (Get-Content $SshPublicKeyPath -Raw).Trim()
if (-not $sshKey) {
    Write-Error "SSH public key file is empty: $SshPublicKeyPath"
    exit 1
}

# Build parameters
$params = @("sshPublicKey=$sshKey")
if ($GatewayToken) { $params += "openclawGatewayToken=$GatewayToken" }
if ($GitHubToken) { $params += "githubToken=$GitHubToken" }
$paramStr = ($params | ForEach-Object { $_ }) -join " "

Write-Host "`n=== OpenClaw Azure VM Deployment ===" -ForegroundColor Cyan

# Create resource group
Write-Host "`n[1/3] Creating resource group '$ResourceGroupName' in '$Location'..."
az group create --name $ResourceGroupName --location $Location --output none

# What-if validation
Write-Host "`n[2/3] Running what-if validation..."
$whatifCmd = "az deployment group what-if --resource-group $ResourceGroupName --template-file `"$PSScriptRoot\infra\main.bicep`" --parameters $paramStr"
Invoke-Expression $whatifCmd

# Prompt to continue
$continue = Read-Host "`nProceed with deployment? (y/n)"
if ($continue -ne 'y') {
    Write-Host "Deployment cancelled."
    exit 0
}

# Deploy
Write-Host "`n[3/3] Deploying infrastructure..."
$deployCmd = "az deployment group create --resource-group $ResourceGroupName --template-file `"$PSScriptRoot\infra\main.bicep`" --parameters $paramStr --output json"
$result = Invoke-Expression $deployCmd | ConvertFrom-Json

# Output results
$outputs = $result.properties.outputs
Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host "VM Public IP:   $($outputs.vmPublicIp.value)"
Write-Host "VM FQDN:        $($outputs.vmFqdn.value)"
Write-Host "SSH Command:    $($outputs.sshCommand.value)"
Write-Host "Key Vault:      $($outputs.keyVaultName.value)"
Write-Host "Key Vault URI:  $($outputs.keyVaultUri.value)"
Write-Host "Gateway:        $($outputs.gatewayNote.value)"
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. SSH into the VM:  $($outputs.sshCommand.value)"
Write-Host "  2. Wait for cloud-init:  cloud-init status --wait"
Write-Host "  3. Load secrets:  source openclaw-fetch-secrets $($outputs.keyVaultName.value)"
Write-Host "  4. Run onboarding:  openclaw onboard"
Write-Host "  5. Start the gateway:  sudo systemctl start openclaw-gateway"
