param(
    [Parameter(Mandatory = $true)]
    [string]$VmHost,

    [string]$SshKeyPath = "$HOME\.ssh\id_ed25519",
    [string]$KnownHostsFile = "$HOME\.ssh\known_hosts",
    [string]$AdminUsername = "azureuser",
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [string]$VmName = "openclaw-vm",
    [Parameter(Mandatory = $true)]
    [string]$VerifiedSnapshotId,
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    [string]$StorageContainerName = "openclaw-backups",
    [switch]$SkipGatewayRestart
)

$ErrorActionPreference = "Stop"
$hostName = ($VmHost -replace '^.*@', '').Trim('[', ']')
$sshTarget = if ($VmHost.Contains("@")) { $VmHost } else { "$AdminUsername@$VmHost" }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required." }
if (-not (Test-Path -LiteralPath $SshKeyPath)) { throw "SSH key not found: $SshKeyPath" }
if (-not (Test-Path -LiteralPath $KnownHostsFile)) { throw "Known hosts file not found: $KnownHostsFile" }
& ssh-keygen -F $hostName -f $KnownHostsFile *> $null
if ($LASTEXITCODE -ne 0) {
    throw "No verified host key for '$hostName' in $KnownHostsFile. Verify it out of band and add it with ssh-keyscan."
}
$sshArgs = @("-i", $SshKeyPath, "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=$KnownHostsFile")

$vm = & az vm show `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --output json `
    --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $vm.storageProfile.osDisk.managedDisk.id) {
    throw "Could not resolve the current VM OS disk."
}
$snapshot = & az snapshot show `
    --ids $VerifiedSnapshotId `
    --output json `
    --only-show-errors | ConvertFrom-Json
if (
    $LASTEXITCODE -ne 0 -or
    $snapshot.provisioningState -ne "Succeeded" -or
    -not [string]::Equals(
        [string]$snapshot.creationData.sourceResourceId,
        [string]$vm.storageProfile.osDisk.managedDisk.id,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "The verified snapshot is not a succeeded snapshot of the current VM OS disk."
}
$imdsCommand = 'curl --fail --silent --show-error --header Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" | python3 -c ''import json,sys; print(json.load(sys.stdin)["resourceId"])'''
$remoteResourceId = & ssh @sshArgs $sshTarget $imdsCommand
if (
    $LASTEXITCODE -ne 0 -or
    -not [string]::Equals(
        [string]$remoteResourceId.Trim(),
        [string]$vm.id,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "The SSH target is not the Azure VM protected by the verified snapshot."
}

$root = Split-Path -Parent $PSScriptRoot
$assets = @(
    "$root\config\openclaw-gateway.service",
    "$root\config\openclaw-backup.service",
    "$root\config\openclaw-backup.timer",
    "$root\config\openclaw-health.service",
    "$root\config\openclaw-health.timer",
    "$PSScriptRoot\install-openclaw-runtime.sh",
    "$PSScriptRoot\openclaw-backup.sh",
    "$PSScriptRoot\openclaw-restore-verify.sh",
    "$PSScriptRoot\openclaw-health-check.sh",
    "$PSScriptRoot\openclaw-keyvault-resolver.py",
    "$PSScriptRoot\openclaw-gateway-launch.py",
    "$PSScriptRoot\openclaw-gog-launch.py"
)
foreach ($asset in $assets) {
    if (-not (Test-Path -LiteralPath $asset)) { throw "Missing asset: $asset" }
}

$remoteDir = ".cache/openclaw-runtime-apply"
& ssh @sshArgs $sshTarget "install -d -m 0700 '$remoteDir'"
if ($LASTEXITCODE -ne 0) { throw "Failed to create remote staging directory." }
& scp @sshArgs @assets "${sshTarget}:$remoteDir/"
if ($LASTEXITCODE -ne 0) { throw "Failed to upload runtime assets." }

$installArgs = @(
    "sudo", "bash", "$remoteDir/install-openclaw-runtime.sh",
    "--asset-dir", "/home/$AdminUsername/$remoteDir",
    "--user", $AdminUsername,
    "--key-vault", $KeyVaultName,
    "--storage-account", $StorageAccountName,
    "--storage-container", $StorageContainerName
)
if ($SkipGatewayRestart) {
    $installArgs += "--skip-gateway-restart"
}
$remoteCommand = ($installArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join " "
& ssh @sshArgs $sshTarget $remoteCommand
if ($LASTEXITCODE -ne 0) { throw "Runtime installer failed." }
Write-Host "Runtime assets applied successfully." -ForegroundColor Green
