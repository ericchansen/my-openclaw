param(
    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [string]$ResourceGroupName = "rg-openclaw",
    [string]$Location = "centralus",
    [string]$SubscriptionId = "",
    [string]$DeployerPrincipalId = "",
    [ValidateSet("User", "ServicePrincipal")]
    [string]$DeployerPrincipalType = "User",
    [string[]]$MonitoringContactEmails = @(),
    [ValidatePattern('^(latest|[0-9]+\.[0-9]+\.[0-9]+)$')]
    [string]$UbuntuImageVersion = "24.04.202607140",
    [string]$VerifiedSnapshotId = "",
    [switch]$SkipCustomData,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$Json
    )

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
    if ($Json) {
        return (($output -join "`n") | ConvertFrom-Json)
    }
    return $output
}

function Assert-SnapshotMatchesDisk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotId,
        [Parameter(Mandatory = $true)]
        [string]$DiskId
    )

    $snapshot = Invoke-Az -Arguments @(
        "snapshot", "show",
        "--ids", $SnapshotId,
        "--output", "json"
    ) -Json
    if (
        $snapshot.provisioningState -ne "Succeeded" -or
        -not [string]::Equals(
            [string]$snapshot.creationData.sourceResourceId,
            $DiskId,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "The verified snapshot is not a succeeded snapshot of the current VM OS disk."
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is required."
}
if (-not (Test-Path -LiteralPath $SshPublicKeyPath)) {
    throw "SSH public key not found: $SshPublicKeyPath"
}
$sshKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()
if (-not $sshKey) {
    throw "SSH public key file is empty: $SshPublicKeyPath"
}
if ($SubscriptionId) {
    Invoke-Az -Arguments @("account", "set", "--subscription", $SubscriptionId, "--output", "none")
}
$account = Invoke-Az -Arguments @("account", "show", "--output", "json") -Json
$SubscriptionId = $account.id
Write-Host "Using subscription '$($account.name)' ($SubscriptionId)." -ForegroundColor DarkCyan

$resourceGroupExists = [bool]::Parse(
    [string](Invoke-Az -Arguments @(
        "group", "exists",
        "--subscription", $SubscriptionId,
        "--name", $ResourceGroupName,
        "--output", "tsv"
    ))
)
$existingVm = $null
if ($resourceGroupExists) {
    $existingVm = Invoke-Az -Arguments @(
        "vm", "list",
        "--subscription", $SubscriptionId,
        "--resource-group", $ResourceGroupName,
        "--query", "[?name=='openclaw-vm'] | [0]",
        "--output", "json"
    ) -Json
}
if ($existingVm -and -not $SkipCustomData) {
    $SkipCustomData = [System.Management.Automation.SwitchParameter]::new($true)
    Write-Host (
        "Detected existing VM 'openclaw-vm'; enabling snapshot-gated existing-VM mode."
    ) -ForegroundColor Yellow
}
elseif (-not $existingVm -and $SkipCustomData) {
    throw "-SkipCustomData requires an existing 'openclaw-vm' in the target resource group."
}

if (-not $DeployerPrincipalId -and -not $SkipCustomData) {
    if ($account.user.type -eq "user") {
        $resolvedPrincipal = Invoke-Az -Arguments @(
            "ad", "signed-in-user", "show",
            "--query", "id",
            "--output", "tsv"
        )
    }
    elseif ($account.user.type -eq "servicePrincipal") {
        $DeployerPrincipalType = "ServicePrincipal"
        $resolvedPrincipal = Invoke-Az -Arguments @(
            "ad", "sp", "show",
            "--id", $account.user.name,
            "--query", "id",
            "--output", "tsv"
        )
    }
    else {
        throw "Pass -DeployerPrincipalId for this Azure account type."
    }
    $DeployerPrincipalId = [string]($resolvedPrincipal | Select-Object -First 1)
    $DeployerPrincipalId = $DeployerPrincipalId.Trim()
    if (-not $DeployerPrincipalId) {
        throw "Could not resolve the deployer principal. Pass -DeployerPrincipalId explicitly."
    }
}

$template = Join-Path $PSScriptRoot "infra\main.bicep"
$subscriptionTemplate = Join-Path $PSScriptRoot "infra\main-subscription.bicep"
$effectiveUbuntuImageVersion = $UbuntuImageVersion
$effectiveVmSize = ""
$effectiveOsDiskSizeGB = 0
if ($SkipCustomData) {
    if (-not $VerifiedSnapshotId) {
        throw "-VerifiedSnapshotId is required for existing-VM deployments."
    }
    $effectiveUbuntuImageVersion = [string]$existingVm.storageProfile.imageReference.version
    $effectiveVmSize = [string]$existingVm.hardwareProfile.vmSize
    $osDiskId = [string]$existingVm.storageProfile.osDisk.managedDisk.id
    $osDisk = Invoke-Az -Arguments @(
        "disk", "show",
        "--ids", $osDiskId,
        "--output", "json"
    ) -Json
    $effectiveOsDiskSizeGB = [int]$osDisk.diskSizeGb
    if (
        -not $effectiveUbuntuImageVersion -or
        -not $effectiveVmSize -or
        -not $osDiskId -or
        $effectiveOsDiskSizeGB -le 0
    ) {
        throw "Could not determine the existing VM image, size, or OS disk size."
    }
    Assert-SnapshotMatchesDisk -SnapshotId $VerifiedSnapshotId -DiskId $osDiskId
    Write-Host (
        "Existing-VM mode preserves image '$effectiveUbuntuImageVersion', size " +
        "'$effectiveVmSize', OS disk '$effectiveOsDiskSizeGB GiB', and existing NSG rules."
    ) -ForegroundColor Yellow
}
$groupParameters = @(
    "sshPublicKey=$sshKey",
    "skipCustomData=$($SkipCustomData.IsPresent.ToString().ToLowerInvariant())",
    "ubuntuImageVersion=$effectiveUbuntuImageVersion"
)
if ($SkipCustomData) {
    $groupParameters += "vmSize=$effectiveVmSize"
    $groupParameters += "osDiskSizeGB=$effectiveOsDiskSizeGB"
}
if ($DeployerPrincipalId) {
    $groupParameters += "deployerPrincipalId=$DeployerPrincipalId"
    $groupParameters += "deployerPrincipalType=$DeployerPrincipalType"
}
if ($MonitoringContactEmails.Count -gt 0) {
    foreach ($email in $MonitoringContactEmails) {
        if ($email -notmatch '^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
            throw "Invalid monitoring contact email."
        }
    }
    $emailArray = "['" + ($MonitoringContactEmails -join "','") + "']"
    $groupParameters += "monitoringContactEmails=$emailArray"
}

Write-Host "`n=== OpenClaw Azure VM Deployment ===" -ForegroundColor Cyan
Write-Host "`n[1/7] Ensuring resource group '$ResourceGroupName' exists..."
Invoke-Az -Arguments @(
    "group", "create",
    "--subscription", $SubscriptionId,
    "--name", $ResourceGroupName,
    "--location", $Location,
    "--output", "none"
)

$groupBaseArgs = @(
    "--subscription", $SubscriptionId,
    "--resource-group", $ResourceGroupName,
    "--template-file", $template,
    "--parameters"
) + $groupParameters

Write-Host "`n[2/7] Validating resource-group deployment..."
Invoke-Az -Arguments (@("deployment", "group", "validate") + $groupBaseArgs + @("--output", "none"))

Write-Host "`n[3/7] Running resource-group what-if..."
Invoke-Az -Arguments (@("deployment", "group", "what-if") + $groupBaseArgs)

if (-not $Force) {
    $continue = Read-Host "`nProceed with the resource-group deployment? (y/n)"
    if ($continue -ne "y") {
        Write-Host "Deployment cancelled."
        exit 0
    }
}

Write-Host "`n[4/7] Deploying resource-group infrastructure..."
$result = Invoke-Az -Arguments (
    @("deployment", "group", "create") + $groupBaseArgs + @("--output", "json")
) -Json
$outputs = $result.properties.outputs
$vmPrincipalId = $outputs.vmPrincipalId.value
$existingBudgetStartDate = & az consumption budget show `
    --subscription $SubscriptionId `
    --budget-name "openclaw-monthly-budget" `
    --query "timePeriod.startDate" `
    --output tsv `
    --only-show-errors 2>$null
$budgetStartDate = if ($LASTEXITCODE -eq 0 -and $existingBudgetStartDate) {
    ($existingBudgetStartDate | Select-Object -First 1).Trim()
}
else {
    (Get-Date -Day 1).ToUniversalTime().ToString("yyyy-MM-01T00:00:00Z")
}
$subscriptionParameters = @(
    "vmPrincipalId=$vmPrincipalId",
    "budgetStartDate=$budgetStartDate"
)
if ($MonitoringContactEmails.Count -gt 0) {
    $subscriptionParameters += "contactEmails=$emailArray"
}
$subscriptionBaseArgs = @(
    "--subscription", $SubscriptionId,
    "--location", $Location,
    "--template-file", $subscriptionTemplate,
    "--parameters"
) + $subscriptionParameters

Write-Host "`n[5/7] Validating subscription deployment..."
Invoke-Az -Arguments (@("deployment", "sub", "validate") + $subscriptionBaseArgs + @("--output", "none"))

Write-Host "`n[6/7] Running subscription what-if..."
Invoke-Az -Arguments (@("deployment", "sub", "what-if") + $subscriptionBaseArgs)

if (-not $Force) {
    $continue = Read-Host "`nProceed with the subscription-wide deployment? (y/n)"
    if ($continue -ne "y") {
        Write-Host "Subscription deployment cancelled."
        exit 0
    }
}

Write-Host "`n[7/7] Deploying subscription budget and RBAC..."
$subResult = Invoke-Az -Arguments (
    @("deployment", "sub", "create") + $subscriptionBaseArgs + @("--output", "json")
) -Json

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host "VM Public IP:   $($outputs.vmPublicIp.value)"
Write-Host "VM FQDN:        $($outputs.vmFqdn.value)"
Write-Host "SSH Command:    $($outputs.sshCommand.value)"
Write-Host "Key Vault:      $($outputs.keyVaultName.value)"
Write-Host "Backup Storage: $($outputs.backupStorageAccountName.value)/$($outputs.backupContainerName.value)"
Write-Host "Log Analytics:  $($outputs.logAnalyticsWorkspaceName.value)"
Write-Host "Budget:         $($subResult.properties.outputs.budgetName.value)"
Write-Host "Gateway:        $($outputs.gatewayNote.value)"
Write-Host "`nFor an existing VM, apply canonical runtime assets with scripts\apply-runtime.ps1." -ForegroundColor Yellow
