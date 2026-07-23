#!/usr/bin/python3
import concurrent.futures
import json
import pathlib
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROTOCOL_VERSION = 1
PROVIDER = "azure-key-vault"
MAX_INPUT_BYTES = 65_536
MAX_OUTPUT_BYTES = 65_536
MAX_IDS = 64
MAX_CONFIG_BYTES = 16_384
DEADLINE_SECONDS = 4.5
COMMAND_TIMEOUT_SECONDS = 2.0
RUNTIME_ENV_PATH = pathlib.Path("/etc/openclaw/runtime.env")
ALLOWLIST_PATH = pathlib.Path("/etc/openclaw/keyvault-allowlist")
REQUIRE_ROOT_OWNER = True
IMDS_TOKEN_URL = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
)
KEY_VAULT_API_VERSION = "7.4"
ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9-]{0,127}$")
VAULT_PATTERN = re.compile(r"^[A-Za-z0-9-]{3,24}$")
BASE_ALLOWLIST = frozenset(
    {
        "OPENCLAW-GATEWAY-TOKEN",
        "TELEGRAM-BOT-TOKEN",
        "DISCORD-BOT-TOKEN",
        "GITHUB-TOKEN",
        "GITHUB-COPILOT-TOKEN",
        "BRAVE-API-KEY",
        "EBIRD-API-KEY",
        "GOG-KEYRING-PASSWORD",
    }
)


class ResolverError(Exception):
    pass


def read_secure_text(path: pathlib.Path) -> str:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ResolverError("resolver configuration unavailable") from exc
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise ResolverError("resolver configuration is not a regular file")
    if REQUIRE_ROOT_OWNER and metadata.st_uid != 0:
        raise ResolverError("resolver configuration owner is invalid")
    if metadata.st_mode & 0o022:
        raise ResolverError("resolver configuration is writable by an untrusted principal")
    if metadata.st_size > MAX_CONFIG_BYTES:
        raise ResolverError("resolver configuration is too large")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ResolverError("resolver configuration is unreadable") from exc


def canonical_vault_name() -> str:
    values = []
    for raw_line in read_secure_text(RUNTIME_ENV_PATH).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "OPENCLAW_KEY_VAULT":
            values.append(value.strip())
    if len(values) != 1 or not VAULT_PATTERN.fullmatch(values[0]):
        raise ResolverError("canonical vault configuration is invalid")
    return values[0]


def configured_allowlist() -> frozenset[str]:
    allowlist = set(BASE_ALLOWLIST)
    if ALLOWLIST_PATH.exists():
        for raw_line in read_secure_text(ALLOWLIST_PATH).splitlines():
            identifier = raw_line.strip()
            if not identifier or identifier.startswith("#"):
                continue
            if not ID_PATTERN.fullmatch(identifier):
                raise ResolverError("configured allowlist contains an invalid id")
            allowlist.add(identifier)
    return frozenset(allowlist)


def error_response(message: str, ids: list[str] | None = None) -> dict:
    keys = list(dict.fromkeys(ids or []))
    errors = (
        {identifier: {"message": message} for identifier in keys}
        if keys
        else {"_request": {"message": message}}
    )
    return {"protocolVersion": PROTOCOL_VERSION, "values": {}, "errors": errors}


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


HTTP_OPENER = urllib.request.build_opener(NoRedirectHandler)


def fetch_json(url: str, headers: dict[str, str], timeout: float) -> dict | None:
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with HTTP_OPENER.open(request, timeout=max(0.1, timeout)) as response:
            payload = response.read(MAX_OUTPUT_BYTES + 1)
    except (OSError, TimeoutError, urllib.error.URLError):
        return None
    if len(payload) > MAX_OUTPUT_BYTES:
        return None
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    return decoded if isinstance(decoded, dict) else None


def managed_identity_token(deadline: float) -> str | None:
    remaining = min(COMMAND_TIMEOUT_SECONDS, deadline - time.monotonic())
    if remaining <= 0:
        return None
    response = fetch_json(IMDS_TOKEN_URL, {"Metadata": "true"}, remaining)
    token = response.get("access_token") if response else None
    return token if isinstance(token, str) and token else None


def fetch_secret(
    vault_name: str,
    identifier: str,
    token: str,
    deadline: float,
) -> tuple[str, str | None]:
    remaining = min(COMMAND_TIMEOUT_SECONDS, deadline - time.monotonic())
    if remaining <= 0:
        return identifier, None
    encoded_identifier = urllib.parse.quote(identifier, safe="")
    url = (
        f"https://{vault_name}.vault.azure.net/secrets/{encoded_identifier}"
        f"?api-version={KEY_VAULT_API_VERSION}"
    )
    response = fetch_json(url, {"Authorization": f"Bearer {token}"}, remaining)
    if response is None:
        return identifier, None
    value = response.get("value")
    return identifier, value if isinstance(value, str) and value else None


def resolve(payload: bytes, vault_argument: str | None) -> dict:
    if len(payload) > MAX_INPUT_BYTES:
        return error_response("request exceeds input limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return error_response("request is not valid JSON")
    if not isinstance(request, dict):
        return error_response("request must be an object")
    raw_ids = request.get("ids")
    candidate_ids = [value for value in raw_ids if isinstance(value, str)] if isinstance(raw_ids, list) else []
    if request.get("protocolVersion") != PROTOCOL_VERSION:
        return error_response("unsupported protocol version", candidate_ids)
    if request.get("provider") != PROVIDER:
        return error_response("provider mismatch", candidate_ids)
    if not isinstance(raw_ids, list) or not 1 <= len(raw_ids) <= MAX_IDS:
        return error_response("ids must be a non-empty bounded array", candidate_ids)
    if any(not isinstance(identifier, str) or not ID_PATTERN.fullmatch(identifier) for identifier in raw_ids):
        return error_response("ids contain an invalid identifier", candidate_ids)
    if len(set(raw_ids)) != len(raw_ids):
        return error_response("ids must be unique", raw_ids)

    try:
        vault_name = canonical_vault_name()
        allowlist = configured_allowlist()
    except ResolverError:
        return error_response("resolver configuration rejected", raw_ids)
    if vault_argument != vault_name:
        return error_response("vault argument rejected", raw_ids)
    if any(identifier not in allowlist for identifier in raw_ids):
        return error_response("id is not allowlisted", raw_ids)

    deadline = time.monotonic() + DEADLINE_SECONDS
    token = managed_identity_token(deadline)
    if token is None:
        return error_response("managed identity authentication failed", raw_ids)

    values: dict[str, str] = {}
    errors: dict[str, dict[str, str]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(raw_ids))) as executor:
        futures = [
            executor.submit(fetch_secret, vault_name, identifier, token, deadline)
            for identifier in raw_ids
        ]
        for future in futures:
            identifier, value = future.result()
            if value is None:
                errors[identifier] = {"message": "secret unavailable"}
            else:
                values[identifier] = value
    return {"protocolVersion": PROTOCOL_VERSION, "values": values, "errors": errors}


def encode_bounded(response: dict, ids: list[str] | None = None) -> bytes:
    encoded = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) <= MAX_OUTPUT_BYTES:
        return encoded
    fallback = error_response("resolved batch exceeds output limit", ids)
    encoded = json.dumps(fallback, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        encoded = b'{"protocolVersion":1,"values":{},"errors":{"_request":{"message":"output limit"}}}'
    return encoded


def request_ids(payload: bytes) -> list[str] | None:
    if len(payload) > MAX_INPUT_BYTES:
        return None
    try:
        parsed_request = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(parsed_request, dict):
        return None
    requested_ids = parsed_request.get("ids")
    if not isinstance(requested_ids, list):
        return None
    return [identifier for identifier in requested_ids if isinstance(identifier, str)]


def main() -> int:
    vault_argument = (
        sys.argv[2]
        if len(sys.argv) == 3 and sys.argv[1] == "--vault-name"
        else None
    )
    payload = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    try:
        response = resolve(payload, vault_argument)
    except Exception:
        response = error_response("resolver failure")
    sys.stdout.buffer.write(encode_bounded(response, request_ids(payload)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
