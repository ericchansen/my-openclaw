param(
    [string]$SshPublicKeyPath = "",
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
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    $output = @(& az @Arguments --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI operation failed; parameter values and response content were suppressed."
    }
    if (-not $Json) { return $output }
    try { return (($output -join "`n") | ConvertFrom-Json -Depth 100) }
    catch { throw "Azure CLI returned invalid JSON; response content was suppressed." }
}

function Assert-SnapshotMatchesDisk {
    param([string]$SnapshotId, [string]$DiskId)
    if (-not $SnapshotId -or -not $DiskId) { throw "An existing-host update requires a verified OS-disk snapshot." }
    $snapshot = Invoke-Az @("snapshot", "show", "--ids", $SnapshotId, "--output", "json") -Json
    if ($snapshot.provisioningState -ne "Succeeded" -or
        -not [string]::Equals($snapshot.creationData.sourceResourceId, $DiskId,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Snapshot is not a succeeded recovery point for the current VM OS disk."
    }
}

function Get-UnsafeWhatIfChanges {
    param([object[]]$Changes, [bool]$ExistingHost)
    $monitorTypes = @(
        "Microsoft.Resources/deployments",
        "Microsoft.OperationalInsights/workspaces", "Microsoft.OperationalInsights/workspaces/tables",
        "Microsoft.Insights/dataCollectionRules", "Microsoft.Insights/dataCollectionRuleAssociations",
        "Microsoft.Insights/actionGroups", "Microsoft.Insights/metricAlerts", "Microsoft.Insights/scheduledQueryRules",
        "Microsoft.Compute/virtualMachines/extensions"
    )
    foreach ($change in $Changes) {
        if ($change.changeType -in @("NoChange", "Ignore")) { continue }
        $parts = ([string]$change.resourceId -split "(?i)/providers/")[-1].Trim("/").Split("/")
        if ($parts.Count -lt 3 -or $parts.Count % 2 -ne 1) {
            "Unknown resource identity in what-if"
            continue
        }
        $type = $parts[0]
        for ($i = 1; $i -lt $parts.Count; $i += 2) { $type += "/" + $parts[$i] }
        if ($change.changeType -notin @("Create", "Modify")) {
            "Unsupported/destructive what-if action: $($change.changeType) $type"
        }
        elseif (($ExistingHost -or $change.changeType -eq "Modify") -and $type -notin $monitorTypes) {
            "Protected resource change: $($change.changeType) $type"
        }
        elseif ($type -eq "Microsoft.Compute/virtualMachines/extensions" -and $parts[-1] -ne "AzureMonitorLinuxAgent") {
            "Only the Azure Monitor extension is managed by this deployment"
        }
        elseif ($change.changeType -eq "Modify" -and $type -eq "Microsoft.OperationalInsights/workspaces" -and
            $change.before.properties.sku.name -ne $change.after.properties.sku.name) {
            "Monitoring updates must preserve the existing workspace pricing tier"
        }
    }
}

function Write-Parameters {
    param([hashtable]$Values, [string]$Path)
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{value = $Values[$key]} }
    @{parameters = $parameters} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
    if (-not $IsWindows) {
        & chmod 0600 $Path
        if ($LASTEXITCODE -ne 0) { throw "Could not protect deployment parameters." }
    }
}

function Confirm-Deployment {
    param([string]$Scope)
    if (-not $Force -and (Read-Host "Apply the reviewed $Scope deployment? (y/n)") -ne "y") {
        throw "Deployment cancelled."
    }
}

function Get-GroupPreview {
    param([string[]]$Arguments)
    Invoke-Az (@("deployment", "group", "what-if") + $Arguments +
        @("--no-pretty-print", "--result-format", "FullResourcePayloads", "-o", "json")) -Json
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required." }
if ($SubscriptionId) { Invoke-Az @("account", "set", "--subscription", $SubscriptionId) | Out-Null }
$account = Invoke-Az @("account", "show", "--output", "json") -Json
$SubscriptionId = $account.id
$groupExists = [bool]::Parse([string](Invoke-Az @("group", "exists", "-n", $ResourceGroupName, "--output", "tsv")))
$existingVm = if ($groupExists) {
    Invoke-Az @("vm", "list", "-g", $ResourceGroupName, "--query", "[?name=='openclaw-vm'] | [0]", "--output", "json") -Json
} else { $null }
if ($SkipCustomData -and -not $existingVm) { throw "-SkipCustomData requires an existing openclaw-vm." }
if ($existingVm) {
    Assert-SnapshotMatchesDisk $VerifiedSnapshotId $existingVm.storageProfile.osDisk.managedDisk.id
    if ($DeployerPrincipalId) { throw "Existing-host mode does not change Key Vault or subscription permissions." }
    $Location = $existingVm.location
    if (-not $PSBoundParameters.ContainsKey("MonitoringContactEmails")) {
        $groups = @(Invoke-Az @("monitor", "action-group", "list", "-g", $ResourceGroupName, "--output", "json") -Json |
            Where-Object name -like "ag-openclaw-*")
        if ($groups.Count -gt 1) { throw "Ambiguous OpenClaw action group; provide reviewed monitoring contacts explicitly." }
        if ($groups.Count -eq 1) {
            $group = $groups[0]
            $otherReceivers = @($group.PSObject.Properties | Where-Object {
                $_.Name -like "*Receivers" -and $_.Name -ne "emailReceivers" -and @($_.Value).Count -gt 0
            })
            if ($otherReceivers.Count -or -not $group.enabled) {
                throw "Existing notification policy requires explicit review; it will not be replaced implicitly."
            }
            $MonitoringContactEmails = @($group.emailReceivers | ForEach-Object emailAddress)
        }
    }
    $templateName = "main-existing.bicep"
    $values = @{location=$Location; monitoringContactEmails=$MonitoringContactEmails}
}
else {
    if (-not $SshPublicKeyPath -or -not (Test-Path -LiteralPath $SshPublicKeyPath -PathType Leaf)) {
        throw "A new VM requires -SshPublicKeyPath."
    }
    $sshKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()
    if (-not $sshKey) { throw "SSH public key is empty." }
    if (-not $DeployerPrincipalId) {
        if ($account.user.type -eq "user") {
            $DeployerPrincipalId = [string](Invoke-Az @("ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"))
        }
        elseif ($account.user.type -eq "servicePrincipal") {
            $DeployerPrincipalType = "ServicePrincipal"
            $DeployerPrincipalId = [string](Invoke-Az @("ad", "sp", "show", "--id", $account.user.name, "--query", "id", "-o", "tsv"))
        }
        else { throw "Provide -DeployerPrincipalId for this account type." }
        if (-not $DeployerPrincipalId.Trim()) { throw "Could not resolve the deploying principal." }
    }
    & (Join-Path $PSScriptRoot "scripts\sync-cloud-init-assets.ps1") -Check
    if ($LASTEXITCODE -ne 0) { throw "Generated runtime assets are stale." }
    $templateName = "main.bicep"
    $values = @{
        location=$Location; sshPublicKey=$sshKey; ubuntuImageVersion=$UbuntuImageVersion
        deployerPrincipalId=$DeployerPrincipalId.Trim(); deployerPrincipalType=$DeployerPrincipalType
        monitoringContactEmails=$MonitoringContactEmails
    }
}
foreach ($email in $MonitoringContactEmails) {
    try { $parsed = [System.Net.Mail.MailAddress]::new($email) }
    catch { throw "Invalid monitoring contact email." }
    if ($parsed.Address -ne $email) { throw "Use plain monitoring email addresses without display names." }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("openclaw-deploy-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
if (-not $IsWindows) { & chmod 0700 $temp; if ($LASTEXITCODE -ne 0) { throw "Private staging failed." } }
try {
    $template = Join-Path $PSScriptRoot "infra\$templateName"
    Invoke-Az @("bicep", "build", "--file", $template, "--stdout") | Out-Null
    $parameters = Join-Path $temp "group.json"
    Write-Parameters $values $parameters
    if (-not $groupExists) {
        Invoke-Az @("group", "create", "-n", $ResourceGroupName, "-l", $Location, "-o", "none") | Out-Null
    }
    $groupArgs = @("--subscription", $SubscriptionId, "--resource-group", $ResourceGroupName,
        "--template-file", $template, "--parameters", "@$parameters")
    Invoke-Az (@("deployment", "group", "validate") + $groupArgs + @("-o", "none")) | Out-Null
    $preview = Get-GroupPreview $groupArgs
    if ($null -eq $preview.changes) { throw "What-if returned no usable change inventory." }
    $unsafe = @(Get-UnsafeWhatIfChanges $preview.changes ([bool]$existingVm))
    if ($unsafe.Count) { throw ($unsafe -join "; ") }
    $preview.changes | Select-Object changeType, resourceId | Format-Table -AutoSize
    Confirm-Deployment "resource-group"
    if ($existingVm) {
        $current = Invoke-Az @("vm", "show", "-g", $ResourceGroupName, "-n", "openclaw-vm", "-o", "json") -Json
        Assert-SnapshotMatchesDisk $VerifiedSnapshotId $current.storageProfile.osDisk.managedDisk.id
    }
    $result = Invoke-Az (@("deployment", "group", "create") + $groupArgs + @("-o", "json")) -Json
    if ($existingVm) {
        Write-Host "Monitoring updated. VM, networking, data stores and runtime were preserved."
    }
    else {
        $budgets = @(Invoke-Az @("consumption", "budget", "list", "--subscription", $SubscriptionId, "-o", "json") -Json)
        $budget = $budgets | Where-Object name -eq "openclaw-monthly-budget" | Select-Object -First 1
        $start = if ($budget) { $budget.timePeriod.startDate } else { (Get-Date -Day 1).ToUniversalTime().ToString("yyyy-MM-01T00:00:00Z") }
        $subParameters = Join-Path $temp "subscription.json"
        Write-Parameters @{vmPrincipalId=$result.properties.outputs.vmPrincipalId.value; budgetStartDate=$start;
            contactEmails=$MonitoringContactEmails} $subParameters
        $subArgs = @("--subscription", $SubscriptionId, "--location", $Location, "--template-file",
            (Join-Path $PSScriptRoot "infra\main-subscription.bicep"), "--parameters", "@$subParameters")
        Invoke-Az (@("deployment", "sub", "validate") + $subArgs + @("-o", "none")) | Out-Null
        Invoke-Az (@("deployment", "sub", "what-if") + $subArgs) | Out-Host
        Confirm-Deployment "subscription budget and RBAC"
        Invoke-Az (@("deployment", "sub", "create") + $subArgs + @("-o", "none")) | Out-Null
        Write-Host "New VM deployed. Complete onboarding without copying a template over live channel configuration."
    }
    Write-Host "Use scripts\apply-runtime.ps1 for snapshot- and backup-guarded existing-host runtime updates."
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
