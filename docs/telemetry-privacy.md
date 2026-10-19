# Telemetry in this deployment

The configured exporter is `@openclaw/diagnostics-otel@2026.10.3`, installed
separately from the core package. Versions and checksums for it and
OpenTelemetry Collector Contrib are in [the manifest](../config/runtime-versions.json).
The template is metadata-only: `diagnostics.otel.captureContent: false`.

## Data path and retention

OpenClaw exports OTLP/HTTP protobuf to `127.0.0.1:4318`. The dedicated
`openclaw-otel` collector processes records before writing
`/var/log/openclaw-telemetry/metadata.jsonl` and `content.jsonl`.
Azure Monitor Agent reads those exact active paths into `OpenClawContent_CL`;
rotated files are not reingested. The table has seven-day interactive and total
retention, with no archive retention.

Metadata uses an attribute allowlist and replaces log bodies with a fixed marker.
If content is enabled, trace/log pipelines sample 10%, apply bounded attribute
allowlists and pattern redaction, and require a sanitizer marker. Raw log bodies
are not retained by the content-log branch.

Pattern redaction does not guarantee semantic PII removal. Content that does
not match a blocked pattern can remain. The table is sensitive, not an audit or
compliance record. Its Azure ingestion/query endpoints use public outbound
networking.

## Startup and content controls

The root-owned Gateway launcher checks the effective OpenClaw OTel configuration
before each start. It accepts only the configured loopback endpoints,
`http/protobuf`, and the OTLP log exporter. It removes inherited exporter routing
and Node/native preload variables and does not rewrite the persistent config.
Invalid configuration exits with status 78.

Content export additionally requires:

1. `captureContent: true`, through the optional
   [content patch](../config/openclaw-telemetry-content.patch.json);
2. the root-owned, non-group-writable `/etc/openclaw/telemetry-content.enabled`
   marker;
3. the collector-owned `/run/openclaw-otel/ready` marker and a live loopback listener.

Metadata-only startup does not require collector readiness. A collector failure
does not stop an already-running Gateway; the systemd relationship is
`Wants`/`After`, not `Requires`/`BindsTo`.

## File access

The collector directory is owned by `openclaw-otel:openclaw-otel`, mode `0750`.
Provisioning verifies the running Azure Monitor Agent `mdsd` executable/account
and grants only that account read/traverse ACLs. Default ACLs cover replacement
files. The collector's `UMask=0027` makes exporter-created files `0640`.
The runtime directory is `0755` with a collector-owned `0444` readiness marker.

To inspect this contract without reading telemetry contents:

```bash
sudo /usr/local/sbin/openclaw-telemetry-access
namei -l /var/log/openclaw-telemetry/metadata.jsonl
getfacl -cp /var/log/openclaw-telemetry
```

## Enable or disable content export

After reviewing the additional data exposure, from the VM checkout:

```bash
openclaw config patch --file config/openclaw-telemetry-content.patch.json --dry-run
openclaw config patch --file config/openclaw-telemetry-content.patch.json
sudo install -o root -g root -m 0600 /dev/null /etc/openclaw/telemetry-content.enabled
sudo systemctl restart openclaw-otel-collector.service openclaw-gateway.service
```

To disable it, persist `captureContent: false` before removing the marker:

```bash
openclaw config set diagnostics.otel.captureContent false
sudo rm -f /etc/openclaw/telemetry-content.enabled
sudo systemctl restart openclaw-gateway.service
```

This stops future content capture; it does not delete previously retained data.

## Verify

```bash
scripts/openclaw-telemetry-redaction-test.sh
sudo /usr/local/libexec/otelcol-openclaw validate \
  --config=/etc/openclaw/otelcol-openclaw.yaml
```

In Azure Monitor:

```kusto
OpenClawContent_CL
| where TimeGenerated > ago(1h)
| summarize Records=count(), Oldest=min(TimeGenerated), Newest=max(TimeGenerated) by TelemetryClass
```

Review table-scoped access and retention through
[Azure Monitor's reference](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure).
Exceptional deletion uses the Log Analytics purge process and separately removes
the relevant local files. Disabling capture does not purge either destination.
