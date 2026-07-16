param(
    [Parameter(Mandatory = $true)]
    [string]$VmHost,

    [string]$SshKeyPath = "$HOME\.ssh\id_ed25519",
    [string]$KnownHostsFile = "$HOME\.ssh\known_hosts"
)

$ErrorActionPreference = "Stop"

function Assert-SshHostKnown {
    param([string]$Target)

    $hostName = ($Target -replace '^.*@', '').Trim('[', ']')
    if (-not (Test-Path -LiteralPath $KnownHostsFile)) {
        throw "Known hosts file not found: $KnownHostsFile"
    }
    & ssh-keygen -F $hostName -f $KnownHostsFile *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "No verified host key for '$hostName' in $KnownHostsFile. Verify it out of band and add it before migration."
    }
}

foreach ($command in @("openclaw", "ssh", "scp", "ssh-keygen")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $command"
    }
}
if (-not (Test-Path -LiteralPath $SshKeyPath)) {
    throw "SSH key not found: $SshKeyPath"
}
Assert-SshHostKnown -Target $VmHost
$sshArgs = @(
    "-i", $SshKeyPath,
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=$KnownHostsFile"
)

& openclaw backup create --help *> $null
if ($LASTEXITCODE -ne 0) {
    throw "This local OpenClaw version does not support official backup creation."
}

$stageBase = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
}
else {
    [System.IO.Path]::GetTempPath()
}
$stageRoot = Join-Path $stageBase "OpenClaw\migration-staging"
$stage = Join-Path $stageRoot "$PID-$([guid]::NewGuid())"
$remoteDir = ".cache/openclaw-migration/incoming"
$restoreHelper = Join-Path $PSScriptRoot "scripts\migrate-restore.sh"
if (-not (Test-Path -LiteralPath $restoreHelper)) {
    throw "Migration restore helper not found: $restoreHelper"
}

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Write-Host "`n[1/5] Creating and verifying official OpenClaw backup..." -ForegroundColor Cyan
    & openclaw backup create --output $stage --verify
    if ($LASTEXITCODE -ne 0) { throw "OpenClaw backup creation failed." }
    $archives = @(Get-ChildItem -LiteralPath $stage -File -Filter "*.tar.gz")
    if ($archives.Count -ne 1) {
        throw "Expected one backup archive, found $($archives.Count)."
    }
    & openclaw backup verify $archives[0].FullName
    if ($LASTEXITCODE -ne 0) { throw "Local OpenClaw backup verification failed." }

    Write-Host "[2/5] Creating private remote staging..." -ForegroundColor Cyan
    & ssh @sshArgs $VmHost "install -d -m 0700 '$remoteDir'"
    if ($LASTEXITCODE -ne 0) { throw "Remote staging creation failed." }

    Write-Host "[3/5] Uploading verified backup and restore helper..." -ForegroundColor Cyan
    & scp @sshArgs $archives[0].FullName $restoreHelper "${VmHost}:$remoteDir/"
    if ($LASTEXITCODE -ne 0) { throw "Backup upload failed." }

    Write-Host "[4/5] Verifying remote archive and creating pre-restore backup..." -ForegroundColor Cyan
    $remoteArchive = "$remoteDir/$($archives[0].Name)"
    $remoteHelper = "$remoteDir/migrate-restore.sh"
    $remoteCommand = "chmod 0700 '$remoteHelper' && '$remoteHelper' '$remoteArchive'"
    & ssh @sshArgs $VmHost $remoteCommand
    if ($LASTEXITCODE -eq 78) {
        throw "Remote OpenClaw can verify backups but has no supported full-backup restore command. The verified archive remains at ~/$remoteArchive."
    }
    if ($LASTEXITCODE -ne 0) { throw "Remote restore failed." }

    Write-Host "[5/5] Migration completed and gateway restarted." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
