#!/usr/bin/env bash
set -Eeuo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ "$(uname -s)" == MINGW* ]]; then
  command -v wsl.exe >/dev/null || {
    printf 'WSL is required to execute the pinned Linux collector on Windows.\n' >&2
    exit 77
  }
  wsl_path="/mnt${script_path}"
  MSYS2_ARG_CONV_EXCL='*' exec wsl.exe -e bash "$wsl_path"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/config/runtime-versions.json"
config="$root/config/otelcol-openclaw.yaml"
scratch="$root/.otel-redaction-test"
collector="${OTELCOL_BINARY:-}"
collector_pid=

cleanup() {
  if [[ -n "$collector_pid" ]] && kill -0 "$collector_pid" 2>/dev/null; then
    kill -TERM "$collector_pid" 2>/dev/null || true
    wait "$collector_pid" 2>/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

command -v curl >/dev/null
command -v python3 >/dev/null || command -v python >/dev/null
python_bin="$(command -v python3 || command -v python)"
json_value() {
  "$python_bin" -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["otelCollectorContrib"][sys.argv[2]])' \
    "$manifest" "$1"
}
rm -rf -- "$scratch"
mkdir -p "$scratch/bin" "$scratch/output"

if [[ -z "$collector" ]]; then
  case "$(uname -m)" in
    aarch64|arm64)
      url="$(json_value linuxArm64Url)"
      expected="$(json_value linuxArm64Sha256)"
      ;;
    x86_64|amd64)
      url="$(json_value linuxAmd64TestUrl)"
      expected="$(json_value linuxAmd64TestSha256)"
      ;;
    *)
      printf 'Unsupported test architecture: %s\n' "$(uname -m)" >&2
      exit 77
      ;;
  esac
  archive="$scratch/otelcol-contrib.tar.gz"
  curl --fail --silent --show-error --location "$url" --output "$archive"
  printf '%s  %s\n' "$expected" "$archive" | sha256sum --check -
  tar --extract --gzip --file "$archive" --directory "$scratch/bin"
  collector="$scratch/bin/otelcol-contrib"
  chmod 0755 "$collector"
fi
[[ -x "$collector" ]] || {
  printf 'Collector binary is not executable: %s\n' "$collector" >&2
  exit 66
}

export OPENCLAW_OTEL_CONTENT_SAMPLE_PERCENT=100
export OPENCLAW_OTEL_METADATA_OUTPUT_PATH="$scratch/output/metadata.jsonl"
export OPENCLAW_OTEL_CONTENT_OUTPUT_PATH="$scratch/output/content.jsonl"
"$collector" validate --config="$config"

"$collector" --config="$config" >"$scratch/collector.log" 2>&1 &
collector_pid=$!
for _ in {1..40}; do
  if curl --fail --silent --max-time 1 http://127.0.0.1:13133/ >/dev/null; then
    break
  fi
  kill -0 "$collector_pid"
  sleep 0.25
done
curl --fail --silent --max-time 1 http://127.0.0.1:13133/ >/dev/null

cat >"$scratch/payload.json" <<'JSON'
{
  "resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "openclaw-gateway"}}]},
    "scopeSpans": [{"scope": {"name": "openclaw.synthetic"}, "spans": [{
      "traceId": "0102030405060708090a0b0c0d0e0f10",
      "spanId": "0102030405060708",
      "name": "openclaw.model.call",
      "kind": 1,
      "startTimeUnixNano": "1000000000",
      "endTimeUnixNano": "2000000000",
      "attributes": [
        {"key": "openclaw.channel", "value": {"stringValue": "synthetic"}},
        {"key": "openclaw.content.input_messages", "value": {"stringValue": "prompt=SYNTHETIC-PROMPT-CANARY"}},
        {"key": "openclaw.content.output_messages", "value": {"stringValue": "ghp_0123456789ABCDEF"}},
        {"key": "openclaw.content.tool_definitions", "value": {"stringValue": "alice@example.invalid"}},
        {"key": "openclaw.content.tool_input", "value": {"stringValue": "203.0.113.77"}},
        {"key": "openclaw.content.tool_output", "value": {"stringValue": "command=rm -rf /synthetic-canary"}},
        {"key": "unreviewed.raw.field", "value": {"stringValue": "UNREVIEWED-CANARY"}}
      ]
    }]}]
  }]
}
JSON
curl --fail --silent --show-error \
  --header 'Content-Type: application/json' \
  --data-binary "@$scratch/payload.json" \
  http://127.0.0.1:4318/v1/traces >/dev/null
sleep 6
kill -TERM "$collector_pid"
wait "$collector_pid"
collector_pid=

[[ -s "$OPENCLAW_OTEL_METADATA_OUTPUT_PATH" && -s "$OPENCLAW_OTEL_CONTENT_OUTPUT_PATH" ]] || {
  cat "$scratch/collector.log" >&2
  printf 'Collector produced no sanitized output.\n' >&2
  exit 1
}
for raw in \
  SYNTHETIC-PROMPT-CANARY \
  alice@example.invalid \
  203.0.113.77 \
  ghp_0123456789ABCDEF \
  'rm -rf /synthetic-canary' \
  UNREVIEWED-CANARY; do
  if grep -F -- "$raw" "$scratch"/output/*.jsonl >/dev/null; then
    printf 'Raw synthetic canary escaped sanitization: %s\n' "$raw" >&2
    exit 1
  fi
done
grep -F '"openclaw.telemetry.sanitized"' "$scratch"/output/*.jsonl >/dev/null
for marker in \
  '[REDACTED_TOKEN]' \
  '[REDACTED_EMAIL]' \
  '[REDACTED_IP]' \
  'prompt=[REDACTED_CONTENT]' \
  'command=[REDACTED_CONTENT]'; do
  grep -F -- "$marker" "$OPENCLAW_OTEL_CONTENT_OUTPUT_PATH" >/dev/null || {
    printf 'Expected redaction marker was not emitted: %s\n' "$marker" >&2
    exit 1
  }
done
if grep -F -- 'unreviewed.raw.field' "$OPENCLAW_OTEL_CONTENT_OUTPUT_PATH" >/dev/null; then
  printf 'Unallowlisted telemetry key reached sanitized content output.\n' >&2
  exit 1
fi
printf 'Collector validation and synthetic redaction checks passed.\n'
