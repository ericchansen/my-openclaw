"""Executable, offline canary tests; every database and status lives in the repo."""

import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "openclaw-availability-check.py"
SESSION = "test-canary-session"


def transcript_path(state):
    return state / "agents" / "healthcheck" / "agent" / "openclaw-agent.sqlite"


def create_database(state):
    path = transcript_path(state)
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as connection:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS transcript_events "
            "(event_json TEXT, created_at INTEGER, session_id TEXT, seq INTEGER)"
        )
    return path


def events(command, nonce, timestamp):
    return [
        {"message": {
            "role": "assistant", "timestamp": timestamp,
            "content": [{
                "type": "toolCall", "id": "test-call",
                "name": "exec", "arguments": {"command": command},
            }],
        }},
        {"message": {
            "role": "toolResult", "timestamp": timestamp,
            "toolCallId": "test-call", "toolName": "exec", "isError": False,
            "details": {"exitCode": 0, "status": "completed"},
            "content": [{"type": "text", "text": nonce}],
        }},
    ]


def insert_events(state, records, *, session=SESSION, created_at=None, first_seq=None):
    path = create_database(state)
    with contextlib.closing(sqlite3.connect(path)) as connection:
        if first_seq is None:
            first_seq = connection.execute(
                "SELECT COALESCE(MAX(seq), -1) + 1 FROM transcript_events "
                "WHERE session_id = ?", (session,),
            ).fetchone()[0]
        for offset, event in enumerate(records):
            timestamp = created_at
            if timestamp is None:
                timestamp = event["message"]["timestamp"]
            connection.execute(
                "INSERT INTO transcript_events VALUES (?, ?, ?, ?)",
                (json.dumps(event), timestamp, session, first_seq + offset),
            )
        connection.commit()


def payload(nonce):
    return {
        "status": "ok",
        "result": {
            "payloads": [{"text": nonce}],
            "meta": {"agentMeta": {"sessionId": SESSION}},
        },
    }


def fake_cli():
    prompt = sys.argv[sys.argv.index("--message") + 1]
    nonce = re.search(r"openclaw-availability-[0-9a-f]{48}", prompt).group()
    command = f"printf '%s' '{nonce}'"
    state = Path(os.environ["OPENCLAW_STATE_DIR"])
    insert_events(state, events(command, nonce, int(time.time() * 1000)))
    print(json.dumps(payload(nonce)))
    print("PRIVATE CLI ERROR MUST NOT LEAK", file=sys.stderr)


class AvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = ROOT / (".availability-test-" + uuid.uuid4().hex)
        self.scratch.mkdir()
        self.state = self.scratch / "state"
        self.target = self.scratch / "health" / "availability.json"
        self.maintenance = self.scratch / "maintenance.lock"
        self.maintenance.touch()
        spec = importlib.util.spec_from_file_location("availability_check", SCRIPT)
        self.canary = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.canary)
        self.patches = []
        if os.name == "nt":
            self.patches.extend([
                mock.patch.object(self.canary, "fcntl", mock.Mock(
                    LOCK_SH=1, LOCK_EX=2, LOCK_NB=4,
                )),
                mock.patch.object(os, "O_NOFOLLOW", 0, create=True),
                mock.patch.object(os, "O_CLOEXEC", 0, create=True),
                mock.patch.object(signal, "SIGKILL", 9, create=True),
            ])
        for patch in self.patches:
            patch.start()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for patch in reversed(self.patches):
            patch.stop()
        shutil.rmtree(self.scratch)

    @property
    def cache(self):
        return self.state / ".availability" / "result.json"

    def arguments(self, *extra):
        return [
            "--state-dir", str(self.state), "--status-file", str(self.target),
            "--maintenance-lock", str(self.maintenance), *extra,
        ]

    def run_main(self, *extra):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = self.canary.main(self.arguments(*extra))
        self.assertEqual(errors.getvalue(), "")
        result = json.loads(output.getvalue())
        self.assertEqual(set(result), {"ok", "timestamp", "reason", "durationMs"})
        self.assertIs(type(result["ok"]), bool)
        self.assertEqual(code, 0 if result["ok"] else 1)
        self.assertNotIn("test-canary-session", output.getvalue())
        self.assertNotIn("PRIVATE", output.getvalue())
        self.assertNotIn("openclaw-availability-", output.getvalue())
        return result

    def cli(self, argv, **kwargs):
        prompt = argv[argv.index("--message") + 1]
        self.nonce = re.search(r"openclaw-availability-[0-9a-f]{48}", prompt).group()
        self.command = f"printf '%s' '{self.nonce}'"
        self.records = events(self.command, self.nonce, int(time.time() * 1000))
        self.response = payload(self.nonce)
        self.record_session = SESSION
        self.created_at = None
        self.exit_code = 0
        if self.change is not None:
            self.change()
        if self.records is not None:
            insert_events(
                Path(kwargs["env"]["OPENCLAW_STATE_DIR"]),
                self.records, session=self.record_session, created_at=self.created_at,
            )
        process = mock.Mock(pid=987654, returncode=self.exit_code)
        data = self.response if isinstance(self.response, bytes) else json.dumps(
            self.response
        ).encode()
        process.stdout = io.BytesIO(data)
        return process

    def run_probe(self, change=None, *extra):
        self.change = change
        with mock.patch.object(self.canary.subprocess, "Popen", side_effect=self.cli) as popen:
            result = self.run_main(*extra)
        return result, popen

    def test_healthy_requires_cli_and_real_sqlite_receipt(self):
        result, popen = self.run_probe()
        self.assertTrue(result["ok"])
        self.assertEqual(result["reason"], "none")
        argv = popen.call_args.args[0]
        self.assertEqual(argv[:8], [
            "openclaw", "agent", "--agent", "healthcheck",
            "--session-key", "agent:healthcheck:availability", "--thinking", "off",
        ])
        self.assertEqual(argv[8:10], ["--timeout", "90"])
        self.assertNotIn("--deliver", argv)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(popen.call_args.kwargs["stderr"], subprocess.DEVNULL)
        self.assertEqual(json.loads(self.target.read_text()), result)
        self.assertEqual(json.loads(self.cache.read_text()), result)
        if os.name != "nt":
            self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.cache.parent.stat().st_mode & 0o777, 0o700)

    def test_actual_subprocess_and_database_end_to_end(self):
        real_popen = subprocess.Popen

        def substitute(argv, **kwargs):
            return real_popen(
                [sys.executable, str(Path(__file__).resolve()), "--fake-cli", *argv[1:]],
                **kwargs,
            )

        with mock.patch.object(self.canary.subprocess, "Popen", side_effect=substitute):
            result = self.run_main()
        self.assertTrue(result["ok"])
        self.assertEqual(json.loads(self.target.read_text()), result)

    def test_hallucinated_token_without_tool_receipt_fails(self):
        result, _ = self.run_probe(lambda: setattr(self, "records", []))
        self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_missing_database_fails_without_creating_database(self):
        result, _ = self.run_probe(lambda: setattr(self, "records", None))
        self.assertEqual(result["reason"], "missing_transcript")
        self.assertFalse(transcript_path(self.state).exists())

    def test_corrupt_database_fails_before_cli(self):
        path = create_database(self.state)
        path.write_bytes(b"PRIVATE corrupt database")
        with mock.patch.object(self.canary.subprocess, "Popen") as popen:
            result = self.run_main()
        self.assertEqual(result["reason"], "invalid_transcript")
        popen.assert_not_called()

    def test_wrong_session_cannot_supply_receipt(self):
        result, _ = self.run_probe(lambda: setattr(self, "record_session", "other-session"))
        self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_tool_result_requires_matching_fresh_call_id(self):
        def change():
            self.records[1]["message"]["toolCallId"] = "unrelated-call"
        result, _ = self.run_probe(change)
        self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_tool_result_without_call_is_not_evidence(self):
        result, _ = self.run_probe(lambda: setattr(self, "records", self.records[1:]))
        self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_stale_and_future_event_or_insert_time_fails(self):
        for field in ("created_at", "timestamp"):
            for delta in (-100_000, 100_000):
                with self.subTest(field=field, delta=delta):
                    def change():
                        timestamp = int(time.time() * 1000) + delta
                        if field == "created_at":
                            self.created_at = timestamp
                        else:
                            for item in self.records:
                                item["message"]["timestamp"] = timestamp
                    result, _ = self.run_probe(change, "--force")
                    self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_preexisting_nonce_receipts_are_rejected_by_watermark(self):
        nonce = "openclaw-availability-" + "a" * 48
        command = f"printf '%s' '{nonce}'"
        now_ms = int(time.time() * 1000)
        insert_events(self.state, events(command, nonce, now_ms))
        with mock.patch.object(self.canary.secrets, "token_hex", return_value="a" * 48):
            with mock.patch.object(self.canary.time, "time", return_value=now_ms / 1000):
                result, _ = self.run_probe(lambda: setattr(self, "records", None))
        self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_tool_error_exit_status_and_token_are_not_success(self):
        for field, value in [
            ("isError", True), ("toolName", "browser"),
            ("details", {"exitCode": 1, "status": "completed"}),
            ("details", {"exitCode": False, "status": "completed"}),
            ("details", {"exitCode": 0, "status": "running"}),
            ("content", [{"type": "text", "text": "wrong"}]),
        ]:
            with self.subTest(field=field, value=value):
                result, _ = self.run_probe(
                    lambda: self.records[1]["message"].update({field: value}), "--force",
                )
                self.assertEqual(result["reason"], "missing_exec_receipt")

    def test_other_commands_or_tool_overrides_are_rejected(self):
        for arguments in ({"command": "touch unwanted"}, {"command": None, "host": "gateway"}):
            with self.subTest(arguments=arguments):
                def change():
                    self.records[0]["message"]["content"][0]["arguments"] = arguments
                result, _ = self.run_probe(change, "--force")
                self.assertEqual(result["reason"], "unexpected_tool_call")

    def test_return_code_must_be_zero(self):
        result, _ = self.run_probe(lambda: setattr(self, "exit_code", 3))
        self.assertEqual(result["reason"], "command_exit")

    def test_json_status_and_token_must_match(self):
        cases = [
            (b"PRIVATE malformed JSON", "invalid_json"),
            ([], "invalid_result"),
            ({"status": "error"}, "invalid_result"),
            ({"status": "ok", "result": {}}, "token_mismatch"),
            ({"status": "ok", "result": {"payloads": [{"text": "wrong"}]}}, "token_mismatch"),
        ]
        for response, reason in cases:
            with self.subTest(reason=reason, response=response):
                result, _ = self.run_probe(
                    lambda: setattr(self, "response", response), "--force"
                )
                self.assertEqual(result["reason"], reason)

    def test_missing_session_metadata_fails(self):
        result, _ = self.run_probe(lambda: self.response["result"].pop("meta"))
        self.assertEqual(result["reason"], "invalid_result")

    def test_timeout_kills_only_own_new_process_group(self):
        process = mock.Mock(pid=987654)
        process.stdout = io.BytesIO(b"PRIVATE")
        process.wait.side_effect = [
            subprocess.TimeoutExpired("PRIVATE command", 95), None,
        ]
        with mock.patch.object(self.canary.subprocess, "Popen", return_value=process):
            with mock.patch.object(os, "killpg", create=True) as killpg:
                result = self.run_main()
        self.assertEqual(result["reason"], "timeout")
        killpg.assert_called_once_with(process.pid, signal.SIGKILL if os.name != "nt" else 9)
        self.assertLessEqual(process.wait.call_args_list[0].kwargs["timeout"], 95)
        self.assertEqual(process.wait.call_args_list[1], mock.call(timeout=5))

    def test_stdout_capture_is_bounded_before_command_exits(self):
        process = mock.Mock(pid=987654, returncode=0)
        data = b"x" * (self.canary.MAX_OUTPUT_BYTES + 1)
        process.stdout.read.return_value = data
        with mock.patch.object(self.canary.subprocess, "Popen", return_value=process):
            with mock.patch.object(os, "killpg", create=True) as killpg:
                result = self.run_main()
        self.assertEqual(result["reason"], "output_limit")
        process.stdout.read.assert_called_once_with(self.canary.MAX_OUTPUT_BYTES + 1)
        killpg.assert_called_once_with(process.pid, signal.SIGKILL)

    def test_success_cache_and_force_do_not_retimestamp_old_evidence(self):
        first, _ = self.run_probe()
        with mock.patch.object(self.canary.subprocess, "Popen") as popen:
            cached = self.run_main()
        popen.assert_not_called()
        self.assertEqual(first, cached)
        old_nonce = self.nonce
        result, popen = self.run_probe(None, "--force")
        self.assertTrue(result["ok"])
        self.assertNotEqual(self.nonce, old_nonce)
        popen.assert_called_once()

    def test_failure_is_retried_on_each_health_run(self):
        failed, _ = self.run_probe(lambda: setattr(self, "records", []))
        self.assertFalse(failed["ok"])
        result, popen = self.run_probe()
        self.assertTrue(result["ok"])
        popen.assert_called_once()

    def test_expired_future_naive_and_malformed_cache_are_not_success(self):
        initial, _ = self.run_probe()
        for timestamp in [
            (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=3601)).isoformat(),
            (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=300)).isoformat(),
            dt.datetime.now().isoformat(),
            "PRIVATE invalid timestamp",
        ]:
            with self.subTest(timestamp=timestamp):
                value = dict(initial, timestamp=timestamp)
                self.cache.write_text(json.dumps(value))
                result, popen = self.run_probe()
                self.assertTrue(result["ok"])
                popen.assert_called_once()

    def test_cache_with_wrong_schema_is_rejected(self):
        initial, _ = self.run_probe()
        for update in [{"ok": 1}, {"reason": "PRIVATE"}, {"durationMs": True}, {"extra": "PRIVATE"}]:
            with self.subTest(update=update):
                self.cache.write_text(json.dumps(dict(initial, **update)))
                result, popen = self.run_probe()
                self.assertTrue(result["ok"])
                popen.assert_called_once()

    def test_same_status_path_cannot_reuse_another_state_cache(self):
        self.run_probe()
        self.state = self.scratch / "another-state"
        result, popen = self.run_probe(lambda: setattr(self, "records", []))
        self.assertFalse(result["ok"])
        popen.assert_called_once()

    def test_status_cannot_replace_coordination_lock_or_database(self):
        for target in (
            self.state / ".availability" / "check.lock",
            self.maintenance,
            transcript_path(self.state),
        ):
            with self.subTest(target=target):
                self.target = target
                result = self.run_main()
                self.assertEqual(result["reason"], "invalid_status_path")
        self.assertEqual(self.maintenance.read_bytes(), b"")

    def test_different_status_paths_share_only_same_state_cache(self):
        first, _ = self.run_probe()
        self.target = self.scratch / "other-health" / "availability.json"
        with mock.patch.object(self.canary.subprocess, "Popen") as popen:
            cached = self.run_main()
        self.assertEqual(first, cached)
        self.assertEqual(json.loads(self.target.read_text()), first)
        popen.assert_not_called()

    def test_zero_max_age_disables_cache(self):
        self.run_probe()
        result, popen = self.run_probe(None, "--max-age-seconds", "0")
        self.assertTrue(result["ok"])
        popen.assert_called_once()

    def test_invalid_argument_emits_only_redacted_status(self):
        result = self.run_main("--max-age-seconds", "PRIVATE")
        self.assertEqual(result["reason"], "invalid_arguments")

    def test_missing_maintenance_lock_fails_closed(self):
        self.maintenance.unlink()
        with mock.patch.object(self.canary.subprocess, "Popen") as popen:
            result = self.run_main()
        self.assertEqual(result["reason"], "maintenance_lock_unavailable")
        popen.assert_not_called()

    def test_default_defers_global_maintenance_lock_to_health_wrapper(self):
        self.change = None
        self.maintenance.unlink()
        output = io.StringIO()
        with mock.patch.object(self.canary.subprocess, "Popen", side_effect=self.cli):
            with mock.patch.object(self.canary.fcntl, "flock") as flock:
                with contextlib.redirect_stdout(output):
                    code = self.canary.main(self.arguments()[:-2])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(output.getvalue())["ok"])
        self.assertEqual(flock.call_count, 1)
        self.assertEqual(flock.call_args.args[1], self.canary.fcntl.LOCK_EX | self.canary.fcntl.LOCK_NB)

    def test_overlap_does_not_replace_inflight_status(self):
        first, _ = self.run_probe()
        with mock.patch.object(self.canary.fcntl, "flock", side_effect=BlockingIOError):
            result = self.run_main("--force")
        self.assertEqual(result["reason"], "already_running")
        self.assertEqual(json.loads(self.target.read_text()), first)

    def test_exclusive_maintenance_preserves_last_status_and_cache(self):
        previous, _ = self.run_probe()
        with mock.patch.object(
            self.canary.fcntl, "flock", side_effect=[None, BlockingIOError],
        ):
            result = self.run_main()
        self.assertEqual(result["reason"], "maintenance_active")
        self.assertEqual(json.loads(self.cache.read_text()), previous)
        self.assertEqual(json.loads(self.target.read_text()), previous)
        with mock.patch.object(self.canary.subprocess, "Popen") as popen:
            result = self.run_main()
        self.assertEqual(result, previous)
        popen.assert_not_called()

    def test_atomic_replacement_failure_never_leaves_partial_status(self):
        self.target.parent.mkdir()
        self.target.write_text('{"old":true}')
        with mock.patch.object(os, "replace", side_effect=OSError("PRIVATE")):
            with self.assertRaises(OSError):
                self.canary.write_status(self.target, {"ok": True})
        self.assertEqual(self.target.read_text(), '{"old":true}')
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_sqlite_is_opened_read_only(self):
        path = create_database(self.state)
        with self.canary.database(path) as connection:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM transcript_events")

    @unittest.skipUnless(os.name == "posix", "Linux process-group and flock integration")
    def test_real_flock_prevents_overlapping_checks(self):
        self.state.mkdir()
        directory = self.state / ".availability"
        directory.mkdir()
        with self.canary.lock(directory / "check.lock"):
            result = self.run_main()
        self.assertEqual(result["reason"], "already_running")

    @unittest.skipUnless(os.name == "posix", "Linux process-group integration")
    def test_real_timeout_terminates_child_and_grandchild(self):
        real_popen = subprocess.Popen
        pid_path = self.scratch / "child.pid"
        parent = []
        code = (
            "import pathlib, subprocess, sys, time; "
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(60)']); "
            f"pathlib.Path({str(pid_path)!r}).write_text(str(child.pid)); "
            "time.sleep(60)"
        )

        def substitute(argv, **kwargs):
            process = real_popen([sys.executable, "-c", code], **kwargs)
            parent.append(process)
            return process

        with mock.patch.object(self.canary.subprocess, "Popen", side_effect=substitute):
            with mock.patch.object(self.canary, "PROCESS_TIMEOUT", 1):
                result = self.run_main()
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual(parent[0].poll(), -signal.SIGKILL)
        child_pid = int(pid_path.read_text())
        child_status = Path("/proc") / str(child_pid) / "status"
        if child_status.exists():
            self.assertIn("\nState:\tZ", child_status.read_text())


if __name__ == "__main__":
    if "--fake-cli" in sys.argv:
        fake_cli()
    else:
        unittest.main()
