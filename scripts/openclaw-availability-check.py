#!/usr/bin/env python3
"""Prove a private, non-delivering agent turn executed a fresh sandbox canary."""

import argparse
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import secrets
import signal
import sqlite3
import subprocess
import sys
import threading
import time

try:
    import fcntl
except ImportError:
    fcntl = None


SESSION_KEY = "agent:healthcheck:availability"
MAINTENANCE_LOCK = Path("/etc/openclaw/maintenance.lock")
PROCESS_TIMEOUT = 95
MAX_OUTPUT_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 128
STATUS_KEYS = {"ok", "timestamp", "reason", "durationMs"}


class ProbeFailure(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ProbeFailure("invalid_arguments")


def status(ok, reason, started):
    return {
        "ok": ok,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z"),
        "reason": reason,
        "durationMs": max(0, int((time.monotonic() - started) * 1000)),
    }


def read_cache(path, max_age):
    try:
        if path.stat().st_size > 1024:
            return None
        cached = json.loads(path.read_text(encoding="utf-8"))
        if (
            not isinstance(cached, dict)
            or set(cached) != STATUS_KEYS
            or cached["ok"] is not True
            or cached["reason"] != "none"
            or type(cached["durationMs"]) is not int
            or cached["durationMs"] < 0
            or not isinstance(cached["timestamp"], str)
        ):
            return None
        timestamp = dt.datetime.fromisoformat(cached["timestamp"].replace("Z", "+00:00"))
        if timestamp.utcoffset() != dt.timedelta(0):
            return None
        age = (dt.datetime.now(dt.timezone.utc) - timestamp).total_seconds()
        return cached if 0 <= age < max_age else None
    except (OSError, ValueError, TypeError, OverflowError):
        return None


def write_status(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    staging = path.with_name(f".{path.name}.{secrets.token_hex(12)}")
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(staging, path)
    finally:
        staging.unlink(missing_ok=True)


@contextlib.contextmanager
def lock(path, shared=False):
    if fcntl is None:
        raise ProbeFailure("unsupported_platform")
    flags = os.O_RDONLY if shared else os.O_RDWR | os.O_CREAT
    try:
        descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        raise ProbeFailure("maintenance_lock_unavailable" if shared else "lock_unavailable")
    try:
        try:
            fcntl.flock(
                descriptor, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | fcntl.LOCK_NB
            )
        except BlockingIOError:
            raise ProbeFailure("maintenance_active" if shared else "already_running")
        yield
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def database(path):
    if not path.is_file():
        raise ProbeFailure("missing_transcript")
    try:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
        connection.execute("PRAGMA query_only=ON")
        deadline = time.monotonic() + 2
        connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        try:
            yield connection
        finally:
            connection.close()
    except sqlite3.Error:
        raise ProbeFailure("invalid_transcript")


def watermark(path):
    if not path.exists():
        return {}
    with database(path) as connection:
        return dict(connection.execute(
            "SELECT session_id, MAX(seq) FROM transcript_events GROUP BY session_id"
        ))


def stop_process(process):
    # Popen creates this session/group; never signal a shared or discovered group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def capture(process):
    output = []
    read_failed = []

    def read():
        try:
            output.append(process.stdout.read(MAX_OUTPUT_BYTES + 1))
        except OSError:
            read_failed.append(True)

    reader = threading.Thread(target=read, daemon=True)
    deadline = time.monotonic() + PROCESS_TIMEOUT
    reader.start()
    try:
        reader.join(timeout=PROCESS_TIMEOUT)
        if reader.is_alive():
            raise ProbeFailure("timeout")
        if read_failed or not output:
            raise ProbeFailure("invalid_output")
        if len(output[0]) > MAX_OUTPUT_BYTES:
            raise ProbeFailure("output_limit")
        process.wait(timeout=max(0, deadline - time.monotonic()))
        return output[0]
    except subprocess.TimeoutExpired:
        stop_process(process)
        raise ProbeFailure("timeout")
    except BaseException:
        stop_process(process)
        raise
    finally:
        reader.join(timeout=5)
        if not reader.is_alive():
            process.stdout.close()


def invoke(state_dir, prompt):
    argv = [
        "openclaw", "agent", "--agent", "healthcheck",
        "--session-key", SESSION_KEY, "--thinking", "off",
        "--timeout", "90", "--message", prompt, "--json",
    ]
    environment = dict(os.environ, OPENCLAW_STATE_DIR=str(state_dir))
    process = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True, env=environment,
    )
    output = capture(process)
    if process.returncode != 0:
        raise ProbeFailure("command_exit")
    try:
        payload = json.loads(output)
    except (ValueError, UnicodeError):
        raise ProbeFailure("invalid_json")
    if not isinstance(payload, dict) or payload.get("status") != "ok":
        raise ProbeFailure("invalid_result")
    return payload


def result_session(payload, nonce):
    result = payload.get("result")
    if not isinstance(result, dict):
        raise ProbeFailure("invalid_result")
    payloads = result.get("payloads")
    if (
        not isinstance(payloads, list)
        or len(payloads) != 1
        or not isinstance(payloads[0], dict)
        or payloads[0].get("text") != nonce
    ):
        raise ProbeFailure("token_mismatch")
    meta = result.get("meta")
    agent_meta = meta.get("agentMeta") if isinstance(meta, dict) else None
    session = agent_meta.get("sessionId") if isinstance(agent_meta, dict) else None
    if not isinstance(session, str) or not session or len(session) > 256:
        raise ProbeFailure("invalid_result")
    return session


def fresh(value, started_ms, ended_ms):
    return type(value) in (int, float) and started_ms <= value <= ended_ms


def verify_receipt(path, session, sequence, command, nonce, started_ms, ended_ms):
    with database(path) as connection:
        rows = connection.execute(
            "SELECT event_json, created_at, seq FROM transcript_events "
            "WHERE session_id = ? AND seq > ? AND created_at >= ? "
            "ORDER BY seq LIMIT ?",
            (session, sequence, started_ms, MAX_EVENTS + 1),
        ).fetchall()
    if len(rows) > MAX_EVENTS:
        raise ProbeFailure("invalid_transcript")
    calls = {}
    receipt = False
    for raw, created_at, seq in rows:
        try:
            event = json.loads(raw)
        except (ValueError, TypeError):
            raise ProbeFailure("invalid_transcript")
        message = event.get("message") if isinstance(event, dict) else None
        if not isinstance(message, dict):
            continue
        if not fresh(created_at, started_ms, ended_ms) or not fresh(
            message.get("timestamp"), started_ms, ended_ms
        ):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        if message.get("role") == "assistant":
            for item in content:
                if not isinstance(item, dict) or item.get("type") != "toolCall":
                    continue
                if item.get("name") != "exec" or item.get("arguments") != {"command": command}:
                    raise ProbeFailure("unexpected_tool_call")
                call_id = item.get("id")
                if not isinstance(call_id, str) or not call_id or call_id in calls:
                    raise ProbeFailure("invalid_transcript")
                calls[call_id] = seq
        elif message.get("role") == "toolResult":
            call_id = message.get("toolCallId")
            details = message.get("details")
            if (
                isinstance(call_id, str)
                and call_id in calls
                and calls[call_id] < seq
                and message.get("toolName") == "exec"
                and message.get("isError") is False
                and isinstance(details, dict)
                and type(details.get("exitCode")) is int
                and details["exitCode"] == 0
                and details.get("status") == "completed"
                and content == [{"type": "text", "text": nonce}]
            ):
                receipt = True
    if not receipt:
        raise ProbeFailure("missing_exec_receipt")


def probe(state_dir):
    path = state_dir / "agents" / "healthcheck" / "agent" / "openclaw-agent.sqlite"
    previous = watermark(path)
    nonce = "openclaw-availability-" + secrets.token_hex(24)
    command = f"printf '%s' '{nonce}'"
    prompt = (
        "Availability check. Call exec exactly once, with only the command argument "
        f"set to: {command}\n"
        "Do not invoke other tools or commands, access files, or send messages. "
        "After the tool succeeds, reply with exactly its output, with no formatting."
    )
    started_ms = int(time.time() * 1000)
    payload = invoke(state_dir, prompt)
    ended_ms = int(time.time() * 1000)
    session = result_session(payload, nonce)
    verify_receipt(
        path, session, previous.get(session, -1), command, nonce, started_ms, ended_ms
    )


def check(args, started):
    state_dir = args.state_dir.expanduser().resolve()
    private_dir = state_dir / ".availability"
    private_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(private_dir, 0o700)
    cache_path = private_dir / "result.json"
    target = args.status_file or private_dir / "status.json"
    target = target.expanduser().absolute()
    if target.resolve() in {
        (private_dir / "check.lock").resolve(),
        (args.maintenance_lock or MAINTENANCE_LOCK).resolve(),
        (state_dir / "agents" / "healthcheck" / "agent" / "openclaw-agent.sqlite").resolve(),
    }:
        raise ProbeFailure("invalid_status_path")
    # Cache belongs to the actual state tree, never to a caller-selected output path.
    with lock(private_dir / "check.lock"):
        try:
            # The health wrapper normally owns the global maintenance lock.
            maintenance = (
                lock(args.maintenance_lock, shared=True)
                if args.maintenance_lock else contextlib.nullcontext()
            )
            with maintenance:
                cached = None if args.force else read_cache(cache_path, args.max_age_seconds)
                if cached is not None:
                    write_status(target, cached)
                    return cached
                probe(state_dir)
                result = status(True, "none", started)
        except ProbeFailure as error:
            result = status(False, str(error), started)
            if str(error) == "maintenance_active":
                return result
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            result = status(False, "probe_error", started)
        write_status(cache_path, result)
        write_status(target, result)
        return result


def main(argv=None):
    started = time.monotonic()
    parser = Parser(description=__doc__)
    parser.add_argument("--status-file", type=Path)
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".openclaw")
    parser.add_argument("--max-age-seconds", type=int, default=3600)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--maintenance-lock", type=Path)
    try:
        args = parser.parse_args(argv)
        if args.max_age_seconds < 0:
            raise ProbeFailure("invalid_arguments")
        result = check(args, started)
    except ProbeFailure as error:
        result = status(False, str(error), started)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        result = status(False, "status_error", started)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise ProbeFailure("interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
