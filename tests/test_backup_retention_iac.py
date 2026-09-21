import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).parents[1]


def plan(items, daily=7, monthly=2):
    if len({x["name"] for x in items}) != len(items):
        raise ValueError("duplicate names")
    for x in items:
        if not re.fullmatch(r"[^\x00-\x1f\x7f]+", x["name"]):
            raise ValueError("malformed name")
        if not isinstance(x["lastModified"], str) or not isinstance(x["contentLength"], int):
            raise ValueError("malformed inventory")
    patterns = {
        "daily/": re.compile(r"^daily/[0-9]{4}/[0-9]{2}/[0-9]{2}/openclaw-[0-9]{8}T[0-9]{6}Z\.tar\.gz$"),
        "monthly/": re.compile(r"^monthly/[0-9]{4}/[0-9]{2}/openclaw-[0-9]{4}-[0-9]{2}\.tar\.gz$"),
    }
    ranked = lambda prefix: sorted(
        (x for x in items if patterns[prefix].fullmatch(x["name"])),
        key=lambda x: (x["lastModified"], x["name"]),
        reverse=True,
    )
    keep = {x["name"] for x in ranked("daily/")[:daily] + ranked("monthly/")[:monthly]}
    managed = {x["name"] for x in items if any(pattern.fullmatch(x["name"]) for pattern in patterns.values())}
    return keep, managed - keep


class BackupRetentionTests(unittest.TestCase):
    def test_exact_seven_plus_two(self):
        items = [{"name": f"daily/2026/09/{i:02}/openclaw-202609{i:02}T000000Z.tar.gz", "lastModified": f"2026-09-{i:02}T00:00:00Z", "contentLength": i} for i in range(1, 11)]
        items += [{"name": f"monthly/2026/{i:02}/openclaw-2026-{i:02}.tar.gz", "lastModified": f"2026-{i:02}-01T00:00:00Z", "contentLength": i} for i in range(1, 4)]
        keep, delete = plan(items)
        self.assertEqual(len(keep), 9)
        self.assertEqual(len(delete), 4)
        self.assertIn("daily/2026/09/10/openclaw-20260910T000000Z.tar.gz", keep)
        self.assertIn("monthly/2026/03/openclaw-2026-03.tar.gz", keep)

    def test_blob_plan_manages_only_exact_schemas(self):
        script = (ROOT / "scripts/openclaw-prune-blob-backups.sh").read_text()
        self.assertIn(
            r'^daily/[0-9]{4}/[0-9]{2}/[0-9]{2}/openclaw-',
            script,
        )
        self.assertIn(
            r'^monthly/[0-9]{4}/[0-9]{2}/openclaw-',
            script,
        )
        self.assertIn("select(managed) | .name", script)
        self.assertIn("unmanaged-names.json", script)
        self.assertIn("expected-names.json", script)

    def test_duplicate_and_malformed_rejected(self):
        item = {"name": "daily/a", "lastModified": "2026-01-01", "contentLength": 1}
        with self.assertRaises(ValueError): plan([item, item])
        with self.assertRaises(ValueError): plan([{**item, "name": "daily/\nunsafe"}])

    def test_unrelated_and_malformed_blob_names_are_not_managed(self):
        items = [
            {"name": "daily/2026/09/21/openclaw-20260921T000000Z.tar.gz", "lastModified": "2026-09-21", "contentLength": 1},
            {"name": "daily/not-a-date/foreign.bin", "lastModified": "2026-09-22", "contentLength": 1},
            {"name": "unrelated/object", "lastModified": "2026-09-23", "contentLength": 1},
        ]
        keep, delete = plan(items, daily=1, monthly=1)
        self.assertEqual(keep, {"daily/2026/09/21/openclaw-20260921T000000Z.tar.gz"})
        self.assertEqual(delete, set())

    def test_snapshot_prefix_newest_two(self):
        names = ["openclaw-auto-weekly-20260921T000000Z", "openclaw-auto-weekly-20260914T000000Z", "openclaw-auto-weekly-20260907T000000Z", "unrelated"]
        selected = sorted((n for n in names if re.fullmatch(r"openclaw-auto-weekly-[0-9]{8}T[0-9]{6}Z", n)), reverse=True)
        self.assertEqual(selected[:2], names[:2])
        self.assertNotIn("unrelated", selected)

    def test_snapshot_runtime_fixture_rejects_wrong_source_candidate(self):
        fixture = json.loads((ROOT / "tests/fixtures/vm-snapshot-inventory.json").read_text())
        source = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/disks/os"
        valid = [
            item for item in fixture
            if re.fullmatch(r"openclaw-auto-weekly-[0-9]{8}T[0-9]{6}Z", item["name"])
            and item["provisioningState"] == "Succeeded"
            and item["incremental"] is True
            and item["sourceResourceId"].lower() == source.lower()
            and item["tags"] == {
                "purpose": "openclaw-automated-backup",
                "retention": "2",
                "createdBy": "openclaw-vm-snapshot",
            }
        ]
        self.assertEqual([item["name"] for item in valid], [fixture[0]["name"]])

    def test_bounded_housekeeping_and_headroom_contract(self):
        text = (ROOT / "scripts/openclaw-housekeeping.sh").read_text()
        self.assertIn("8 * 1024 * 1024 * 1024", text)
        self.assertIn("after_used >= 85", text)
        self.assertIn('case "$path" in', text)
        self.assertIn("allowed=1", text)
        self.assertNotIn("/var/lib/docker/volumes", text)
        self.assertNotIn("openclaw-agent.sqlite", text)

    def test_unit_ordering_and_tracked_refs(self):
        service = (ROOT / "config/openclaw-backup.service").read_text()
        drop = (ROOT / "config/drop-ins/openclaw-backup-10-housekeeping.conf").read_text()
        self.assertIn("Requires=openclaw-housekeeping.service", drop)
        self.assertIn("After=openclaw-housekeeping.service", drop)
        self.assertIn("ExecStartPost=/usr/local/sbin/openclaw-prune-blob-backups", (ROOT / "config/drop-ins/openclaw-backup-20-blob-retention.conf").read_text())
        housekeeping_service = (ROOT / "config/openclaw-housekeeping.service").read_text()
        self.assertIn("EnvironmentFile=/etc/openclaw/runtime.env", housekeeping_service)
        snapshot_service = (ROOT / "config/openclaw-vm-snapshot.service").read_text()
        self.assertIn("EnvironmentFile=/etc/openclaw/runtime.env", snapshot_service)
        self.assertIn("User=__OPENCLAW_USER__", snapshot_service)
        self.assertNotIn("/usr/local/bin/openclaw-backup", "\n".join(p.read_text() for p in (ROOT / "config").rglob("*") if p.is_file()))
        self.assertIn("openclaw-housekeeping.timer", (ROOT / "scripts/install-openclaw-runtime.sh").read_text())
        self.assertIn("all(.[]; .provisioningState == \"Succeeded\"", (ROOT / "scripts/openclaw-create-vm-snapshot.sh").read_text())

    def test_bicep_retention_parameters_reach_runtime_configuration(self):
        bicep = (ROOT / "infra/main.bicep").read_text()
        cloud_init = (ROOT / "infra/cloud-init.yaml").read_text()
        installer = (ROOT / "scripts/install-openclaw-runtime.sh").read_text()
        self.assertIn("string(dailyBackupRetention)", bicep)
        self.assertIn("string(monthlyBackupRetention)", bicep)
        self.assertIn("string(weeklySnapshotRetention)", bicep)
        self.assertIn("--daily-backup-retention, __DAILY_BACKUP_RETENTION__", cloud_init)
        self.assertIn("OPENCLAW_BACKUP_KEEP_DAILY=${daily_backup_retention}", installer)
        self.assertIn("OPENCLAW_BACKUP_KEEP_MONTHLY=${monthly_backup_retention}", installer)
        self.assertIn("OPENCLAW_SNAPSHOT_RETENTION=${weekly_snapshot_retention}", installer)

    def test_no_secret_or_live_identifier(self):
        for p in [ROOT / "infra/main.bicep", ROOT / "scripts/openclaw-prune-blob-backups.sh", ROOT / "scripts/openclaw-create-vm-snapshot.sh"]:
            text = p.read_text()
            self.assertNotRegex(
                text,
                r"(?im)^\s*(?:readonly\s+)?subscription_id=['\"][0-9a-f-]{36}['\"]",
            )
            self.assertNotRegex(text, r"-----BEGIN .*PRIVATE KEY-----")

if __name__ == "__main__":
    unittest.main()
