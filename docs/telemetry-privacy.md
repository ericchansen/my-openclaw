# Telemetry privacy

OpenClaw exports OTLP/HTTP protobuf only to `127.0.0.1:4318`. The pinned
OpenTelemetry Collector Contrib `0.160.0` runs as the dedicated
`openclaw-otel` user and writes only post-processor JSONL under
`/var/log/openclaw-telemetry`. No receiver is publicly reachable and no debug
exporter is enabled. Its ARM64 SHA-256 is copied from the matching
[official release sidecar](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.160.0/otelcol-contrib_0.160.0_linux_arm64.tar.gz.sha256)
and is checked before extraction.

The exporter is provided by the separately installed, reviewed
`@openclaw/diagnostics-otel@2026.9.2` npm plugin, not by an assumed bundled
copy. Its SHA-512 is pinned in `config/runtime-versions.json`, verified against
the registry before install, and revalidated with runtime plugin metadata
before the Gateway starts. See [OpenClaw plugin documentation](https://docs.openclaw.ai/tools/plugin).

Official references:

- [OpenClaw OpenTelemetry export](https://docs.openclaw.ai/gateway/opentelemetry)
- [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Azure Monitor custom text logs](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-log-text)
- [Log Analytics table retention](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)

## Data paths

- Metadata pipelines retain bounded, allowlisted operational attributes in
  `metadata.jsonl`. Log bodies are replaced with a fixed marker.
- Content trace/log pipelines sample 10% locally. They run memory limiting,
  allowlist-first transforms, credential/token/email/IP and labeled
  prompt/command pattern replacement, length limits, a required sanitized
  marker, and batching before file output.
- Raw log bodies are never retained; the content log branch writes only a fixed
  dropped marker.
- Records without the sanitizer marker are dropped. Transform, filter, or
  exporter errors cannot bypass the pipeline into another exporter.
- AMA reads only the two exact active collector-owned paths,
  `/var/log/openclaw-telemetry/metadata.jsonl` and
  `/var/log/openclaw-telemetry/content.jsonl`, and sends them to
  `OpenClawContent_CL`. The DCR derives `TelemetryClass` only from the trusted
  exact metadata/content file path, rejects any other path, and never matches
  rotated JSONL files, so metadata remains separately queryable without
  reingesting rotations.
  The table has seven-day interactive and total retention, so archive retention
  is zero. Existing bounded syslog health alerts remain the primary paging path.

Pattern redaction cannot prove semantic PII removal. Sampled text that does not
match a blocked pattern can remain. Treat the custom table as sensitive,
restrict table-scope access, and do not use it as an audit or compliance record.
Azure Monitor ingestion and query endpoints remain public outbound residuals.

## Fail-closed content gate

The committed template is metadata-only (`captureContent: false`). Content
requires all three:

1. an operator-reviewed application of
   `config/openclaw-telemetry-content.patch.json`;
2. a root-owned, non-group-writable
   `/etc/openclaw/telemetry-content.enabled` marker; and
3. the collector's owned `/run/openclaw-otel/ready` marker plus a live
   loopback listener.

The Gateway launcher never rewrites or replaces the canonical persistent config,
so Control UI and CLI config changes remain authoritative. Before every Gateway
exec it runs the pinned OpenClaw `config get diagnostics.otel --json` command
with a 15-second/output bound. This resolves `$include`, environment
interpolation, schema validation, runtime defaults, and canonical precedence.
When OTel is enabled, startup accepts only the exact shared loopback endpoint,
the three matching loopback `/v1/{signal}` endpoints, `http/protobuf`, and the
OTLP log exporter. Inherited OTLP endpoint/protocol/exporter variables and
Node/native preload variables are removed from both the read-only query and
Gateway environment. Requested content capture also requires both markers and
the live listener. Any unsafe or unresolved state exits with configuration
status 78; no ephemeral config is created. The Gateway has a systemd `Wants`/`After`
dependency on the collector, not `Requires` or `BindsTo`: a collector failure or
restart must not stop an already-running chat Gateway. Metadata-only startup
does not require the collector readiness marker. Content-enabled startup still
fails closed without it; no unverified environment override is used to disable
content capture. If the collector later fails, the canonical
endpoint remains loopback-only and unavailable, so export cannot redirect raw
data; the collector restart policy recreates readiness.
The collector runtime directory is mode `0755` and the empty marker is collector-owned
mode `0444`, allowing the unprivileged Gateway to traverse/read it without
granting write access to either the directory or marker.

## Azure Monitor Agent file access

Provisioning installs POSIX ACL support, waits at most 180 seconds for exactly
one `/opt/microsoft/azuremonitoragent/bin/mdsd` process, verifies its executable
path, and resolves its actual OS account. AMA releases can use different
accounts; this deployment currently runs `mdsd` as `syslog`. The collector
fails before enabling if the process identity or ACL contract is unavailable.
The telemetry directory remains owned by `openclaw-otel:openclaw-otel` at mode
`0750`. Only the verified `mdsd` account receives an additional read/traverse
ACL.
Matching default ACLs cover collector-created replacement files, while the
active files are pre-created and checked explicitly. No telemetry file or
directory receives world access.
The pinned exporter creates active and rotated replacements with mode `0644`;
the collector's `UMask=0027` reduces that to `0640`, preserving the inherited
named-user read ACL ([pinned exporter source](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.160.0/exporter/fileexporter/factory.go)).

The collector unit reasserts and verifies this contract before every start.
Check a host without printing data:

```bash
sudo /usr/local/sbin/openclaw-telemetry-access
ama_pid="$(pgrep -x mdsd)"
ama_uid="$(stat -c '%u' "/proc/$ama_pid")"
ama_reader="$(getent passwd "$ama_uid" | awk -F: 'NR == 1 { print $1 }')"
sudo -u "$ama_reader" test -r /var/log/openclaw-telemetry/metadata.jsonl
sudo -u "$ama_reader" test -r /var/log/openclaw-telemetry/content.jsonl
namei -l /var/log/openclaw-telemetry/metadata.jsonl
getfacl -cp /var/log/openclaw-telemetry
```

Enable only in an approved window:

```bash
openclaw config patch --file ./config/openclaw-telemetry-content.patch.json --dry-run
# Apply through the reviewed OpenClaw config workflow.
sudo install -o root -g root -m 0600 /dev/null /etc/openclaw/telemetry-content.enabled
sudo systemctl restart openclaw-otel-collector.service openclaw-gateway.service
```

Immediate kill switch (first persist metadata-only config through the reviewed
config workflow, then remove approval):

```bash
openclaw config patch --file <reviewed-metadata-only-patch>
sudo rm -f /etc/openclaw/telemetry-content.enabled
sudo systemctl restart openclaw-gateway.service
```

Restarting with `captureContent: true` after removing either marker intentionally
fails with status 78. Disabling it canonically returns telemetry to metadata-only
without deleting existing retained data.

## Validation and access

Before enabling content:

```bash
scripts/openclaw-telemetry-redaction-test.sh
sudo /usr/local/libexec/otelcol-openclaw validate \
  --config=/etc/openclaw/otelcol-openclaw.yaml
ss -lnt | grep -E '127\.0\.0\.1:(4318|13133)'
```

The test sends token, email, IP, prompt, command, and non-allowlisted canaries in
independent attributes. It requires each specific redaction marker and fails if
any raw canary or the non-allowlisted key reaches the file.

Verify table retention and role assignments:

```bash
table_id="$(az monitor log-analytics workspace table show \
  --resource-group rg-openclaw --workspace-name '<workspace>' \
  --name OpenClawContent_CL --query id --output tsv)"
az monitor log-analytics workspace table show \
  --resource-group rg-openclaw --workspace-name '<workspace>' \
  --name OpenClawContent_CL \
  --query '{interactive:retentionInDays,total:totalRetentionInDays,plan:plan}'
az role assignment list --scope "$table_id" --output table
```

Grant the smallest custom role at `table_id`; do not grant broad workspace
query access merely to read content. Confirm an approved principal can run the
following and an unapproved principal cannot:

```kusto
OpenClawContent_CL
| where TimeGenerated > ago(1h)
| summarize Records=count(), Oldest=min(TimeGenerated), Newest=max(TimeGenerated) by TelemetryClass
```

Check expiration:

```kusto
OpenClawContent_CL
| summarize Oldest=min(TimeGenerated), Newest=max(TimeGenerated), Records=count()
| extend OldestAge=now()-Oldest
```

For urgent deletion, disable content first, delete local matching files, then
use the Log Analytics purge API with a narrow time/filter predicate and the
Data Purger permission. Purge is asynchronous and exceptional; seven-day table
retention remains the normal deletion control. Record the purge request ID, not
matching content.
