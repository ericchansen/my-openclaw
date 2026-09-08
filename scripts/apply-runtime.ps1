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
    [string]$VerifiedBackupArchive,
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    [string]$StorageContainerName = "openclaw-backups",
    [switch]$SkipGatewayRestart,
    [switch]$UseTailscaleSsh
)

$ErrorActionPreference = "Stop"
if ($SkipGatewayRestart) {
    throw "-SkipGatewayRestart is incompatible with the validated active-host updater."
}
$hostName = ($VmHost -replace '^.*@', '').Trim('[', ']')
$sshTarget = if ($VmHost.Contains("@")) { $VmHost } else { "$AdminUsername@$VmHost" }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required." }
if (-not $UseTailscaleSsh -and -not (Test-Path -LiteralPath $SshKeyPath)) {
    throw "SSH key not found: $SshKeyPath"
}
if (-not (Test-Path -LiteralPath $KnownHostsFile)) { throw "Known hosts file not found: $KnownHostsFile" }
& ssh-keygen -F $hostName -f $KnownHostsFile *> $null
if ($LASTEXITCODE -ne 0) {
    throw "No verified host key for '$hostName' in $KnownHostsFile. Verify it out of band and add it with ssh-keyscan."
}
$sshArgs = @(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=$KnownHostsFile"
)
if (-not $UseTailscaleSsh) {
    $sshArgs = @("-i", $SshKeyPath) + $sshArgs
}

function ConvertTo-PosixShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

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
& (Join-Path $PSScriptRoot "sync-cloud-init-assets.ps1") -Check
if ($LASTEXITCODE -ne 0) { throw "Runtime assets are stale." }
$bundle = [IO.File]::ReadAllText((Join-Path $root "infra\runtime-assets.tar.xz.b64")).Trim()
$bundleHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($bundle))
).ToLowerInvariant()

# Stream the reviewed bundle directly into sudo; never execute from a runtime-user path.
$stageProgram = @'
import base64, hashlib, io, os, re, shutil, stat, sys, tarfile, tempfile
from pathlib import Path

if os.geteuid() != 0:
    raise RuntimeError("Runtime staging requires root")
root = Path("/var/lib/openclaw-runtime")
for directory in [*reversed(root.parents), root]:
    if directory == root and not directory.exists():
        directory.mkdir(mode=0o755)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RuntimeError("Unsafe runtime staging parent")
encoded = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
if len(encoded) > 4 * 1024 * 1024:
    raise ValueError("Runtime bundle exceeds staging limit")
data = base64.b64decode(encoded.strip(), validate=True)
if hashlib.sha256(data).hexdigest() != sys.argv[1]:
    raise ValueError("Runtime bundle checksum mismatch")
assets = {}
with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as archive:
    for item in archive:
        if (not item.isfile() or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", item.name)
                or item.name in assets or item.size > 1024 * 1024):
            raise ValueError("Unsafe runtime asset")
        assets[item.name] = archive.extractfile(item).read()
if not {"install-openclaw-runtime.sh", "openclaw-update.sh",
        "openclaw-provision-sandbox-images.sh"} <= assets.keys():
    raise ValueError("Incomplete runtime bundle")
stage = Path(tempfile.mkdtemp(prefix="apply-", dir=root))
try:
    for name, content in assets.items():
        path = stage / name
        with path.open("xb") as output:
            output.write(content)
        path.chmod(0o400)
        info = path.lstat()
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o400 or path.read_bytes() != content:
            raise RuntimeError("Runtime staging verification failed")
    info = stage.lstat()
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError("Unsafe runtime staging directory")
except BaseException:
    shutil.rmtree(stage)
    raise
print(stage)
'@
$stageCommand = "sudo -n python3 -c $(ConvertTo-PosixShellLiteral $stageProgram) $bundleHash"
$stagingOutput = @($bundle | & ssh @sshArgs $sshTarget $stageCommand)
if ($LASTEXITCODE -ne 0 -or $stagingOutput.Count -ne 1 -or
    $stagingOutput[0] -notmatch '^/var/lib/openclaw-runtime/apply-[a-z0-9_]+$') {
    throw "Failed to establish verified root-owned runtime staging."
}
$remoteDir = $stagingOutput[0]

$manifestPath = Join-Path $root "config\runtime-versions.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing runtime manifest: $manifestPath"
}
$versions = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$installArgs = @(
    "sudo", "bash", "$remoteDir/install-openclaw-runtime.sh",
    "--asset-dir", $remoteDir,
    "--user", $AdminUsername,
    "--key-vault", $KeyVaultName,
    "--storage-account", $StorageAccountName,
    "--storage-container", $StorageContainerName,
    "--openclaw-version", $versions.openclaw.version,
    "--openclaw-integrity", $versions.openclaw.npmIntegrity,
    "--diagnostics-otel-version", $versions.packages.'@openclaw/diagnostics-otel'.version,
    "--diagnostics-otel-integrity", $versions.packages.'@openclaw/diagnostics-otel'.npmIntegrity,
    "--node-version", $versions.node.version,
    "--node-sha256", $versions.node.linuxArm64Sha256,
    "--otel-version", $versions.otelCollectorContrib.version,
    "--otel-url", $versions.otelCollectorContrib.linuxArm64Url,
    "--otel-sha256", $versions.otelCollectorContrib.linuxArm64Sha256,
    "--copilot-version", $versions.packages.'@github/copilot'.version,
    "--copilot-integrity", $versions.packages.'@github/copilot'.npmIntegrity,
    "--mcp-ebird-version", $versions.packages.'@pondlog/mcp-ebird'.version,
    "--mcp-ebird-integrity", $versions.packages.'@pondlog/mcp-ebird'.npmIntegrity,
    "--mcp-pondlog-version", $versions.packages.'@pondlog/mcp-pondlog'.version,
    "--mcp-pondlog-integrity", $versions.packages.'@pondlog/mcp-pondlog'.npmIntegrity,
    "--sandbox-source-commit", $versions.upstream.commit,
    "--sandbox-archive-url", $versions.upstream.archiveUrl,
    "--sandbox-archive-sha256", $versions.upstream.archiveSha256,
    "--sandbox-browser-contract", $versions.sandbox.browserContract,
    "--verified-backup", $VerifiedBackupArchive,
    "--snapshot-evidence", $VerifiedSnapshotId
)
$remoteCommand = ($installArgs | ForEach-Object { ConvertTo-PosixShellLiteral ([string]$_) }) -join " "
& ssh @sshArgs $sshTarget $remoteCommand
if ($LASTEXITCODE -ne 0) { throw "Runtime installer failed." }
Write-Host "Runtime assets applied successfully." -ForegroundColor Green
