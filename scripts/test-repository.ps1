param(
    [switch]$SkipOpenClawInstall,
    [switch]$SkipSystemdValidation
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content (Join-Path $root "config\runtime-versions.json") -Raw | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()
$files = @(& git -C $root ls-files --cached --others --exclude-standard) |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($LASTEXITCODE -ne 0) { throw "Could not enumerate repository files." }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "[ok] $Name"
    }
    catch {
        $failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "[failed] $Name"
    }
}

function Get-LinuxPath {
    param([string]$Path)
    if (-not $IsWindows) { return $Path }
    $result = (& wsl.exe --exec wslpath -a $Path).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not translate a repository path for WSL." }
    return $result
}

function Invoke-Linux {
    param([string]$Command, [string[]]$Arguments)
    if ($IsWindows) { & wsl.exe --exec $Command @Arguments }
    else { & $Command @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit $LASTEXITCODE." }
}

function Invoke-Cli {
    param([string[]]$Arguments, [int[]]$AllowedExits = @(0), [switch]$Text)
    $output = (& $script:node $script:cli @Arguments 2>&1) -join "`n"
    if ($LASTEXITCODE -notin $AllowedExits) { throw "OpenClaw $($Arguments[0]) failed: $output" }
    if ($Text) { return $output }
    return ($output | ConvertFrom-Json -Depth 100)
}

function Get-TemplateResources {
    param($Template)
    foreach ($resource in $Template.resources) {
        $resource
        if ($resource.type -eq "Microsoft.Resources/deployments" -and $resource.properties.template) {
            Get-TemplateResources $resource.properties.template
        }
    }
}

Invoke-Check "Python behavioral regressions" {
    Invoke-Linux python3 @("-m", "unittest", "discover", "-s",
        (Get-LinuxPath (Join-Path $root "tests")), "-p", "test_*.py")
}

Invoke-Check "Manifest and configuration invariants" {
    Assert-True ($manifest.schemaVersion -eq 1) "Unknown runtime manifest schema."
    Assert-True ($manifest.openclaw.version -match '^\d{4}\.\d+\.\d+$') "Runtime must be an exact release."
    Assert-True ($manifest.upstream.tag -eq "v$($manifest.openclaw.version)") "Tag/version mismatch."
    Assert-True ($manifest.upstream.commit -match '^[a-f0-9]{40}$') "Source commit is not pinned."
    Assert-True ($manifest.upstream.archiveSha256 -match '^[a-f0-9]{64}$') "Missing source checksum."
    Assert-True ($manifest.upstream.archiveUrl -eq
        "https://codeload.github.com/openclaw/openclaw/tar.gz/$($manifest.upstream.commit)") "Unbound source URL."
    Assert-True ($manifest.packages.'@openclaw/diagnostics-otel'.version -eq $manifest.openclaw.version) (
        "Diagnostics must match the reviewed runtime."
    )
    Get-ChildItem (Join-Path $root "config") -Filter "*.json" |
        ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 100 | Out-Null }
    foreach ($name in @("openclaw.template.json", "openclaw-quality.patch.json")) {
        $config = Get-Content (Join-Path $root "config\$name") -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $invariants = @{
            "update.channel" = "stable"
            "update.auto.enabled" = $false
            "browser.noSandbox" = $false
            "browser.allowSystemProfileImport" = $false
            "browser.ssrfPolicy.dangerouslyAllowPrivateNetwork" = $false
            "agents.defaults.sandbox.backend" = "docker"
            "agents.defaults.sandbox.scope" = "session"
            "agents.defaults.sandbox.docker.readOnlyRoot" = $true
            "agents.defaults.sandbox.docker.network" = "none"
            "agents.defaults.sandbox.browser.allowHostControl" = $false
            "agents.defaults.sandbox.browser.autoStart" = $false
            "tools.exec.host" = "auto"
            "tools.exec.strictInlineEval" = $true
            "tools.sessions.visibility" = "tree"
            "tools.toolSearch.enabled" = $false
            "diagnostics.otel.captureContent" = $false
        }
        foreach ($entry in $invariants.GetEnumerator()) {
            $actual = $config
            foreach ($part in $entry.Key.Split(".")) { $actual = $actual[$part] }
            Assert-True ($actual -ceq $entry.Value) "$name violates $($entry.Key)."
        }
        Assert-True ($null -eq $config.agents.defaults.sandbox.docker.ulimits.nproc) "UID-wide nproc limit returned."
        Assert-True ($null -eq $config.agents.list) "Retired agents.list returned."
        Assert-True ($null -eq $config.gateway.controlUi.toolTitles) "Retired toolTitles returned."
        Assert-True ($null -eq $config.messages.suppressToolErrors) "Retired suppressToolErrors returned."
        Assert-True (($config.commands.ownerAllowFrom -join ",") -eq
            "telegram:YOUR_TELEGRAM_USER_ID,discord:YOUR_DISCORD_USER_ID") "Explicit command owners are required."
        Assert-True ($null -eq $config.commands.allowFrom) "Do not bypass owner authorization with broad command grants."
    }
}

Invoke-Check "Registry integrity and install-policy decisions" {
    $pins = @{"openclaw" = $manifest.openclaw}
    foreach ($property in $manifest.packages.PSObject.Properties) { $pins[$property.Name] = $property.Value }
    foreach ($name in $pins.Keys) {
        $pin = $pins[$name]
        Assert-True ($pin.npmIntegrity -match '^sha512-[A-Za-z0-9+/]+={0,2}$') "Invalid integrity for $name."
        $actual = (& npm view "$name@$($pin.version)" dist.integrity --json) -join "`n"
        Assert-True ($LASTEXITCODE -eq 0 -and ($actual | ConvertFrom-Json) -ceq $pin.npmIntegrity) (
            "Registry integrity changed for $name."
        )
    }
    $python = (Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    Assert-True ([bool]$python) "Python is required."
    Get-ChildItem (Join-Path $root "tests\fixtures") -Filter "install-policy-*.json" | ForEach-Object {
        $result = (Get-Content $_.FullName -Raw | & $python (Join-Path $root "scripts\openclaw-install-policy.py")) |
            ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0) "Install policy fixture failed."
        $expected = if ($_.Name -like "*block-*") { "block" }
            elseif ($_.Name -like "*review-*" -or $_.Name -eq "install-policy-allow-pinned-npm.json") { "warn" }
            else { "allow" }
        Assert-True ($result.protocolVersion -eq 1 -and $result.decision -eq $expected) "Wrong decision for $($_.Name)."
    }
}

Invoke-Check "Repository syntax and executable line endings" {
    foreach ($file in $files | Where-Object { $_ -like "*.ps1" }) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "PowerShell syntax: $file"
    }
    $pythonFiles = @($files | Where-Object { $_ -like "*.py" } | ForEach-Object { Get-LinuxPath $_ })
    Invoke-Linux python3 (@("-c", "import pathlib,sys; [compile(pathlib.Path(p).read_bytes(),p,'exec') for p in sys.argv[1:]]") + $pythonFiles)
    $shellFiles = $files | Where-Object { $_ -like "*.sh" -or
        (Split-Path $_ -Leaf) -in @("openclaw-otel-ready", "openclaw-telemetry-access") }
    foreach ($file in $shellFiles) { Invoke-Linux bash @("-n", (Get-LinuxPath $file)) }
    $pythonExecutables = $files | Where-Object {
        $_ -like "*.py" -and (Split-Path $_ -Parent) -eq $PSScriptRoot
    }
    foreach ($file in @($shellFiles) + @($pythonExecutables)) {
        Assert-True (-not [IO.File]::ReadAllText($file).Contains("`r")) "Linux executable has CR line endings: $file"
    }
}

Invoke-Check "Runtime assets, units and telemetry boundaries" {
    & (Join-Path $PSScriptRoot "sync-cloud-init-assets.ps1") -Check
    if ($LASTEXITCODE -ne 0) { throw "Runtime assets are stale." }
    if ($SkipSystemdValidation) { Write-Warning "Systemd validation explicitly skipped." }
    else {
        Invoke-Linux bash @((Get-LinuxPath (Join-Path $PSScriptRoot "test-systemd-units.sh")),
            (Get-LinuxPath (Join-Path $root "config")))
    }
    $permissions = Get-LinuxPath (Join-Path $PSScriptRoot "test-telemetry-permissions.sh")
    if ($IsWindows) { & wsl.exe --user root --exec bash $permissions }
    elseif ((& id -u) -eq "0") { & bash $permissions }
    else { & sudo -n bash $permissions }
    if ($LASTEXITCODE -ne 0) { throw "Telemetry permission boundary failed." }
    Invoke-Linux bash @((Get-LinuxPath (Join-Path $PSScriptRoot "openclaw-telemetry-redaction-test.sh")))
}

Invoke-Check "Deployment topology and Bicep" {
    & (Join-Path $PSScriptRoot "test-deploy-network.ps1")
    if ($LASTEXITCODE -ne 0) { throw "Deployment guard regression." }
    foreach ($name in @("main", "main-existing")) {
        $output = @(& az bicep build --file (Join-Path $root "infra\$name.bicep") --stdout --only-show-errors 2>&1)
        Assert-True ($LASTEXITCODE -eq 0 -and ($output -join "`n") -notmatch '\bBCP\d+\b') "$name failed Bicep compilation."
        if ($name -eq "main-existing") {
            $template = ($output -join "`n") | ConvertFrom-Json -Depth 100
            $forbidden = @("Microsoft.Compute/virtualMachines", "Microsoft.Compute/disks",
                "Microsoft.Network/networkInterfaces", "Microsoft.Network/virtualNetworks",
                "Microsoft.Network/networkSecurityGroups", "Microsoft.Network/publicIPAddresses",
                "Microsoft.Network/natGateways", "Microsoft.Network/privateEndpoints",
                "Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts", "Microsoft.Authorization/roleAssignments")
            Assert-True (@(Get-TemplateResources $template | Where-Object type -in $forbidden).Count -eq 0) (
                "Existing-host deployment must not redeploy compute or network resources."
            )
        }
    }
}

Invoke-Check "Secret scan" {
    $patterns = @('gh[pousr]_[A-Za-z0-9]{20,}', 'sk-[A-Za-z0-9]{20,}',
        '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)(client_secret|bot_token|api_key)\s*[:=]\s*["''][^"'']{12,}')
    foreach ($file in $files) {
        $text = [IO.File]::ReadAllText($file)
        foreach ($pattern in $patterns) { Assert-True ($text -notmatch $pattern) "Possible secret in $file." }
    }
}

Invoke-Check "Exact official CLI, migration and recovery contracts" {
    if ($SkipOpenClawInstall) { Write-Warning "Exact OpenClaw validation explicitly skipped."; return }
    $scratch = Join-Path $root ".repository-test-runtime"
    $saved = @{}
    foreach ($name in @("HOME", "USERPROFILE", "OPENCLAW_HOME", "OPENCLAW_STATE_DIR",
        "OPENCLAW_CONFIG_PATH", "OPENCLAW_TEST_OTLP_ENDPOINT", "NPM_CONFIG_CACHE", "NPM_CONFIG_USERCONFIG")) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    try {
        if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
        New-Item -ItemType Directory -Path $scratch | Out-Null
        if (-not $IsWindows) { & chmod 700 $scratch; if ($LASTEXITCODE -ne 0) { throw "Private fixture mode failed." } }
        $env:HOME = $env:USERPROFILE = $env:OPENCLAW_HOME = $scratch
        $env:OPENCLAW_STATE_DIR = Join-Path $scratch "state"
        $env:NPM_CONFIG_CACHE = Join-Path $scratch "npm-cache"
        $env:NPM_CONFIG_USERCONFIG = Join-Path $scratch "npmrc"
        @{private = $true; dependencies = @{node = $manifest.node.version; openclaw = $manifest.openclaw.version}} |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $scratch "package.json")
        Push-Location $scratch
        try {
            & npm install --ignore-scripts --no-audit --no-fund --silent
            if ($LASTEXITCODE -ne 0) { throw "Isolated CLI dependency installation failed." }
            & npm rebuild node --silent
            if ($LASTEXITCODE -ne 0) { throw "Isolated Node installation failed." }
        }
        finally { Pop-Location }
        $script:node = Join-Path $scratch ("node_modules\node\bin\" + $(if ($IsWindows) { "node.exe" } else { "node" }))
        $script:cli = Join-Path $scratch "node_modules\openclaw\openclaw.mjs"
        Assert-True ((& $script:node --version) -ceq "v$($manifest.node.version)") "Wrong isolated Node."
        $version = Invoke-Cli -Arguments @("--version") -Text
        Assert-True ($version.Trim() -match "^OpenClaw $([regex]::Escape($manifest.openclaw.version))(?: \([A-Za-z0-9._+-]+\))?$") "Wrong CLI release."
        foreach ($name in @("list", "runs")) {
            $help = Invoke-Cli -Arguments @("automations", $name, "--help") -Text
            Assert-True ($help -match '--json' -and $help -notmatch '--scope|--offset') "Unsupported automation CLI contract."
            Assert-True ($(if ($name -eq "list") { $help -match '--all' -and $help -notmatch '--limit' }
                else { $help -match '--id\s+<[^>]+>' -and $help -match '--limit' })) "Missing automation flags."
        }
        $safeDir = if ($IsWindows) { "$env:WINDIR\System32" } else { Join-Path $scratch "safe-bin" }
        $safeCommand = if ($IsWindows) { Join-Path $safeDir "where.exe" } else { Join-Path $safeDir "false" }
        if (-not $IsWindows) {
            New-Item -ItemType Directory $safeDir | Out-Null
            Copy-Item /usr/bin/false $safeCommand
            & chmod 0700 $safeDir
            & chmod 0555 $safeCommand
            if ($LASTEXITCODE -ne 0) { throw "Safe fixture command permissions failed." }
        }
        foreach ($name in @("openclaw.template.json", "openclaw-quality.patch.json")) {
            $config = Get-Content (Join-Path $root "config\$name") -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            if ($config.secrets) {
                $config.secrets.providers.'azure-key-vault'.command = $safeCommand
                $config.secrets.providers.'azure-key-vault'.trustedDirs = @($safeDir)
                foreach ($server in $config.mcp.servers.Values) { $server.command = $safeCommand }
            }
            $config.security.installPolicy.exec.command = $safeCommand
            $config.security.installPolicy.exec.trustedDirs = @($safeDir)
            $config.agents.defaults.sandbox.docker.ulimits.Remove("nproc")
            $env:OPENCLAW_CONFIG_PATH = Join-Path $scratch $name
            $config | ConvertTo-Json -Depth 100 | Set-Content $env:OPENCLAW_CONFIG_PATH
            Assert-True (Invoke-Cli -Arguments @("config", "validate", "--json")).valid "Invalid $name."
        }
        # Exercise the real effective-config resolver, not a raw JSON read.
        $include = Join-Path $scratch "otel.include.json"
        @{enabled=$true; endpoint='${OPENCLAW_TEST_OTLP_ENDPOINT}'; protocol="http/protobuf"; captureContent=$false} |
            ConvertTo-Json | Set-Content $include
        $env:OPENCLAW_TEST_OTLP_ENDPOINT = "http://127.0.0.1:4318"
        $env:OPENCLAW_CONFIG_PATH = Join-Path $scratch "include-test.json"
        @{diagnostics=@{otel=@{'$include'=$include}}} | ConvertTo-Json -Depth 10 | Set-Content $env:OPENCLAW_CONFIG_PATH
        Assert-True ((Invoke-Cli -Arguments @("config", "get", "diagnostics.otel", "--json")).endpoint -eq
            $env:OPENCLAW_TEST_OTLP_ENDPOINT) "Effective include/environment resolution failed."
        $env:OPENCLAW_HOME = $env:HOME = $env:USERPROFILE = Join-Path $scratch "migration-home"
        $env:OPENCLAW_STATE_DIR = Join-Path $scratch "migration-state"
        New-Item -ItemType Directory $env:HOME, $env:OPENCLAW_STATE_DIR | Out-Null
        if (-not $IsWindows) { & chmod 700 $env:HOME $env:OPENCLAW_STATE_DIR }
        $env:OPENCLAW_CONFIG_PATH = Join-Path $scratch "migration.json"
        Copy-Item (Join-Path $root "tests\fixtures\openclaw-2026.7.1.json") $env:OPENCLAW_CONFIG_PATH
        Invoke-Cli -Arguments @("doctor", "--fix", "--non-interactive") -Text | Out-Null
        $compare = @'
const fs = require("node:fs"), assert = require("node:assert/strict");
const actual = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const expected = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
delete actual.meta; delete actual.skills; delete actual.wizard;
assert.equal(actual.agents.entries.main.workspace, process.argv[3]);
actual.agents.entries.main.workspace = "__STATE__/workspace";
assert.deepStrictEqual(actual, expected);
'@
        & $script:node -e $compare $env:OPENCLAW_CONFIG_PATH (Join-Path $root "tests\fixtures\openclaw-2026.9.1.json") (Join-Path $env:OPENCLAW_STATE_DIR "workspace")
        if ($LASTEXITCODE -ne 0) { throw "Doctor migration changed the canonical fixture." }
        Assert-True (Invoke-Cli -Arguments @("config", "validate", "--json")).valid "Migrated config is invalid."
        $agents = @(Invoke-Cli -Arguments @("agents", "list", "--json"))
        Assert-True ($agents.Count -eq 2) "Agent inventory changed."
        foreach ($agent in $agents) {
            Assert-True ([IO.Path]::IsPathRooted($agent.agentDir) -and [IO.Path]::IsPathRooted($agent.workspace) -and
                $agent.bindings -is [long] -and $agent.isDefault -is [bool]) "Invalid agent JSON contract."
        }
        $archive = Invoke-Cli -Arguments @("backup", "create", "--only-config", "--output", (Join-Path $scratch "backup"), "--verify", "--json")
        Assert-True ($archive.verified -and $archive.skippedVolatileCount -is [long]) "Native backup contract failed."
        $verified = Invoke-Cli -Arguments @("backup", "verify", $archive.archivePath, "--json")
        Assert-True ($verified.ok -and $verified.archivePath -eq $archive.archivePath -and
            $verified.assetCount -is [long] -and $verified.entryCount -is [long] -and $verified.symlinkCount -is [long]) "Native verify contract failed."
        $target = Join-Path $scratch "restored"
        $restored = Invoke-Cli -Arguments @("backup", "restore", $archive.archivePath, "--target", $target, "--json")
        Assert-True ($restored.ok -and $restored.targetPath -eq $target -and @($restored.warnings).Count -gt 0) "Native restore contract failed."
        if ($IsWindows) { Write-Warning "Native SQLite CLI is exercised in Linux CI; inherited Windows worktree ACLs are unsupported." }
        else {
            $snapshot = Invoke-Cli -Arguments @("backup", "sqlite", "create", "--global", "--repository", (Join-Path $scratch "sqlite"), "--json")
            Assert-True ($snapshot.ok -and $snapshot.manifest.database.role -eq "global" -and
                $snapshot.manifest.schemaVersion -eq 1 -and $snapshot.manifest.artifact.path -eq "database.sqlite") "SQLite create contract failed."
            $verified = Invoke-Cli -Arguments @("backup", "sqlite", "verify", $snapshot.snapshotPath, "--json")
            Assert-True ($verified.ok -and $verified.manifest.artifact.path -eq "database.sqlite") "SQLite verification failed."
        }
        $env:OPENCLAW_CONFIG_PATH = Join-Path $scratch "doctor.json"
        $env:OPENCLAW_STATE_DIR = Join-Path $scratch "doctor-state"
        '{"agents":{"entries":{"main":{}}},"update":{"channel":"stable","auto":{"enabled":false}}}' | Set-Content $env:OPENCLAW_CONFIG_PATH
        $doctor = Invoke-Cli -Arguments @("doctor", "--lint", "--json") -AllowedExits @(0, 1, 2)
        $doctorExit = $LASTEXITCODE
        Assert-True ($doctor.ok -is [bool] -and $doctor.findings -is [array]) "Invalid Doctor result."
        $errors = @($doctor.findings | Where-Object severity -eq "error")
        $unknown = @($doctor.findings | Where-Object severity -notin @("info", "warning", "error"))
        if ($IsWindows -and $errors.Count -eq 1 -and $unknown.Count -eq 0 -and
            $errors[0].message -like "*Temporary doctor lint state snapshot cleanup did not complete*") {
            Write-Warning "Known isolated Windows Doctor cleanup limitation."
        }
        else { Assert-True ($errors.Count -eq 0 -and $unknown.Count -eq 0 -and $doctorExit -in @(0, 1)) "Doctor reported an error." }
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process") }
        if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    }
}

if ($failures.Count) { throw "Repository validation failed:`n - $($failures -join "`n - ")" }
Write-Host "All repository checks passed."
exit 0
