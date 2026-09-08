import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "scripts/openclaw-health-check.sh").read_text()
THRESHOLD = SOURCE[SOURCE.index("task_settlement_max_age_seconds="):SOURCE.index("capacity_memory_percent=")]
SUMMARY = SOURCE[SOURCE.index("summarize_task_settlement() {"):SOURCE.index("maintenance_lock=")]
CAPTURE = SOURCE[SOURCE.index("capture_json() {"):SOURCE.index("\ngateway_ok=false")]
TASK_CHECK = SOURCE[SOURCE.index("capture_json tasks 25"):SOURCE.index('if [[ -f "$backup_status"')]
TASK_ACTIONS = SOURCE[SOURCE.index("(( task_errors > 0 )) && actionable_failures"):
                      SOURCE.index("actionable_failures_json=")]
NOW = 1800000000000


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires bash and jq")
class TaskSettlementTests(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / f".task-health-fixture-{uuid.uuid4().hex}"
        self.work.mkdir()
        self.addCleanup(shutil.rmtree, self.work)
        self.env = {key: value for key, value in os.environ.items()
                    if key != "OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS"}

    def task(self, age_ms=2400001, **changes):
        return {
            "taskId": "private-fixture-task", "runtime": "subagent",
            "runId": "private-fixture-run", "childSessionKey": "private-fixture-child",
            "ownerKey": "private-fixture-owner", "requesterSessionKey": "private-fixture-requester",
            "scopeKind": "session", "status": "failed", "deliveryStatus": "pending",
            "notifyPolicy": "done_only", "createdAt": NOW - 3600000,
            "startedAt": NOW - 3500000, "endedAt": NOW - age_ms,
            "lastEventAt": NOW - age_ms, "error": "private-fixture-error",
            "task": "private-fixture-prompt", "detail": {"private": "private-fixture-detail"},
            **changes,
        }

    def inventory(self, tasks):
        return {"count": len(tasks), "runtime": "subagent", "status": None, "tasks": tasks}

    def run_bash(self, body, env=None):
        return subprocess.run(
            ["bash", "-c", 'set -Eeuo pipefail\nwork="$1"\n' + THRESHOLD + SUMMARY + body,
             "health-test", str(self.work)],
            env={**self.env, **(env or {})}, text=True, capture_output=True, timeout=15)

    def summarize(self, tasks, **root_changes):
        (self.work / "inventory.json").write_text(json.dumps({
            **self.inventory(tasks), **root_changes,
        }))
        result = self.run_bash(f'\nsummarize_task_settlement "$work/inventory.json" {NOW}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("private-fixture", result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_strict_age_boundary_and_terminal_helper_statuses(self):
        for status in ("succeeded", "failed", "timed_out", "cancelled", "lost"):
            for age, stale in ((2399999, False), (2400000, False), (2400001, True)):
                with self.subTest(status=status, age=age):
                    record = self.summarize([self.task(age, status=status)])
                    self.assertEqual(record["ok"], not stale)
                    self.assertEqual(record["count"], int(stale))
                    self.assertEqual(record["oldestAgeSeconds"], age // 1000)
                    self.assertEqual(record["failureReason"],
                                     "stale_terminal_pending" if stale else "none")

    def test_session_queued_is_pending_settlement_not_running_execution(self):
        record = self.summarize([self.task(deliveryStatus="session_queued")])
        self.assertFalse(record["ok"])
        self.assertEqual(record["count"], 1)

    def test_native_timeout_with_equal_start_and_end_needs_no_audit_warning(self):
        audit = {"summary": {"combined": {"errors": 0, "warnings": 0}}}
        for age, stale in ((2400000, False), (2400001, True)):
            with self.subTest(age=age):
                task = self.task(age, status="timed_out", startedAt=NOW - age,
                                 notifyPolicy="done_only", deliveryStatus="pending")
                result = self.check(self.inventory([task]), audit=audit)
                self.assertEqual(result["ok"], not stale)
                self.assertEqual(result["settlementOk"], not stale)
                self.assertEqual(result["warnings"], 0)
                self.assertEqual(result["actions"], ["task-settlement"] if stale else [])

    def test_native_retry_window_and_delayed_deadline_processing_are_not_stale(self):
        for age in (90000, 900000, 1800000, 2280000):
            with self.subTest(age=age):
                task = self.task(age, status="timed_out", startedAt=NOW - age)
                result = self.check(self.inventory([task]))
                self.assertTrue(result["ok"])
                self.assertEqual(result["count"], 0)
                self.assertEqual(result["actions"], [])

    def test_days_old_pending_is_late_but_failed_delivery_is_already_settled(self):
        for delivery, stale in (("pending", True), ("failed", False)):
            with self.subTest(delivery=delivery):
                task = self.task(3 * 86400000, status="failed", deliveryStatus=delivery,
                                 createdAt=NOW - 4 * 86400000, startedAt=NOW - 3 * 86400000)
                result = self.check(self.inventory([task]))
                self.assertEqual(result["ok"], not stale)
                self.assertEqual(result["count"], int(stale))
                self.assertEqual(result["actions"], ["task-settlement"] if stale else [])

    def test_native_silent_timeout_and_delivered_success_are_settled(self):
        for status, delivery, policy in (
            ("timed_out", "not_applicable", "silent"),
            ("succeeded", "delivered", "done_only"),
        ):
            with self.subTest(status=status):
                task = self.task(status=status, deliveryStatus=delivery, notifyPolicy=policy,
                                 startedAt=NOW - 2400001)
                result = self.check(self.inventory([task]))
                self.assertTrue(result["ok"])
                self.assertTrue(result["settlementOk"])
                self.assertEqual(result["count"], 0)
                self.assertEqual(result["actions"], [])

    def test_running_queued_silent_and_not_required_work_do_not_page(self):
        for changes in (
            {"status": "running"}, {"status": "queued"}, {"notifyPolicy": "silent"},
            {"deliveryStatus": "not_applicable"}, {"scopeKind": "system"},
        ):
            with self.subTest(changes=changes):
                task = self.task(**changes)
                task.pop("endedAt")
                record = self.summarize([task])
                self.assertTrue(record["ok"])
                self.assertEqual(record["pendingCount"], 0)
                self.assertIsNone(record["oldestAgeSeconds"])

    def test_historical_delivery_failures_completions_and_dismissals_do_not_page(self):
        for delivery in ("failed", "delivered", "dismissed", "parent_missing", "not_applicable"):
            with self.subTest(delivery=delivery):
                record = self.summarize([self.task(deliveryStatus=delivery)])
                self.assertTrue(record["ok"])
                self.assertEqual(record["count"], 0)
        record = self.summarize([self.task(status="succeeded", terminalOutcome="blocked",
                                         deliveryStatus="failed")])
        self.assertTrue(record["ok"])

    def test_recent_redrive_refreshes_age_but_future_and_invalid_times_are_unknown(self):
        record = self.summarize([self.task(lastEventAt=NOW - 1000)])
        self.assertTrue(record["ok"])
        self.assertEqual(record["oldestAgeSeconds"], 1)
        for field in ("endedAt", "lastEventAt", "startedAt"):
            for value in (None, 0, -1, NOW + 1, "1800000000000", 1.5):
                with self.subTest(field=field, value=value):
                    record = self.summarize([self.task(**{field: value})])
                    self.assertIsNone(record["ok"])
                    self.assertEqual(record["unknownCount"], 1)
                    self.assertEqual(record["failureReason"], "invalid_timestamp")
                    self.assertIsNone(record["oldestAgeSeconds"])
        for changes in ({"endedAt": NOW - 4000000}, {"lastEventAt": NOW - 2500000},
                        {"startedAt": NOW - 1000}):
            self.assertIsNone(self.summarize([self.task(**changes)])["ok"])

    def test_no_created_time_fallback_when_terminal_timestamp_is_missing(self):
        task = self.task()
        task.pop("endedAt")
        self.assertIsNone(self.summarize([task])["ok"])
        task = self.task()
        task.pop("lastEventAt")  # Optional; the explicit canonical end remains usable.
        self.assertFalse(self.summarize([task])["ok"])

    def test_missing_correlation_is_unknown_not_invented_orphan_detection(self):
        for field in ("runId", "childSessionKey", "ownerKey", "requesterSessionKey"):
            with self.subTest(field=field):
                record = self.summarize([self.task(**{field: ""})])
                self.assertIsNone(record["ok"])
                self.assertEqual(record["failureReason"], "uncorrelated_terminal_pending")
                self.assertEqual(record["count"], 0)
        # The CLI inventory cannot reveal orphan queue owners whose task row no longer exists.
        empty = self.summarize([])
        self.assertTrue(empty["ok"])
        self.assertEqual(empty["inventoryCount"], 0)
        self.assertEqual(empty["count"], 0)

    def test_confirmed_stale_and_unknown_rows_remain_degraded_without_raw_data(self):
        record = self.summarize([
            self.task(), self.task(taskId="other-private-task", endedAt=None),
        ])
        self.assertFalse(record["ok"])
        self.assertEqual((record["count"], record["unknownCount"], record["inventoryCount"]),
                         (1, 1, 2))
        self.assertEqual(record["failureReason"], "stale_terminal_pending")

    def check(self, inventory=None, capture_reason="none", capture_exit=0, capture_valid=True,
              audit=None):
        if inventory is None:
            inventory = self.inventory([self.task()])
        (self.work / "task_settlement.json").write_text(json.dumps(inventory))
        (self.work / "tasks.json").write_text(json.dumps(
            {"summary": {"combined": {"errors": 0, "warnings": 2}}} if audit is None else audit))
        initial = SOURCE[SOURCE.index("task_ok=false"):SOURCE.index("backup_ok=false")]
        mock = f'''
task_errors=0
task_warnings=0
date() {{ printf "{NOW}\\n"; }}
capture_json() {{
  CAPTURE_EXIT=0
  CAPTURE_VALID=true
  CAPTURE_REASON=none
  CAPTURE_DURATION_MS=17
  if [[ "$1" == task_settlement ]]; then
    [[ "$*" == "task_settlement 25 openclaw tasks list --runtime subagent --json" ]] || exit 91
    CAPTURE_EXIT={capture_exit}
    CAPTURE_VALID={str(capture_valid).lower()}
    CAPTURE_REASON={capture_reason}
  fi
}}
'''
        output = '''
actionable_failures=()
''' + TASK_ACTIONS + '''
actions="$(jq -nc --args '$ARGS.positional' "${actionable_failures[@]}")"
jq -nc --argjson ok "$task_ok" --argjson auditOk "$task_audit_ok" \\
  --argjson settlementOk "$task_settlement_ok" --argjson count "$task_settlement_count" \\
  --argjson age "$task_settlement_oldest_age_seconds" --argjson warnings "$task_warnings" \\
  --argjson actions "$actions" --arg reason "$task_settlement_failure_reason" \\
  --arg taskReason "$task_failure_reason" --argjson duration "$task_settlement_duration_ms" \\
  '{ok:$ok,auditOk:$auditOk,settlementOk:$settlementOk,count:$count,age:$age,
    warnings:$warnings,actions:$actions,reason:$reason,taskReason:$taskReason,duration:$duration}'
'''
        result = self.run_bash(initial + mock + TASK_CHECK + output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("private-fixture", result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_zero_audit_errors_cannot_mask_confirmed_stale_settlement(self):
        result = self.check()
        self.assertFalse(result["ok"])
        self.assertTrue(result["auditOk"])
        self.assertFalse(result["settlementOk"])
        self.assertEqual(result["warnings"], 2)
        self.assertEqual(result["actions"], ["task-settlement"])
        self.assertEqual(result["taskReason"], "stale_settlement")
        self.assertEqual(result["duration"], 17)

    def test_healthy_settlement_preserves_audit_warnings_and_errors(self):
        result = self.check(self.inventory([self.task(1000)]))
        self.assertTrue(result["ok"])
        self.assertEqual(result["warnings"], 2)
        self.assertEqual(result["actions"], [])
        result = self.check(self.inventory([]),
                            audit={"summary": {"combined": {"errors": 1, "warnings": 2}}})
        self.assertFalse(result["ok"])
        self.assertEqual(result["actions"], ["task_errors"])
        self.assertEqual(result["taskReason"], "audit_errors")
        result = self.check(self.inventory([]), audit={"summary": {}})
        self.assertFalse(result["ok"])
        self.assertEqual(result["taskReason"], "invalid_contract")

    def test_capture_failures_are_unknown_not_green_or_false_stale_alerts(self):
        for reason, code, valid in (
            ("timeout", 124, False), ("terminated", 137, True), ("command_exit", 1, True),
            ("output_limit", 1, True), ("invalid_json", 0, False), ("empty_output", 0, False),
        ):
            with self.subTest(reason=reason):
                result = self.check(capture_reason=reason, capture_exit=code, capture_valid=valid)
                self.assertFalse(result["ok"])
                self.assertIsNone(result["settlementOk"])
                self.assertIsNone(result["count"])
                self.assertIsNone(result["age"])
                self.assertEqual(result["reason"], reason)
                self.assertEqual(result["taskReason"], "settlement_unknown")
                self.assertEqual(result["actions"], [])

    def test_incomplete_unknown_duplicate_and_unsupported_schema_fail_closed(self):
        base = self.inventory([self.task()])
        cases = [
            {}, [], {"count": 0, "tasks": []},
            {**base, "count": 2}, {**base, "count": "1"}, {**base, "count": 1.5},
            {**base, "runtime": None}, {**base, "status": "failed"},
            self.inventory([self.task(), self.task()]),
        ]
        for field in ("status", "deliveryStatus", "notifyPolicy", "scopeKind", "taskId"):
            cases.append(self.inventory([self.task(**{field: "" if field == "taskId" else "unknown"})]))
        # "completed" is a gateway display status, and revoked is not a TaskDeliveryStatus.
        cases += [self.inventory([self.task(status="completed")]),
                  self.inventory([self.task(deliveryStatus="revoked")]),
                  self.inventory([self.task(createdAt=0)]),
                  self.inventory([self.task(createdAt=NOW + 1)])]
        for inventory in cases:
            with self.subTest(inventory=inventory):
                result = self.check(inventory)
                self.assertFalse(result["ok"])
                self.assertIsNone(result["settlementOk"])
                self.assertEqual(result["reason"], "invalid_inventory")
                self.assertEqual(result["actions"], [])

    def test_multiple_json_roots_are_rejected(self):
        payload = json.dumps(self.inventory([]))
        (self.work / "inventory.json").write_text(payload + "\n" + payload)
        result = self.run_bash(f'\nsummarize_task_settlement "$work/inventory.json" {NOW}\n')
        self.assertNotEqual(result.returncode, 0)

    def test_threshold_bounds_are_validated_without_shell_evaluation(self):
        for value in ("", "0", "59", "3601", "-900", "0900", "900.0", "1+899", " 900",
                      "999999999999999999999999"):
            with self.subTest(value=value):
                result = self.run_bash("true", {"OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS": value})
                self.assertEqual(result.returncode, 64)
                self.assertEqual(result.stdout, "")
        for value in ("60", "2400", "3600"):
            result = self.run_bash("true", {"OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS": value})
            self.assertEqual(result.returncode, 0, result.stderr)
        (self.work / "inventory.json").write_text(json.dumps(self.inventory([self.task(60001)])))
        for value, healthy in (("60", False), ("3600", True)):
            result = self.run_bash(
                f'\nsummarize_task_settlement "$work/inventory.json" {NOW}\n',
                {"OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS": value})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["ok"], healthy)

    def test_real_capture_rejects_oversized_inventory_without_logging_it(self):
        body = "\ncapture_max_bytes=2097152\n" + CAPTURE + r'''
capture_json task_settlement 3 python3 -c 'import json; print(json.dumps({"data": "x" * 2097152}))'
printf "%s %s\\n" "$CAPTURE_EXIT" "$CAPTURE_REASON"
'''
        result = self.run_bash(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1 output_limit")


if __name__ == "__main__":
    unittest.main()
