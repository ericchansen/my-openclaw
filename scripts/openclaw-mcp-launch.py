#!/usr/bin/python3
import json
import os
import pathlib
import re
import stat
import subprocess
import sys


RUNTIME_ENV_PATH = pathlib.Path("/etc/openclaw/runtime.env")
RESOLVER_PATH = "/usr/local/bin/openclaw-keyvault-resolver"
MCP_PATHS = {
    "ebird": "/usr/local/lib/openclaw-mcp/bin/pondlog-mcp-ebird",
    "pondlog": "/usr/local/lib/openclaw-mcp/bin/pondlog-mcp-pondlog",
}
MAX_BYTES = 65_536
VAULT_PATTERN = re.compile(r"^[A-Za-z0-9-]{3,24}$")
EX_USAGE = 64
EX_CONFIG = 78
EX_TEMPFAIL = 75


def canonical_vault_name() -> str:
    metadata = RUNTIME_ENV_PATH.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & 0o022
        or metadata.st_size > 16_384
    ):
        raise RuntimeError("runtime configuration rejected")
    values = []
    for raw_line in RUNTIME_ENV_PATH.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "OPENCLAW_KEY_VAULT":
            values.append(value.strip())
    if len(values) != 1 or not VAULT_PATTERN.fullmatch(values[0]):
        raise RuntimeError("runtime configuration rejected")
    return values[0]


def resolve_ebird_key(vault_name: str) -> str:
    request = json.dumps(
        {
            "protocolVersion": 1,
            "provider": "azure-key-vault",
            "ids": ["EBIRD-API-KEY"],
        },
        separators=(",", ":"),
    ).encode("utf-8")
    result = subprocess.run(
        [RESOLVER_PATH, "--vault-name", vault_name],
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=12,
        env={
            "HOME": os.environ.get("HOME", ""),
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG": "C.UTF-8",
        },
    )
    if result.returncode != 0 or len(result.stdout) > MAX_BYTES:
        raise RuntimeError("credential resolution failed")
    response = json.loads(result.stdout.decode("utf-8"))
    value = response.get("values", {}).get("EBIRD-API-KEY")
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or response.get("errors")
    ):
        raise RuntimeError("credential resolution failed")
    return value


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in MCP_PATHS:
        print("Usage: openclaw-mcp-launch {ebird|pondlog}", file=sys.stderr)
        return EX_USAGE
    executable = MCP_PATHS[sys.argv[1]]
    try:
        if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
            raise RuntimeError("MCP executable rejected")
        vault_name = canonical_vault_name()
    except Exception:
        print("MCP credential configuration failed.", file=sys.stderr)
        return EX_CONFIG
    try:
        ebird_key = resolve_ebird_key(vault_name)
    except Exception:
        print("MCP credential provider is temporarily unavailable.", file=sys.stderr)
        return EX_TEMPFAIL
    environment = os.environ.copy()
    environment["EBIRD_API_KEY"] = ebird_key
    os.execve(executable, [executable], environment)
    return EX_CONFIG


if __name__ == "__main__":
    raise SystemExit(main())
