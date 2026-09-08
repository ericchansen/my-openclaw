param([switch]$Check)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sources = @(
    "config\openclaw-gateway.service",
    "config\openclaw-backup.service",
    "config\openclaw-backup.timer",
    "config\openclaw-health.service",
    "config\openclaw-health.timer",
    "config\openclaw-journald.conf",
    "config\openclaw-otel-collector.service",
    "config\otelcol-openclaw.yaml",
    "scripts\install-openclaw-runtime.sh",
    "scripts\openclaw-backup.sh",
    "scripts\openclaw-restore-verify.sh",
    "scripts\openclaw-health-check.sh",
    "scripts\openclaw-availability-check.py",
    "scripts\openclaw-keyvault-resolver.py",
    "scripts\openclaw-gateway-launch.py",
    "scripts\openclaw-gog-launch.py",
    "scripts\openclaw-mcp-launch.py",
    "scripts\openclaw-update.sh",
    "scripts\openclaw-install-policy.py",
    "scripts\openclaw-provision-sandbox-images.sh",
    "scripts\openclaw-otel-ready",
    "scripts\openclaw-telemetry-access"
) | ForEach-Object { Join-Path $root $_ }
$bundle = Join-Path $root "infra\runtime-assets.tar.xz.b64"
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction Stop }
$arguments = @((Join-Path $PSScriptRoot "build-runtime-bundle.py"), "--output", $bundle)
if ($Check) { $arguments += "--check" }
& $python.Source @arguments @sources
if ($LASTEXITCODE -ne 0) { throw "Runtime bundle generation/verification failed." }

$template = [System.IO.File]::ReadAllText((Join-Path $root "infra\cloud-init.yaml"))
$template = $template.Replace("__RUNTIME_BUNDLE_XZ_B64__", [IO.File]::ReadAllText($bundle))
$versions = Get-Content -LiteralPath (Join-Path $root "config\runtime-versions.json") -Raw |
    ConvertFrom-Json
$values = @{
    "__ADMIN_USERNAME__" = "azureuser"
    "__KEY_VAULT_NAME__" = ("k" * 24)
    "__STORAGE_ACCOUNT_NAME__" = ("s" * 24)
    "__STORAGE_CONTAINER_NAME__" = "openclaw-backups"
    "__OPENCLAW_VERSION__" = $versions.openclaw.version
    "__OPENCLAW_INTEGRITY__" = $versions.openclaw.npmIntegrity
    "__DIAGNOSTICS_OTEL_VERSION__" = $versions.packages.'@openclaw/diagnostics-otel'.version
    "__DIAGNOSTICS_OTEL_INTEGRITY__" = $versions.packages.'@openclaw/diagnostics-otel'.npmIntegrity
    "__NODE_VERSION__" = $versions.node.version
    "__NODE_SHA256__" = $versions.node.linuxArm64Sha256
    "__OTEL_VERSION__" = $versions.otelCollectorContrib.version
    "__OTEL_URL__" = $versions.otelCollectorContrib.linuxArm64Url
    "__OTEL_SHA256__" = $versions.otelCollectorContrib.linuxArm64Sha256
    "__COPILOT_VERSION__" = $versions.packages.'@github/copilot'.version
    "__COPILOT_INTEGRITY__" = $versions.packages.'@github/copilot'.npmIntegrity
    "__MCP_EBIRD_VERSION__" = $versions.packages.'@pondlog/mcp-ebird'.version
    "__MCP_EBIRD_INTEGRITY__" = $versions.packages.'@pondlog/mcp-ebird'.npmIntegrity
    "__MCP_PONDLOG_VERSION__" = $versions.packages.'@pondlog/mcp-pondlog'.version
    "__MCP_PONDLOG_INTEGRITY__" = $versions.packages.'@pondlog/mcp-pondlog'.npmIntegrity
    "__SANDBOX_SOURCE_COMMIT__" = $versions.upstream.commit
    "__SANDBOX_ARCHIVE_URL__" = $versions.upstream.archiveUrl
    "__SANDBOX_ARCHIVE_SHA256__" = $versions.upstream.archiveSha256
    "__SANDBOX_BROWSER_CONTRACT__" = $versions.sandbox.browserContract
}
foreach ($entry in $values.GetEnumerator()) {
    $template = $template.Replace($entry.Key, $entry.Value)
}
if ($template -match "__[A-Z0-9_]+__") {
    throw "Cloud-init rendering left an unresolved placeholder: $($Matches[0])"
}
$renderedSize = [Text.Encoding]::UTF8.GetByteCount($template)
$maximumComfortableSize = 62000
if ($renderedSize -gt $maximumComfortableSize) {
    throw "Rendered cloud-init is $renderedSize bytes; limit is $maximumComfortableSize."
}
Write-Host "Runtime bundle is current; rendered cloud-init is $renderedSize bytes."
