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

function Assert-SourceGatewayStopped {
    $statusText = ((& openclaw gateway status --json 2>$null) -join "`n").Trim()
    try {
        $status = $statusText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw (
            "Could not verify that the source Gateway is stopped. Run " +
            "'openclaw gateway status --json', resolve any status error, and rerun migration."
        )
    }

    if (
        $null -eq $status.service -or
        $status.service.loaded -isnot [bool] -or
        $null -eq $status.rpc -or
        $status.rpc.ok -isnot [bool]
    ) {
        throw (
            "Gateway status returned an unsupported result. Run " +
            "'openclaw gateway status --json' and verify the installed source CLI."
        )
    }
    $runtimeStatus = [string]$status.service.runtime.status
    $serviceStateUnknown = $status.service.loaded -and -not [string]::Equals(
        $runtimeStatus,
        "stopped",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $rpcReachable = $status.rpc.ok -eq $true
    if (
        $serviceStateUnknown -or
        $rpcReachable
    ) {
        throw (
            "The source Gateway is active or could not be proven stopped. " +
            "Stop it with 'openclaw gateway stop' " +
            "(or its service manager), confirm 'openclaw gateway status --json' reports " +
            "a non-running service and rpc.ok=false, then rerun. No migration backup was created."
        )
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
$remoteRestoreTarget = ".cache/openclaw-migration/restored-$PID-$([guid]::NewGuid())"
$restoreHelper = Join-Path $PSScriptRoot "scripts\migrate-restore.sh"
if (-not (Test-Path -LiteralPath $restoreHelper)) {
    throw "Migration restore helper not found: $restoreHelper"
}

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Write-Host "`n[1/5] Verifying the source Gateway is offline, then creating the backup..." `
        -ForegroundColor Cyan
    Assert-SourceGatewayStopped
    & openclaw backup create --output $stage --verify
    if ($LASTEXITCODE -ne 0) { throw "OpenClaw backup creation failed." }
    $archives = @(Get-ChildItem -LiteralPath $stage -File -Filter "*.tar.gz")
    if ($archives.Count -ne 1) {
        throw "Expected one backup archive, found $($archives.Count)."
    }
    & openclaw backup verify $archives[0].FullName
    if ($LASTEXITCODE -ne 0) { throw "Local OpenClaw backup verification failed." }
    Assert-SourceGatewayStopped

    Write-Host "[2/5] Creating private remote staging..." -ForegroundColor Cyan
    & ssh @sshArgs $VmHost "install -d -m 0700 '$remoteDir'"
    if ($LASTEXITCODE -ne 0) { throw "Remote staging creation failed." }

    Write-Host "[3/5] Uploading verified backup and restore helper..." -ForegroundColor Cyan
    & scp @sshArgs $archives[0].FullName $restoreHelper "${VmHost}:$remoteDir/"
    if ($LASTEXITCODE -ne 0) { throw "Backup upload failed." }

    $manifest = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot "config\runtime-versions.json"
    ) -Raw | ConvertFrom-Json
    $remoteVersionOutput = ((& ssh @sshArgs $VmHost "openclaw --version") -join "`n").Trim()
    $remoteVersionMatch = [regex]::Match(
        $remoteVersionOutput,
        '^OpenClaw ([0-9]{4}\.[0-9]+\.[0-9]+)(?: \([A-Za-z0-9._+-]+\))?$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (
        $LASTEXITCODE -ne 0 -or
        -not $remoteVersionMatch.Success -or
        -not [string]::Equals(
            $remoteVersionMatch.Groups[1].Value,
            [string]$manifest.openclaw.version,
            [System.StringComparison]::Ordinal
        )
    ) {
        throw "Remote OpenClaw must be exactly $($manifest.openclaw.version) before staged restore."
    }

    Write-Host "[4/5] Restoring into fresh remote staging..." -ForegroundColor Cyan
    $remoteArchive = "$remoteDir/$($archives[0].Name)"
    $remoteHelper = "$remoteDir/migrate-restore.sh"
    $remoteCommand = (
        "chmod 0700 '$remoteHelper' && " +
        "'$remoteHelper' '$remoteArchive' '$remoteRestoreTarget'"
    )
    & ssh @sshArgs $VmHost $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Remote restore failed." }

    Write-Host (
        "[5/5] Migration staged at ~/$remoteRestoreTarget. " +
        "Production state and Gateway were not changed; activate separately while offline."
    ) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
