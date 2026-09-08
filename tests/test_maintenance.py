import os
import pathlib
import re
import shutil
import subprocess
import sys
import unittest
import uuid

if sys.platform == "linux":
    import fcntl


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
INSTALLER = (SCRIPTS / "install-openclaw-runtime.sh").read_text()
UPDATER = (SCRIPTS / "openclaw-update.sh").read_text()
BACKUP = (SCRIPTS / "openclaw-backup.sh").read_text()


def lock_block(source):
    start = source.index("maintenance_lock=/etc/openclaw/maintenance.lock")
    end_marker = "export OPENCLAW_MAINTENANCE_LOCK_HELD=1"
    end = source.index(end_marker, start) + len(end_marker)
    return source[start:end] + "\n"


class MaintenanceOrderingTests(unittest.TestCase):
    def test_active_installer_delegates_before_live_mutation(self):
        delegate = INSTALLER.index('exec bash "$asset_dir/openclaw-update.sh"')
        for mutation in (
            "\nensure_merged_lib64\n",
            "\napt-get update\n",
            '\n  install_otel_collector\n',
            'npm install --global --omit=dev "openclaw@',
            'cat > /etc/openclaw/runtime.env',
            'install -m 0755 "$asset_dir/openclaw-backup.sh"',
            '> "/etc/systemd/system/$unit"',
            "systemctl daemon-reload",
            "systemctl restart openclaw-backup.timer",
        ):
            with self.subTest(mutation=mutation):
                self.assertLess(delegate, INSTALLER.index(mutation))
        self.assertIn('--runtime-installer "$installer_path"', INSTALLER)
        self.assertIn('[[ "$inherited_maintenance_lock" == true ]]', INSTALLER)

    def test_update_preflight_and_callback_order(self):
        stop = UPDATER.index("\ngateway_stopped=true\nsystemctl stop")
        for validation in (
            'expected_package_root="${global_prefix}/lib/node_modules/openclaw"',
            "openclaw backup verify",
            'verify_registry_pin openclaw "$target_version"',
            'openclaw update status --json',
            'for service in openclaw-backup.service openclaw-health.service',
            '\nbash "$sandbox_provisioner"',
        ):
            with self.subTest(validation=validation):
                self.assertLess(UPDATER.index(validation), stop)
        callback = UPDATER.index(
            'OPENCLAW_INSTALL_PHASE=stopped bash "$runtime_installer"'
        )
        self.assertLess(stop, UPDATER.index('npm install --global --prefix'))
        self.assertLess(UPDATER.index('openclaw config validate --json'), callback)
        self.assertLess(UPDATER.index('openclaw doctor --lint --json'), callback)
        self.assertLess(callback, UPDATER.index("\nsystemctl start openclaw-gateway.service"))
        ready = UPDATER.index("\nupdate_succeeded=true\n")
        unlock = UPDATER.index("\nflock --unlock 8\n", ready)
        self.assertLess(
            unlock, UPDATER.index("systemctl start openclaw-backup.timer", ready)
        )

    def test_only_own_timers_are_paused_and_no_service_is_killed_for_drain(self):
        drain = UPDATER.split("# Stop only our timers.", 1)[1].split(
            '\nbash "$sandbox_provisioner"', 1
        )[0]
        self.assertIn("openclaw-backup.timer openclaw-health.timer", drain)
        self.assertNotIn("systemctl stop \"$service\"", drain)
        self.assertNotIn("docker", drain)
        self.assertNotIn("kill", drain)
        self.assertIn("SECONDS < deadline", drain)

    def test_fresh_install_releases_lock_before_starting_timers(self):
        finish = INSTALLER.split(
            "\nsystemctl enable openclaw-backup.timer openclaw-health.timer\n", 1
        )[1]
        self.assertIn('if [[ "$install_stopped_runtime" != true ]]; then', finish)
        self.assertLess(finish.index("flock --unlock 8"), finish.index("systemctl restart"))

    def test_canary_helper_and_private_workspace_are_provisioned(self):
        required = re.search(r"required_assets=\((.*?)\n\)", INSTALLER, re.DOTALL)[1].split()
        self.assertIn("openclaw-availability-check.py", required)
        self.assertIn(
            'install -o root -g root -m 0555 \\\n'
            '  "$asset_dir/openclaw-availability-check.py" \\\n'
            "  /usr/local/libexec/openclaw-availability-check",
            INSTALLER,
        )
        self.assertIn(
            'healthcheck_workspace="${openclaw_state_dir}/workspace-healthcheck"',
            INSTALLER,
        )
        self.assertIn(
            'install -d -o "$openclaw_user" -g "$openclaw_user" -m 0700 "$healthcheck_workspace"',
            INSTALLER,
        )
        self.assertIn('for directory in "$openclaw_state_dir" "$healthcheck_workspace"', INSTALLER)
        self.assertIn('! -L "$directory"', INSTALLER)


@unittest.skipUnless(
    sys.platform == "linux" and shutil.which("bash") and shutil.which("flock"),
    "Executable flock regression tests require Linux, bash, and util-linux",
)
class MaintenanceExecutionTests(unittest.TestCase):
    def setUp(self):
        self.scratch = ROOT / ".repository-test-runtime" / f"maintenance-{uuid.uuid4().hex}"
        self.scratch.mkdir(parents=True)
        self.lock = self.scratch / "etc" / "maintenance.lock"
        self.lock.parent.mkdir()
        self.lock.write_text("")
        self.lock.chmod(0o644)
        self.events = self.scratch / "events"
        self.environment = os.environ.copy()
        self.environment.pop("OPENCLAW_MAINTENANCE_LOCK_HELD", None)
        self.environment.pop("OPENCLAW_INSTALL_PHASE", None)
        self.environment.update(
            TEST_EVENTS=str(self.events),
            TEST_ROOT=str(self.scratch),
            OPENCLAW_BACKUP_ACCOUNT="testaccount",
            OPENCLAW_BACKUP_CONTAINER="testcontainer",
            STATE_DIRECTORY=str(self.scratch / "state"),
        )

    def tearDown(self):
        shutil.rmtree(self.scratch)

    def fixture_script(self, name, body):
        # Only OS ownership/installation are mocked, allowing unprivileged WSL
        # runs on a Windows checkout. flock, descriptors and traps are real.
        prelude = """#!/usr/bin/env bash
set -Eeuo pipefail
install() { mkdir -p -- "${@: -1}"; }
stat() {
  if [[ "$1" == -c && "$2" == '%u:%g:%a:%h' ]]; then
    printf '%s\\n' "${TEST_LOCK_METADATA:-0:0:644:1}"
  else
    command stat "$@"
  fi
}
"""
        path = self.scratch / name
        path.write_text(
            prelude + body.replace("/etc/openclaw", str(self.lock.parent)),
            encoding="utf-8",
        )
        return path

    def run_script(self, path, **environment):
        return subprocess.run(
            ["bash", str(path)],
            env={**self.environment, **environment},
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def test_shared_reader_blocks_both_maintenance_writers(self):
        with self.lock.open("r") as reader:
            fcntl.flock(reader, fcntl.LOCK_SH | fcntl.LOCK_NB)
            for source, name in ((INSTALLER, "install"), (UPDATER, "update")):
                with self.subTest(writer=name):
                    path = self.fixture_script(
                        name, lock_block(source) + 'printf mutated > "$TEST_ROOT/mutated"\n'
                    )
                    result = self.run_script(path)
                    self.assertEqual(result.returncode, 75, result.stderr)
                    self.assertFalse((self.scratch / "mutated").exists())

    def test_exclusive_maintenance_skips_backup_without_changing_status(self):
        state = self.scratch / "state"
        state.mkdir()
        status = state / "backup-status.json"
        status.write_text('{"result":"succeeded","timestamp":"existing"}')
        before = status.read_bytes()
        path = self.fixture_script("backup", BACKUP)
        with self.lock.open("r") as writer:
            fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"reason":"maintenance"', result.stdout)
        self.assertEqual(status.read_bytes(), before)
        self.assertFalse((state / "backup-work").exists())

    def test_backup_shared_gate_allows_another_reader(self):
        gate = BACKUP.split("maintenance_lock=", 1)[1].split("runtime_root=", 1)[0]
        path = self.fixture_script("reader", "maintenance_lock=" + gate + "echo acquired\n")
        with self.lock.open("r") as reader:
            fcntl.flock(reader, fcntl.LOCK_SH | fcntl.LOCK_NB)
            result = self.run_script(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "acquired")

    def test_missing_unsafe_and_symlink_locks_fail_closed(self):
        path = self.fixture_script("backup", BACKUP)
        self.lock.unlink()
        result = self.run_script(path)
        self.assertEqual(result.returncode, 78, result.stderr)
        self.lock.write_text("")
        result = self.run_script(path, TEST_LOCK_METADATA="1000:1000:666:1")
        self.assertEqual(result.returncode, 78, result.stderr)
        target = self.scratch / "target"
        target.write_text("")
        self.lock.unlink()
        self.lock.symlink_to(target)
        result = self.run_script(path)
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertFalse((self.scratch / "state").exists())

    def test_lock_errors_are_not_reported_as_contention(self):
        for source, name in (
            (BACKUP, "backup"),
            (lock_block(INSTALLER), "install"),
            (lock_block(UPDATER), "update"),
        ):
            with self.subTest(caller=name):
                path = self.fixture_script(name, "flock() { return 70; }\n" + source)
                result = self.run_script(path)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertNotIn("backup_skipped", result.stdout)
                self.assertNotIn("already running", result.stderr)

    def test_nested_installer_updater_callback_inherits_exclusive_lock(self):
        callback = self.fixture_script(
            "callback",
            lock_block(INSTALLER)
            + """
exec 7<"$maintenance_lock"
if flock --shared --nonblock 7; then exit 99; fi
echo callback-under-exclusive-lock
""",
        )
        update = self.fixture_script(
            "update", lock_block(UPDATER) + f'bash "{callback}"\n'
        )
        install = self.fixture_script(
            "install", lock_block(INSTALLER) + f'bash "{update}"\n'
        )
        inode = self.lock.stat().st_ino
        for _ in range(2):
            result = self.run_script(install)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("callback-under-exclusive-lock", result.stdout)
            self.assertEqual(self.lock.stat().st_ino, inode)

    def test_inheritance_marker_without_descriptor_is_rejected(self):
        path = self.fixture_script("update", lock_block(UPDATER) + "echo mutated\n")
        result = self.run_script(path, OPENCLAW_MAINTENANCE_LOCK_HELD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mutated", result.stdout)

    def test_active_installer_delegates_under_lock_without_touching_runtime(self):
        assets = self.scratch / "assets"
        assets.mkdir()
        names = re.search(r"required_assets=\((.*?)\n\)", INSTALLER, re.DOTALL)[1].split()
        for name in names:
            source = SCRIPTS / name
            if not source.exists():
                source = ROOT / "config" / name
            shutil.copyfile(source, assets / name)
        updater = assets / "openclaw-update.sh"
        updater.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${OPENCLAW_MAINTENANCE_LOCK_HELD:-}" == 1 ]]
exec 7<"$TEST_ROOT/etc/maintenance.lock"
if flock --shared --nonblock 7; then exit 99; fi
printf '%s\\n' "$@" > "$TEST_EVENTS"
exit 78
"""
        )
        home = self.scratch / "home"
        home.mkdir()
        original_runtime = self.scratch / "working-runtime"
        original_runtime.write_text("last-known-good")
        prefix = INSTALLER.split("\nensure_merged_lib64() {", 1)[0]
        prefix = prefix.replace("if [[ $EUID -ne 0 ]]; then", "if false; then", 1)
        setup = """
id() { return 0; }
getent() { printf 'runtime:x:1000:1000::%s/home:/bin/bash\\n' "$TEST_ROOT"; }
systemctl() { [[ "$*" == 'is-active --quiet openclaw-gateway.service' ]]; }
node() { echo v22.22.0; }
"""
        path = self.fixture_script(
            "installer-prefix", setup + prefix + "\necho LIVE_MUTATION_REACHED\nexit 99\n"
        )
        args = {
            "asset-dir": assets,
            "user": "runtime",
            "key-vault": "test-vault",
            "storage-account": "testaccount",
            "openclaw-version": "2026.9.1",
            "diagnostics-otel-version": "2026.9.1",
            "node-version": "22.22.0",
            "otel-version": "0.160.0",
            "copilot-version": "1.0.1",
            "mcp-ebird-version": "1.0.1",
            "mcp-pondlog-version": "1.0.1",
            "node-sha256": "a" * 64,
            "otel-url": "https://example.invalid/collector",
            "otel-sha256": "b" * 64,
            "sandbox-source-commit": "c" * 40,
            "sandbox-archive-url": "https://example.invalid/source",
            "sandbox-archive-sha256": "d" * 64,
            "sandbox-browser-contract": "reviewed",
            "verified-backup": self.scratch / "backup.tar.gz",
            "snapshot-evidence": "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/snapshots/test",
        }
        for name in (
            "openclaw", "diagnostics-otel", "copilot", "mcp-ebird", "mcp-pondlog"
        ):
            args[f"{name}-integrity"] = "sha512-YWJj"
        command = ["bash", str(path)]
        for key, value in args.items():
            command.extend([f"--{key}", str(value)])
        result = subprocess.run(
            command, env=self.environment, capture_output=True, text=True, timeout=15
        )
        self.assertEqual(result.returncode, 78, result.stderr)
        delegated = self.events.read_text().splitlines()
        self.assertIn("--runtime-installer", delegated)
        self.assertIn("--sandbox-provisioner", delegated)
        self.assertEqual(delegated[delegated.index("--") + 1 :], command[2:])
        self.assertNotIn("LIVE_MUTATION_REACHED", result.stdout)
        self.assertEqual(original_runtime.read_text(), "last-known-good")

    def lifecycle_script(self, after=""):
        begin = UPDATER.index("\ngateway_stopped=false\n")
        end_marker = "\npackage_ownership_captured=true\n"
        end = UPDATER.index(end_marker, begin) + len(end_marker)
        lifecycle = UPDATER[begin:end].replace(
            'bash "$sandbox_provisioner"', "provision_sandbox_images"
        )
        setup = """
artifact_dir="$TEST_ROOT/evidence"
drain_timeout=0
sandbox_source_commit=unused
sandbox_archive_url=unused
sandbox_archive_sha256=unused
target_version=2026.9.1
sandbox_browser_contract=unused
systemctl() {
  printf '%s\\n' "$*" >> "$TEST_EVENTS"
  case "$1" in
    is-active) return 0 ;;
    show)
      if [[ "$TEST_SCENARIO" == busy && "$2" == openclaw-backup.service ]]; then
        echo active
      else
        echo inactive
      fi
      ;;
    start)
      exec 7<"$maintenance_lock"
      flock --shared --nonblock 7 || return 99
      echo timer-restored-after-unlock >> "$TEST_EVENTS"
      exec 7<&-
      ;;
  esac
}
provision_sandbox_images() {
  echo provision >> "$TEST_EVENTS"
  [[ "$TEST_SCENARIO" != invalid-image ]] || return 42
}
"""
        return self.fixture_script("lifecycle", lock_block(UPDATER) + setup + lifecycle + after)

    def test_busy_legacy_backup_preserves_gateway_and_restores_timers(self):
        result = self.run_script(self.lifecycle_script(), TEST_SCENARIO="busy")
        self.assertEqual(result.returncode, 75, result.stderr)
        events = self.events.read_text()
        self.assertIn("stop openclaw-backup.timer", events)
        self.assertIn("timer-restored-after-unlock", events)
        self.assertNotIn("stop openclaw-gateway.service", events)
        self.assertNotIn("stop openclaw-backup.service", events)
        self.assertNotIn("provision", events)

    def test_invalid_image_preserves_gateway_and_restores_timers(self):
        result = self.run_script(self.lifecycle_script(), TEST_SCENARIO="invalid-image")
        self.assertEqual(result.returncode, 42, result.stderr)
        events = self.events.read_text()
        self.assertIn("provision", events)
        self.assertIn("timer-restored-after-unlock", events)
        self.assertNotIn("stop openclaw-gateway.service", events)

    def test_post_shutdown_failure_keeps_gateway_and_timers_stopped(self):
        path = self.lifecycle_script("\npackage_ownership_captured=false\nexit 42\n")
        result = self.run_script(path, TEST_SCENARIO="post-shutdown-failure")
        self.assertEqual(result.returncode, 42, result.stderr)
        events = self.events.read_text()
        self.assertIn("stop openclaw-gateway.service", events)
        self.assertNotIn("start openclaw-", events)
        self.assertIn("Gateway remains stopped", result.stderr)

    @unittest.skipUnless(shutil.which("jq"), "Doctor result validation requires jq")
    def test_doctor_only_accepts_success_and_warning_exits(self):
        start = UPDATER.index("set +e\nrun_as_openclaw timeout", UPDATER.index("openclaw config validate --json"))
        gate = UPDATER[start:UPDATER.index("\nassert_runtime_state_owned", start)]
        path = self.fixture_script("doctor-gate", """
artifact_dir="$TEST_ROOT"
run_as_openclaw() {
  printf '%s\\n' "$TEST_DOCTOR_JSON"
  return "$TEST_DOCTOR_EXIT"
}
""" + gate + "\necho accepted\n")
        for code in (0, 1, 2, 3, 70, 78, 124, 137, 143, 255):
            with self.subTest(exit=code):
                result = self.run_script(path, TEST_DOCTOR_EXIT=str(code),
                                         TEST_DOCTOR_JSON='{"ok":true,"findings":[]}')
                self.assertEqual(result.returncode, 0 if code in (0, 1) else 78, result.stderr)
                self.assertEqual("accepted" in result.stdout, code in (0, 1))
        for payload in ('not-json', '{"findings":[{"severity":"error"}]}'):
            result = self.run_script(path, TEST_DOCTOR_EXIT="0", TEST_DOCTOR_JSON=payload)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("accepted", result.stdout)


if __name__ == "__main__":
    unittest.main()
