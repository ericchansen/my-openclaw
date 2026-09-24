import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "openclaw-runtime-health-probe.sh"


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires bash and jq")
class RuntimeProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.proc = self.root / "proc"
        self.bin.mkdir()
        self.proc.mkdir()
        self.log = self.root / "syslog.jsonl"
        self.write_stub("timeout", r'''#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
''')
        self.write_stub("curl", r'''#!/usr/bin/env bash
[[ "${PROBE_GATEWAY_OK:-true}" == true ]]
''')
        self.write_stub("systemctl", r'''#!/usr/bin/env bash
if [[ "${PROBE_GATEWAY_OK:-true}" == true ]]; then
  printf 'ActiveState=active\nResult=success\n'
else
  printf 'ActiveState=failed\nResult=exit-code\n'
fi
''')
        self.write_stub("df", r'''#!/usr/bin/env bash
printf 'Use%%\n%s%%\n' "${PROBE_DISK_PERCENT:-10}"
''')
        self.write_stub("getconf", r'''#!/usr/bin/env bash
printf '%s\n' "${PROBE_CPU_COUNT:-2}"
''')
        self.write_stub("logger", r'''#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >>"$PROBE_LOG"
''')

    def write_stub(self, name, source):
        path = self.bin / name
        path.write_text(textwrap.dedent(source))
        path.chmod(0o755)

    def run_probe(self, *, gateway=True, memory=50, disk=10, load="0.10"):
        (self.proc / "meminfo").write_text(
            f"MemTotal: 100000 kB\nMemAvailable: {100000 - memory * 1000} kB\n"
        )
        (self.proc / "loadavg").write_text(f"{load} 0.10 0.10 1/100 1\n")
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "OPENCLAW_PROC_ROOT": str(self.proc),
            "PROBE_GATEWAY_OK": str(gateway).lower(),
            "PROBE_DISK_PERCENT": str(disk),
            "PROBE_LOG": str(self.log),
        }
        return subprocess.run(
            ["bash", str(PROBE)], env=env, text=True, capture_output=True, timeout=10
        )

    def test_probe_exit_tracks_gateway_and_core_capacity_health(self):
        for name, kwargs, healthy in (
            ("healthy", {}, True),
            ("gateway", {"gateway": False}, False),
            ("memory", {"memory": 95}, False),
            ("load", {"load": "2.00"}, False),
            ("disk", {"disk": 85}, False),
        ):
            with self.subTest(name=name):
                self.log.unlink(missing_ok=True)
                result = self.run_probe(**kwargs)
                self.assertEqual(result.returncode == 0, healthy, result.stderr)
                records = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["event"], "runtime_health_probe")
                self.assertEqual(records[0]["probeOk"], healthy)
                self.assertEqual(
                    [json.loads(line) for line in self.log.read_text().splitlines()], records
                )


class MonitoringWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        az = shutil.which("az")
        if not az:
            raise unittest.SkipTest("Azure CLI is required for Bicep compilation")
        cls.templates = {}
        for name in ("main", "main-existing"):
            result = subprocess.run(
                [az, "bicep", "build", "--file", str(ROOT / f"infra/{name}.bicep"),
                 "--stdout", "--only-show-errors"],
                text=True, capture_output=True, timeout=120,
            )
            if result.returncode:
                raise AssertionError(f"{name} Bicep compilation failed: {result.stderr}")
            cls.templates[name] = json.loads(result.stdout)

    @staticmethod
    def resources(template):
        for resource in template["resources"]:
            yield resource
            nested = resource.get("properties", {}).get("template")
            if resource["type"] == "Microsoft.Resources/deployments" and nested:
                yield from MonitoringWiringTests.resources(nested)

    def test_alerts_compile_with_only_the_agreed_routes(self):
        expected_queries = {
            "openclaw-disk-pressure",
            "openclaw-capacity-pressure",
            "openclaw-runtime-health-probe-failed",
            "openclaw-runtime-health-probe-missing",
        }
        for template in self.templates.values():
            alerts = {
                resource["name"]: resource
                for resource in self.resources(template)
                if resource["type"] in {
                    "Microsoft.Insights/scheduledQueryRules",
                    "Microsoft.Insights/metricAlerts",
                }
            }
            self.assertEqual(
                {name for name, resource in alerts.items()
                 if resource["type"] == "Microsoft.Insights/scheduledQueryRules"},
                expected_queries,
            )
            self.assertEqual(
                {name for name, resource in alerts.items()
                 if resource["type"] == "Microsoft.Insights/metricAlerts"},
                {"openclaw-vm-availability"},
            )
            for name in expected_queries:
                self.assertEqual(alerts[name]["properties"]["actions"],
                                 "[variables('diagnosticAlertActions')]")
            availability = alerts["openclaw-vm-availability"]["properties"]
            self.assertEqual(availability["actions"],
                             "[variables('ownerMetricAlertActions')]")
            criterion = availability["criteria"]["allOf"][0]
            self.assertEqual(criterion["metricName"], "VmAvailabilityMetric")
            self.assertEqual(criterion["timeAggregation"], "Maximum")
            self.assertNotIn("dimensions", criterion)


if __name__ == "__main__":
    unittest.main()
