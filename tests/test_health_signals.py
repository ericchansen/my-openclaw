import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "scripts/openclaw-health-check.sh").read_text()
CAPACITY_SOURCE = SOURCE[SOURCE.index("capacity_memory_percent="):SOURCE.index("maintenance_lock=")]


@unittest.skipUnless(shutil.which("jq"), "jq expressions run in the Linux repository gate")
class HealthSignalTests(unittest.TestCase):
    def test_automation_total_is_compared_in_object_context(self):
        query = re.search(
            r"jq -e '(\s*type == \"object\" and\s*\(\.jobs.*?)' \"\$work/automation_list.json\"",
            SOURCE, re.S)[1]
        listing = {
            "total": 1, "offset": 0, "limit": 200, "hasMore": False, "nextOffset": None,
            "jobs": [{"id": "fixture", "enabled": True, "schedule": {}, "payload": {}, "state": {}}],
        }
        for total, expected in ((1, True), (2, False), ("1", False)):
            with self.subTest(total=total):
                result = subprocess.run(
                    ["jq", "-e", query], input=json.dumps({**listing, "total": total}),
                    text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_doctor_warnings_are_not_errors_but_unknown_findings_fail(self):
        query = re.search(
            r"jq -e '(\.findings[^']*all\(\.\[\];[^']*)' \"\$work/doctor.json\"",
            SOURCE, re.S)[1]
        for findings, expected in (
            ([], True),
            ([{"severity": "warning"}], True),
            ([{"severity": "info"}], True),
            ([{"severity": "error"}], False),
            ([{"severity": "unknown"}], False),
            (None, False),
        ):
            with self.subTest(findings=findings):
                result = subprocess.run(
                    ["jq", "-e", query], input=json.dumps({"findings": findings}),
                    text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, expected)

    def test_channel_connectivity_matters_even_when_token_probe_succeeds(self):
        query = re.search(
            r'channel_probe_failures="\$\(jq -r \'(.*?)\' \"\$work/channels.json\"',
            SOURCE, re.S)[1]
        for account, expected in (
            ({"enabled": True, "running": True, "connected": True, "probe": {"ok": True}}, 0),
            ({"enabled": True, "running": False, "probe": {"ok": True}}, 1),
            ({"enabled": True, "connected": False, "probe": {"ok": True}}, 1),
            ({"enabled": True, "probe": {"ok": False}}, 1),
            ({"enabled": False, "running": False}, 0),
        ):
            with self.subTest(account=account):
                result = subprocess.run(
                    ["jq", "-r", query],
                    input=json.dumps({"channelAccounts": {"telegram": [account]}}),
                    text=True, capture_output=True, check=True)
                self.assertEqual(int(result.stdout), expected)


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires bash and jq")
class CapacitySignalTests(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / f".capacity-fixture-{uuid.uuid4().hex}"
        (self.work / "proc/pressure").mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.work)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("OPENCLAW_CAPACITY_")}
        self.write_metrics()

    def write_metrics(self, memory=50, swap=0, swap_total=100000, memory_some=0,
                      memory_full=0, cpu_some=0):
        (self.work / "proc/meminfo").write_text(
            f"MemTotal: 100000 kB\nMemAvailable: {100000 - memory * 1000} kB\n"
            f"SwapTotal: {swap_total} kB\nSwapFree: {swap_total * (100 - swap) // 100} kB\n")
        (self.work / "proc/pressure/memory").write_text(
            f"some avg10=99.99 avg60={memory_some:.2f} avg300=0.00 total=123456789\n"
            f"full avg10=99.99 avg60={memory_full:.2f} avg300=0.00 total=123456789\n")
        (self.work / "proc/pressure/cpu").write_text(
            f"some avg10=99.99 avg60={cpu_some:.2f} avg300=0.00 total=123456789\n"
            "full avg10=0.00 avg60=99.99 avg300=0.00 total=0\n")

    def run_sample(self, overrides=None):
        return subprocess.run(
            ["bash", "-c", "set -Eeuo pipefail\n" + CAPACITY_SOURCE +
             '\nsample_capacity "$1"\nprintf "%s\\n" "$capacity_json"\n',
             "capacity-test", str(self.work / "proc")],
            env={**self.env, **(overrides or {})}, text=True, capture_output=True, timeout=10)

    def sample(self, overrides=None):
        result = self.run_sample(overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_normal_and_inactive_swap_are_not_pressure(self):
        for swap in (0, 80, 99, 100):
            with self.subTest(swap=swap):
                self.write_metrics(memory=50, swap=swap)
                record = self.sample()
                self.assertEqual(record["state"], "normal")
                self.assertFalse(record["pressure"])
                self.assertEqual(record["reasons"], [])
                self.assertEqual(record["cpuSomeAvg60Percent"], 0)
                self.assertEqual(record["unavailableSignals"], [])

    def test_memory_swap_combination_and_exact_boundaries(self):
        for memory, swap, expected in ((89, 99, True), (85, 80, True),
                                       (84, 99, False), (99, 79, False)):
            with self.subTest(memory=memory, swap=swap):
                self.write_metrics(memory=memory, swap=swap)
                record = self.sample()
                self.assertEqual(record["pressure"], expected)
                self.assertEqual(record["reasons"], ["memory_swap_pressure"] if expected else [])
        self.write_metrics(memory=99, swap=100, swap_total=0)
        self.assertFalse(self.sample()["pressure"])

    def test_real_psi_stalls_independently_signal_pressure(self):
        for metric, threshold, reason in (
            ("memory_some", 10, "memory_psi_some"),
            ("memory_full", 2, "memory_psi_full"),
            ("cpu_some", 25, "cpu_psi_some"),
        ):
            for value, expected in ((threshold - 0.01, False), (threshold, True)):
                with self.subTest(metric=metric, value=value):
                    self.write_metrics(**{metric: value})
                    record = self.sample()
                    self.assertEqual(record["pressure"], expected)
                    self.assertEqual(record["reasons"], [reason] if expected else [])

    def test_unavailable_and_malformed_psi_are_not_fabricated_zero(self):
        for contents in (None, "", "some avg60=NaN\nfull avg60=-1\n",
                         "some avg60=100.01\nfull avg60=infinity\n",
                         "some avg60=2\nsome avg60=3\n"):
            with self.subTest(contents=contents):
                for resource in ("cpu", "memory"):
                    path = self.work / f"proc/pressure/{resource}"
                    if contents is None:
                        path.unlink(missing_ok=True)
                    else:
                        path.write_text(contents)
                record = self.sample()
                self.assertFalse(record["pressure"])
                self.assertEqual(record["state"], "unavailable")
                self.assertIsNone(record["memorySomeAvg60Percent"])
                self.assertIsNone(record["memoryFullAvg60Percent"])
                self.assertIsNone(record["cpuSomeAvg60Percent"])
                self.assertEqual(record["unavailableSignals"],
                                 ["memory_psi_some", "memory_psi_full", "cpu_psi_some"])

    def test_combined_pressure_still_works_without_optional_psi(self):
        self.write_metrics(memory=89, swap=99)
        shutil.rmtree(self.work / "proc/pressure")
        record = self.sample()
        self.assertEqual(record["state"], "pressure")
        self.assertEqual(record["reasons"], ["memory_swap_pressure"])
        self.assertEqual(len(record["unavailableSignals"]), 3)

    def test_missing_meminfo_is_explicitly_unavailable(self):
        (self.work / "proc/meminfo").unlink()
        record = self.sample()
        self.assertEqual(record["state"], "unavailable")
        self.assertFalse(record["memoryMetricsAvailable"])
        self.assertEqual(record["unavailableSignals"], ["memory_usage"])

    def test_validated_threshold_overrides_and_defaults(self):
        self.assertEqual(self.sample()["thresholds"], {
            "memoryUsedPercent": 85, "swapUsedPercent": 80, "memorySomeAvg60Percent": 10,
            "memoryFullAvg60Percent": 2, "cpuSomeAvg60Percent": 25,
        })
        self.write_metrics(memory=89, swap=99, memory_some=10, memory_full=2, cpu_some=25)
        overrides = {
            "OPENCLAW_CAPACITY_MEMORY_PERCENT": "90", "OPENCLAW_CAPACITY_SWAP_PERCENT": "99",
            "OPENCLAW_CAPACITY_MEMORY_SOME_AVG60": "11",
            "OPENCLAW_CAPACITY_MEMORY_FULL_AVG60": "3",
            "OPENCLAW_CAPACITY_CPU_SOME_AVG60": "26",
        }
        self.assertFalse(self.sample(overrides)["pressure"])
        self.write_metrics(memory=90, swap=99, memory_some=11, memory_full=3, cpu_some=26)
        self.assertEqual(self.sample(overrides)["reasons"], [
            "memory_swap_pressure", "memory_psi_some", "memory_psi_full", "cpu_psi_some"])

    def test_invalid_threshold_inputs_fail_before_sampling(self):
        for key, minimum, maximum in (
            ("MEMORY_PERCENT", 70, 99), ("SWAP_PERCENT", 50, 99),
            ("MEMORY_SOME_AVG60", 1, 100), ("MEMORY_FULL_AVG60", 1, 100),
            ("CPU_SOME_AVG60", 5, 100),
        ):
            for value in ("", "-1", "0", "1.5", "NaN", "085", " 85", "1+84",
                          "999999999999999999999999", str(minimum - 1), str(maximum + 1)):
                with self.subTest(key=key, value=value):
                    result = self.run_sample({f"OPENCLAW_CAPACITY_{key}": value})
                    self.assertEqual(result.returncode, 64, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Invalid capacity threshold:", result.stderr)
        result = self.run_sample({"OPENCLAW_CAPACITY_MEMORY_FULL_AVG60": "11"})
        self.assertEqual(result.returncode, 64)

    def test_early_log_and_final_record_preserve_consumer_contract(self):
        self.write_metrics(memory=89, swap=99)
        fixtures = {
            "status": {}, "availability": {"ok": True}, "doctor": {"findings": []},
            "channels": {"channelAccounts": {}}, "security": {"summary": {}},
            "secrets": {"summary": {}}, "automations": {
                "enabled": True, "triggersEnabled": True, "storage": "sqlite",
                "jobs": 0, "nextWakeAtMs": None,
            }, "automation_list": {
                "jobs": [], "total": 0, "offset": 0, "limit": 200,
                "hasMore": False, "nextOffset": None,
            }, "tasks": {"summary": {"combined": {"errors": 0, "warnings": 0}}},
            "task_settlement": {"count": 0, "runtime": "subagent", "status": None, "tasks": []},
            "backup": {"timestamp": "2099-01-01T00:00:00Z", "result": "succeeded"},
        }
        for name, data in fixtures.items():
            (self.work / f"{name}.json").write_text(json.dumps(data))
        mocks = r'''
work="$1"
health_state_dir="$work"
backup_status="$work/backup.json"
backup_max_age_seconds=129600
automation_recent_failure_seconds=7200
automation_failure_threshold=1
task_settlement_max_age_seconds=2400
gateway_url=http://fixture.invalid/health
now="$(date -d 2099-01-01 +%s)"
now_ms=$((now * 1000))
check_started_ms="$(date +%s%3N)"
curl() { return 0; }
systemctl() { printf 'ActiveState=active\nResult=success\nNRestarts=0\n'; }
df() { printf 'Use%%\n10%%\n'; }
logger() { printf '%s\n' "${@: -1}" >>"$work/log.jsonl"; }
timeout() { shift 3; "$@"; }
'''
        capture_mock = r'''
capture_json() {
  [[ -s "$work/log.jsonl" ]] || exit 91
  CAPTURE_EXIT=0
  CAPTURE_VALID=true
  CAPTURE_REASON=none
  CAPTURE_DURATION_MS=1
}
'''
        body = SOURCE[SOURCE.index("# Emit the cheap sample"):]
        body = body.replace("sample_capacity\n", 'sample_capacity "$work/proc"\n', 1)
        body = body.replace("gateway_ok=false\n", capture_mock + "\ngateway_ok=false\n", 1)
        result = subprocess.run(
            ["bash", "-c", "set -Eeuo pipefail\n" + CAPACITY_SOURCE + mocks + body,
             "health-test", str(self.work)],
            env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 1, result.stderr)
        final = json.loads(result.stdout)  # stdout remains one complete health record.
        logs = [json.loads(line) for line in (self.work / "log.jsonl").read_text().splitlines()]
        self.assertEqual(len(logs), 2)
        early = logs[0]
        self.assertEqual(early["event"], "capacity")
        self.assertEqual(early["capacitySchemaVersion"], 1)
        self.assertNotIn("schemaVersion", early)
        self.assertEqual(final["schemaVersion"], 2)
        self.assertEqual(final["event"], "health")
        self.assertEqual(final["capacity"], early["capacity"])
        self.assertEqual(final["actionableFailures"], ["capacity_pressure"])
        self.assertTrue(final["availabilityOk"])
        self.assertTrue(final["gatewayOk"])
        self.assertTrue(final["taskOk"])
        self.assertTrue(final["taskAuditOk"])
        self.assertTrue(final["taskSettlementOk"])
        self.assertEqual(final["taskSettlementCount"], 0)
        self.assertEqual(final["taskSettlementInventoryCount"], 0)
        self.assertIsNone(final["taskSettlementOldestAgeSeconds"])
        self.assertEqual(final["taskSettlementFailureReason"], "none")
        self.assertEqual(final["memoryUsedPercent"], 89)
        self.assertEqual(final["swapUsedPercent"], 99)
        self.assertEqual(final["memoryAvailableBytes"], 11000 * 1024)
        self.assertEqual(final["swapUsedBytes"], 99000 * 1024)
        self.assertTrue(all(len(json.dumps(record)) < 8192 for record in logs))


class CapacityInfrastructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bicep = shutil.which("bicep")
        az = shutil.which("az")
        if not bicep and not az:
            raise unittest.SkipTest("Bicep or Azure CLI is required for offline ARM compilation")
        command = [bicep, "build"] if bicep else [az, "bicep", "build"]
        cls.templates = {}
        for name in ("main", "main-existing"):
            source = str(ROOT / f"infra/{name}.bicep")
            if not bicep and os.name != "nt" and shutil.which("wslpath") and Path(az).with_suffix(".cmd").exists():
                source = subprocess.check_output(["wslpath", "-w", source], text=True).strip()
            result = subprocess.run(
                [*command, "--file", source, "--stdout"]
                if not bicep else [*command, source, "--stdout"],
                text=True, capture_output=True, timeout=120)
            if result.returncode != 0:
                raise AssertionError(f"{name} Bicep compilation failed: {result.stderr}")
            cls.templates[name] = json.loads(result.stdout)

    def resources(self, template):
        for resource in template["resources"]:
            yield resource
            nested = resource.get("properties", {}).get("template")
            if resource["type"] == "Microsoft.Resources/deployments" and nested:
                yield from self.resources(nested)

    def resource(self, template, name):
        return next(resource for resource in self.resources(template)
                    if resource["name"] == name and resource["type"] in (
                        "Microsoft.Insights/metricAlerts", "Microsoft.Insights/scheduledQueryRules"))

    def test_complete_alert_definitions_compile_and_match_in_both_templates(self):
        for name in ("openclaw-cpu-saturation", "openclaw-capacity-pressure"):
            definitions = []
            for template in self.templates.values():
                resource = self.resource(template, name)
                definitions.append({key: value for key, value in resource.items()
                                    if key != "dependsOn"})
            self.assertEqual(*definitions)

    def test_platform_cpu_alert_is_independent_of_guest_and_credit_metrics(self):
        for template in self.templates.values():
            resource = self.resource(template, "openclaw-cpu-saturation")
            self.assertEqual(resource["type"], "Microsoft.Insights/metricAlerts")
            self.assertEqual(resource["apiVersion"], "2018-03-01")
            self.assertEqual(resource["location"], "global")
            properties = resource["properties"]
            self.assertTrue(properties["enabled"])
            self.assertTrue(properties["autoMitigate"])
            self.assertEqual(properties["severity"], 1)
            self.assertEqual(properties["evaluationFrequency"], "PT1M")
            self.assertEqual(properties["windowSize"], "PT15M")
            self.assertEqual(properties["targetResourceType"], "Microsoft.Compute/virtualMachines")
            self.assertIn("Microsoft.Compute/virtualMachines", properties["scopes"][0])
            self.assertEqual(properties["actions"], "[variables('metricAlertActions')]")
            self.assertEqual(properties["criteria"], {
                "odata.type": "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria",
                "allOf": [{
                    "name": "CpuSaturation", "metricNamespace": "Microsoft.Compute/virtualMachines",
                    "metricName": "Percentage CPU", "operator": "GreaterThanOrEqual",
                    "timeAggregation": "Average", "criterionType": "StaticThresholdCriterion",
                    "threshold": "[parameters('cpuSaturationPercent')]", "skipMetricValidation": False,
                }],
            })
            parameter = template["parameters"]["cpuSaturationPercent"]
            self.assertEqual((parameter["defaultValue"], parameter["minValue"], parameter["maxValue"]),
                             (90, 80, 99))

    def test_guest_alert_uses_only_latest_fresh_early_record(self):
        for template in self.templates.values():
            resource = self.resource(template, "openclaw-capacity-pressure")
            self.assertEqual(resource["type"], "Microsoft.Insights/scheduledQueryRules")
            self.assertEqual(resource["apiVersion"], "2023-12-01")
            self.assertEqual(resource["kind"], "LogAlert")
            properties = resource["properties"]
            self.assertTrue(properties["enabled"])
            self.assertTrue(properties["autoMitigate"])
            self.assertEqual(properties["severity"], 2)
            self.assertEqual(properties["evaluationFrequency"], "PT5M")
            self.assertEqual(properties["windowSize"], "PT30M")
            self.assertIn("Microsoft.OperationalInsights/workspaces", properties["scopes"][0])
            self.assertEqual(properties["actions"], "[variables('alertActions')]")
            criterion, = properties["criteria"]["allOf"]
            query = criterion["query"]
            for fragment in ('Facility == "local6"', 'ProcessName == "openclaw-health"',
                             'd.event == "capacity"', 'toint(d.capacitySchemaVersion) == 1',
                             'SampledAt between (ago(20m) .. now())',
                             'summarize arg_max(SampledAt, *) by Computer',
                             'where tobool(d.capacity.pressure) == true'):
                self.assertIn(fragment, query)
            self.assertLess(query.index("arg_max"), query.index("capacity.pressure"))
            self.assertEqual({key: value for key, value in criterion.items() if key != "query"}, {
                "timeAggregation": "Count", "operator": "GreaterThan", "threshold": 0,
                "failingPeriods": {"numberOfEvaluationPeriods": 1, "minFailingPeriodsToAlert": 1},
            })
            for name in ("openclaw-runtime-health", "openclaw-health-missing"):
                existing = self.resource(template, name)["properties"]["criteria"]["allOf"][0]["query"]
                self.assertIn("toint(d.schemaVersion) >= 2", existing)

    def test_boot_diagnostics_are_managed_without_existing_vm_or_topology_writes(self):
        self.assertEqual(self.templates["main"]["parameters"]["vmSize"]["defaultValue"],
                         "Standard_D4ps_v6")
        self.assertNotIn("vmSize", self.templates["main-existing"]["parameters"])
        vm, = [resource for resource in self.templates["main"]["resources"]
               if resource["type"] == "Microsoft.Compute/virtualMachines"]
        self.assertEqual(vm["properties"]["diagnosticsProfile"],
                         {"bootDiagnostics": {"enabled": True}})
        existing = self.templates["main-existing"]
        protected = {
            "Microsoft.Compute/virtualMachines", "Microsoft.Compute/disks",
            "Microsoft.Network/networkInterfaces", "Microsoft.Network/networkSecurityGroups",
            "Microsoft.Network/publicIPAddresses", "Microsoft.Network/virtualNetworks",
        }
        protected.update({
            "Microsoft.Network/natGateways", "Microsoft.Network/privateEndpoints",
            "Microsoft.Network/privateDnsZones", "Microsoft.KeyVault/vaults",
            "Microsoft.Storage/storageAccounts", "Microsoft.Authorization/roleAssignments",
        })
        self.assertFalse(protected.intersection(resource["type"] for resource in self.resources(existing)))
        self.assertNotIn("removePublicInbound", existing["parameters"])
        self.assertNotIn("disablePublicDataPlane", existing["parameters"])
        nic, = [resource for resource in self.templates["main"]["resources"]
                if resource["type"] == "Microsoft.Network/networkInterfaces"]
        self.assertTrue(nic["properties"]["enableAcceleratedNetworking"])


if __name__ == "__main__":
    unittest.main()
