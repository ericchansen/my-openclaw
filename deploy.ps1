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
Write-Host "`n[1/4] Creating resource group '$ResourceGroupName' in '$Location'..."
az group create --name $ResourceGroupName --location $Location --output none

# What-if validation
Write-Host "`n[2/4] Running what-if validation..."
$whatifCmd = "az deployment group what-if --resource-group $ResourceGroupName --template-file `"$PSScriptRoot\infra\main.bicep`" --parameters $paramStr"
Invoke-Expression $whatifCmd

# Prompt to continue
$continue = Read-Host "`nProceed with deployment? (y/n)"
if ($continue -ne 'y') {
    Write-Host "Deployment cancelled."
    exit 0
}

# Deploy
Write-Host "`n[3/4] Deploying infrastructure..."
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

# Deploy subscription-scoped resources (budget alerts + RBAC roles)
Write-Host "`n[4/4] Deploying subscription-scoped resources (budget + RBAC)..."
$vmPrincipalId = $outputs.vmPrincipalId.value
$budgetStartDate = (Get-Date -Day 1).ToString("yyyy-MM-01T00:00:00Z")
$subResult = az deployment sub create `
    --location $Location `
    --template-file "$PSScriptRoot\infra\main-subscription.bicep" `
    --parameters vmPrincipalId=$vmPrincipalId budgetStartDate=$budgetStartDate `
    --output json | ConvertFrom-Json

$subOutputs = $subResult.properties.outputs
Write-Host "Budget:         $($subOutputs.budgetName.value)" -ForegroundColor Green
Write-Host "Cost Mgmt Role: assigned" -ForegroundColor Green
Write-Host "Contributor:    assigned" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. SSH into the VM:  $($outputs.sshCommand.value)"
Write-Host "  2. Wait for cloud-init:  cloud-init status --wait"
Write-Host "  3. Load secrets:  source openclaw-fetch-secrets $($outputs.keyVaultName.value)"
Write-Host "  4. Run onboarding:  openclaw onboard"
Write-Host "  5. Start the gateway:  sudo systemctl start openclaw-gateway"
