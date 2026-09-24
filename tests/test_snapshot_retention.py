import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "openclaw-create-vm-snapshot.sh"
DISK_ID = (
    "/subscriptions/00000000-0000-0000-0000-000000000000/"
    "resourceGroups/rg-openclaw/providers/Microsoft.Compute/disks/openclaw-os"
)


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "requires bash and jq")
class SnapshotRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state_path = self.root / "az-state.json"
        self.log_path = self.root / "az-log.jsonl"
        self.runtime_state = self.root / "runtime-state"
        az = self.bin / "az"
        az.write_text(textwrap.dedent(
            r"""#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ["AZ_STATE"])
log_path = Path(os.environ["AZ_LOG"])
args = sys.argv[1:]
with log_path.open("a") as output:
    output.write(json.dumps(args) + "\n")
state = json.loads(state_path.read_text())

def option(name):
    return args[args.index(name) + 1]

if args[:1] == ["login"] or args[:2] == ["account", "set"]:
    pass
elif args[:2] == ["group", "show"]:
    print("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-openclaw")
elif args[:2] == ["vm", "show"]:
    print(state["disk_id"])
elif args[:2] == ["disk", "show"]:
    print(state["location"])
elif args[:2] == ["snapshot", "create"]:
    name = option("--name")
    source = option("--source")
    stamp = name.removeprefix("openclaw-auto-daily-")
    created = datetime.datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(
        tzinfo=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    snapshot = {
        "name": name,
        "id": f"/snapshots/{name}",
        "timeCreated": created,
        "provisioningState": "Succeeded",
        "incremental": True,
        "creationData": {"sourceResourceId": source},
        "tags": {
            "purpose": "openclaw-automated-backup",
            "retention": "3",
            "createdBy": "openclaw-vm-snapshot",
        },
    }
    state["snapshots"].append(snapshot)
    state_path.write_text(json.dumps(state))
    print(json.dumps(snapshot))
elif args[:2] == ["snapshot", "show"]:
    name = option("--name")
    snapshot = next(item for item in state["snapshots"] if item["name"] == name)
    if state.get("readback_failure"):
        snapshot = {**snapshot, "provisioningState": "Failed"}
    print(json.dumps(snapshot))
elif args[:2] == ["snapshot", "list"]:
    print(json.dumps(state["snapshots"]))
elif args[:2] == ["snapshot", "delete"]:
    name = option("--name")
    state["snapshots"] = [item for item in state["snapshots"] if item["name"] != name]
    state_path.write_text(json.dumps(state))
else:
    raise SystemExit(f"unexpected az invocation: {args}")
"""))
        az.chmod(0o755)

    def snapshot(self, day, *, disk_id=DISK_ID, purpose="openclaw-automated-backup"):
        name = f"openclaw-auto-daily-202601{day:02d}T053000Z"
        return {
            "name": name,
            "id": f"/snapshots/{name}",
            "timeCreated": f"2026-01-{day:02d}T05:30:00Z",
            "provisioningState": "Succeeded",
            "incremental": True,
            "creationData": {"sourceResourceId": disk_id},
            "tags": {
                "purpose": purpose,
                "retention": "3",
                "createdBy": "openclaw-vm-snapshot",
            },
        }

    def run_script(self, *, readback_failure=False):
        snapshots = [self.snapshot(day) for day in range(1, 5)]
        snapshots.append(self.snapshot(
            9,
            disk_id=DISK_ID.replace("openclaw-os", "other-os"),
            purpose="foreign",
        ))
        null_source = self.snapshot(10)
        null_source["creationData"] = {}
        snapshots.append(null_source)
        self.state_path.write_text(json.dumps({
            "disk_id": DISK_ID,
            "location": "centralus",
            "readback_failure": readback_failure,
            "snapshots": snapshots,
        }))
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "AZ_STATE": str(self.state_path),
            "AZ_LOG": str(self.log_path),
            "STATE_DIRECTORY": str(self.runtime_state),
            "OPENCLAW_AZURE_RESOURCE_GROUP": "rg-openclaw",
            "OPENCLAW_AZURE_VM_NAME": "openclaw-vm",
        }
        return subprocess.run(
            ["bash", str(SCRIPT)], env=env, text=True, capture_output=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def test_retention_verifies_current_source_before_exact_oldest_deletes(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        vm_show = next(i for i, call in enumerate(calls) if call[:2] == ["vm", "show"])
        create = next(i for i, call in enumerate(calls) if call[:2] == ["snapshot", "create"])
        show = next(i for i, call in enumerate(calls) if call[:2] == ["snapshot", "show"])
        deletes = [(i, call) for i, call in enumerate(calls)
                   if call[:2] == ["snapshot", "delete"]]
        self.assertLess(vm_show, create)
        self.assertLess(create, show)
        self.assertTrue(deletes)
        self.assertLess(show, deletes[0][0])
        create_call = calls[create]
        self.assertEqual(create_call[create_call.index("--source") + 1], DISK_ID)
        self.assertEqual(
            [call[call.index("--name") + 1] for _, call in deletes],
            [
                "openclaw-auto-daily-20260102T053000Z",
                "openclaw-auto-daily-20260101T053000Z",
            ],
        )
        for _, call in deletes:
            self.assertNotIn("--ids", call)
            self.assertEqual(call.count("--name"), 1)

        retained = json.loads(
            (self.runtime_state / "last-automated-inventory.json").read_text())
        retained_names = [item["name"] for item in retained]
        self.assertEqual(len(retained_names), 3)
        self.assertEqual(retained_names, sorted(
            retained_names,
            key=lambda name: next(
                item["timeCreated"] for item in retained if item["name"] == name),
            reverse=True,
        ))
        remaining = json.loads(self.state_path.read_text())["snapshots"]
        self.assertIn("openclaw-auto-daily-20260109T053000Z",
                      [item["name"] for item in remaining])

    def test_readback_failure_prevents_all_retention_deletes(self):
        result = self.run_script(readback_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("readback_mismatch", result.stderr)
        self.assertFalse(any(call[:2] == ["snapshot", "delete"] for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
