param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $PSScriptRoot "openclaw-health-check.sh"
$encodedPath = Join-Path $root "infra\openclaw-health-check.sh.gz.b64"

function Expand-Gzip {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Compressed
    )

    $input = [System.IO.MemoryStream]::new($Compressed, $false)
    $gzip = [System.IO.Compression.GZipStream]::new(
        $input,
        [System.IO.Compression.CompressionMode]::Decompress
    )
    $output = [System.IO.MemoryStream]::new()
    try {
        $gzip.CopyTo($output)
        return $output.ToArray()
    }
    finally {
        $output.Dispose()
        $gzip.Dispose()
        $input.Dispose()
    }
}

function Get-RenderedCloudInitSize {
    $templatePath = Join-Path $root "infra\cloud-init.yaml"
    $template = [System.IO.File]::ReadAllText($templatePath)
    $base64Assets = @{
        "__INSTALLER_B64__" = "scripts\install-openclaw-runtime.sh"
        "__GATEWAY_SERVICE_B64__" = "config\openclaw-gateway.service"
        "__BACKUP_SERVICE_B64__" = "config\openclaw-backup.service"
        "__BACKUP_TIMER_B64__" = "config\openclaw-backup.timer"
        "__HEALTH_SERVICE_B64__" = "config\openclaw-health.service"
        "__HEALTH_TIMER_B64__" = "config\openclaw-health.timer"
        "__JOURNALD_CONFIG_B64__" = "config\openclaw-journald.conf"
        "__BACKUP_SCRIPT_B64__" = "scripts\openclaw-backup.sh"
        "__RESTORE_VERIFY_SCRIPT_B64__" = "scripts\openclaw-restore-verify.sh"
        "__KEYVAULT_RESOLVER_B64__" = "scripts\openclaw-keyvault-resolver.py"
        "__GATEWAY_LAUNCH_B64__" = "scripts\openclaw-gateway-launch.py"
        "__GOG_LAUNCH_B64__" = "scripts\openclaw-gog-launch.py"
        "__MCP_LAUNCH_B64__" = "scripts\openclaw-mcp-launch.py"
    }
    foreach ($entry in $base64Assets.GetEnumerator()) {
        $assetBytes = [System.IO.File]::ReadAllBytes((Join-Path $root $entry.Value))
        $template = $template.Replace($entry.Key, [Convert]::ToBase64String($assetBytes))
    }
    $template = $template.Replace(
        "__HEALTH_SCRIPT_GZIP_B64__",
        [System.IO.File]::ReadAllText($encodedPath).Trim()
    )
    $values = @{
        "__ADMIN_USERNAME__" = "azureuser"
        "__KEY_VAULT_NAME__" = ("k" * 24)
        "__STORAGE_ACCOUNT_NAME__" = ("s" * 24)
        "__STORAGE_CONTAINER_NAME__" = "openclaw-backups"
        "__OPENCLAW_VERSION__" = "2026.7.1"
        "__NODE_VERSION__" = "22.23.1"
        "__NODE_SHA256__" = "0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1"
        "__COPILOT_VERSION__" = "1.0.71-3"
        "__MCP_EBIRD_VERSION__" = "0.1.5"
        "__MCP_PONDLOG_VERSION__" = "0.4.0"
    }
    foreach ($entry in $values.GetEnumerator()) {
        $template = $template.Replace($entry.Key, $entry.Value)
    }
    if ($template -match "__[A-Z0-9_]+__") {
        throw "Cloud-init rendering left an unresolved placeholder: $($Matches[0])"
    }
    return [System.Text.Encoding]::UTF8.GetByteCount($template)
}

$sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
if ($Check) {
    if (-not (Test-Path -LiteralPath $encodedPath)) {
        throw "Generated cloud-init health asset is missing. Run scripts\sync-cloud-init-assets.ps1."
    }
    try {
        $compressed = [Convert]::FromBase64String(
            [System.IO.File]::ReadAllText($encodedPath).Trim()
        )
        $expanded = Expand-Gzip -Compressed $compressed
    }
    catch {
        throw "Generated cloud-init health asset is invalid. Run scripts\sync-cloud-init-assets.ps1."
    }
    if (
        $sourceBytes.Length -ne $expanded.Length -or
        [Convert]::ToBase64String($sourceBytes) -ne [Convert]::ToBase64String($expanded)
    ) {
        throw "Generated cloud-init health asset is stale. Run scripts\sync-cloud-init-assets.ps1."
    }
    $renderedSize = Get-RenderedCloudInitSize
    if ($renderedSize -gt 65535) {
        throw "Rendered cloud-init is $renderedSize bytes; Azure allows at most 65535."
    }
    Write-Host (
        "Generated cloud-init health asset is current; rendered payload is " +
        "$renderedSize bytes."
    ) -ForegroundColor DarkGreen
    exit 0
}

$output = [System.IO.MemoryStream]::new()
$gzip = [System.IO.Compression.GZipStream]::new(
    $output,
    [System.IO.Compression.CompressionLevel]::SmallestSize,
    $true
)
try {
    $gzip.Write($sourceBytes)
}
finally {
    $gzip.Dispose()
}
$encoded = [Convert]::ToBase64String($output.ToArray())
$output.Dispose()
[System.IO.File]::WriteAllText(
    $encodedPath,
    $encoded,
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "Updated $encodedPath" -ForegroundColor Green
