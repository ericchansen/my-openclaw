$ErrorActionPreference = "Stop"
$tokens = $null
$errors = $null
$path = Join-Path (Split-Path -Parent $PSScriptRoot) "deploy.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Deployment script syntax failed." }
foreach ($name in @("Get-UnsafeWhatIfChanges", "Invoke-Az", "Assert-SnapshotMatchesDisk", "Get-GroupPreview")) {
    $functions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $name function." }
    Invoke-Expression $functions[0].Extent.Text
}

function Assert-Equal($Actual, $Expected, $Message) {
    if ($Actual -ne $Expected) { throw "$Message Expected $Expected; got $Actual." }
}
function Change($Type, $Resource) {
    @{changeType=$Type; resourceId="/subscriptions/test/resourceGroups/test/providers/$Resource"}
}

foreach ($resource in @("Microsoft.Compute/virtualMachines/vm", "Microsoft.Compute/disks/os",
    "Microsoft.Network/networkInterfaces/nic", "Microsoft.Network/virtualNetworks/vnet/subnets/default",
    "Microsoft.Network/publicIPAddresses/ip", "Microsoft.Network/networkSecurityGroups/nsg",
    "Microsoft.KeyVault/vaults/vault", "Microsoft.Storage/storageAccounts/store")) {
    foreach ($kind in @("Create", "Modify", "Delete", "Deploy", "Unsupported")) {
        Assert-Equal @(Get-UnsafeWhatIfChanges @((Change $kind $resource)) $true).Count 1 "Existing-host resource mutation escaped."
    }
    Assert-Equal @(Get-UnsafeWhatIfChanges @((Change "NoChange" $resource)) $true).Count 0 "Read-only resource was rejected."
    Assert-Equal @(Get-UnsafeWhatIfChanges @((Change "Create" $resource)) $false).Count 0 "Fresh creation was rejected."
    Assert-Equal @(Get-UnsafeWhatIfChanges @((Change "Modify" $resource)) $false).Count 1 "Fresh deployment mutated an existing protected resource."
}
foreach ($resource in @("Microsoft.Insights/actionGroups/alerts", "Microsoft.Insights/metricAlerts/cpu",
    "Microsoft.OperationalInsights/workspaces/log/tables/Custom_CL",
    "Microsoft.Compute/virtualMachines/vm/extensions/AzureMonitorLinuxAgent",
    "Microsoft.Compute/virtualMachines/vm/providers/Microsoft.Insights/dataCollectionRuleAssociations/health",
    "Microsoft.Resources/deployments/monitoring")) {
    foreach ($kind in @("Create", "Modify")) {
        Assert-Equal @(Get-UnsafeWhatIfChanges @((Change $kind $resource)) $true).Count 0 "Monitoring update was rejected."
    }
    Assert-Equal @(Get-UnsafeWhatIfChanges @((Change "Delete" $resource)) $true).Count 1 "Destructive monitoring update escaped."
}
Assert-Equal @(Get-UnsafeWhatIfChanges @((Change "Create" "Microsoft.Compute/virtualMachines/vm/extensions/Other")) $true).Count 1 "Unrelated VM extension escaped."
Assert-Equal @(Get-UnsafeWhatIfChanges @(@{changeType="Modify";resourceId="invalid"}) $true).Count 1 "Malformed identity escaped."
$workspace = Change "Modify" "Microsoft.OperationalInsights/workspaces/log"
$workspace.before = @{properties=@{sku=@{name="PerGB2018"}}}
$workspace.after = @{properties=@{sku=@{name="PerGB2018"}}}
Assert-Equal @(Get-UnsafeWhatIfChanges @($workspace) $true).Count 0 "Unchanged pricing tier was rejected."
$workspace.after.properties.sku.name = "CapacityReservation"
Assert-Equal @(Get-UnsafeWhatIfChanges @($workspace) $true).Count 1 "A pricing-tier change escaped."

function az {
    Write-Output "SYNTHETIC-PRIVATE-PARAMETER"
    $global:LASTEXITCODE = 23
}
$message = try { Invoke-Az @("deployment", "group", "create", "--parameters", "SYNTHETIC-SECRET"); "" }
catch { $_.Exception.Message }
Assert-Equal ($message -match "SYNTHETIC") $false "CLI errors exposed private values."
Assert-Equal ($message -match "suppressed") $true "CLI failure was not surfaced."
Remove-Item Function:az
function az {
    if ($args -contains "--no-pretty-print") { '{"changes":[]}' }
    else { "Human-readable what-if output, even with -o json." }
    $global:LASTEXITCODE = 0
}
$preview = Get-GroupPreview @("--resource-group", "fixture")
Assert-Equal @($preview.changes).Count 0 "What-if must request machine-readable output."
Remove-Item Function:az

function Invoke-Az {
    param([string[]]$Arguments, [switch]$Json)
    @{provisioningState=$script:State; creationData=@{sourceResourceId=$script:Disk}}
}
$script:State = "Succeeded"
$script:Disk = "/disk/current"
Assert-SnapshotMatchesDisk "/snapshot/good" "/DISK/CURRENT"
foreach ($case in @(@("Failed", "/disk/current"), @("Succeeded", "/disk/other"))) {
    $script:State, $script:Disk = $case
    $rejected = $false
    try { Assert-SnapshotMatchesDisk "/snapshot/bad" "/disk/current" }
    catch { $rejected = $true }
    Assert-Equal $rejected $true "Invalid snapshot accepted."
}
Write-Host "Deployment snapshot, protected-resource and private-error tests passed."
$global:LASTEXITCODE = 0
