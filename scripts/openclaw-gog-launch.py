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
GOG_PATH = "/usr/local/libexec/gog"
MAX_BYTES = 65_536
VAULT_PATTERN = re.compile(r"^[A-Za-z0-9-]{3,24}$")
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


def resolve_keyring_password(vault_name: str) -> str:
    request = json.dumps(
        {
            "protocolVersion": 1,
            "provider": "azure-key-vault",
            "ids": ["GOG-KEYRING-PASSWORD"],
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
    value = response.get("values", {}).get("GOG-KEYRING-PASSWORD")
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or response.get("errors")
    ):
        raise RuntimeError("credential resolution failed")
    return value


def main() -> int:
    try:
        if not os.path.isfile(GOG_PATH) or not os.access(GOG_PATH, os.X_OK):
            raise RuntimeError("gog executable rejected")
        vault_name = canonical_vault_name()
    except Exception:
        print("gog credential configuration failed.", file=sys.stderr)
        return EX_CONFIG
    try:
        password = resolve_keyring_password(vault_name)
    except Exception:
        print("gog credential provider is temporarily unavailable.", file=sys.stderr)
        return EX_TEMPFAIL
    environment = os.environ.copy()
    environment["GOG_KEYRING_PASSWORD"] = password
    os.execve(GOG_PATH, [GOG_PATH, *sys.argv[1:]], environment)
    return EX_CONFIG


if __name__ == "__main__":
    raise SystemExit(main())
