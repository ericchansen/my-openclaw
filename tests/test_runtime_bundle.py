import base64
import hashlib
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "runtime_bundle", Path(__file__).resolve().parents[1] / "scripts/build-runtime-bundle.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeBundleTests(unittest.TestCase):
    def test_xz_cli_is_deterministic_checked_and_extractable_by_system_tar(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "runtime.sh"
            source.write_bytes(b"#!/bin/sh\r\nprintf ready\r\n")
            bundle = root / "runtime.tar.xz.b64"
            command = [sys.executable, str(Path(MODULE.__file__)), "--output", str(bundle), str(source)]
            subprocess.run(command, check=True, capture_output=True)
            encoded = bundle.read_bytes()
            compressed = base64.b64decode(encoded, validate=True)
            self.assertEqual(lzma.decompress(compressed), MODULE.archive_bytes([source]))
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(bundle.read_bytes(), encoded)
            subprocess.run(command + ["--check"], check=True, capture_output=True)
            archive = root / "runtime.tar.xz"
            archive.write_bytes(compressed)
            extracted = subprocess.run(
                ["tar", "-xJOf", str(archive), "runtime.sh"], check=True, capture_output=True,
            ).stdout
            self.assertEqual(extracted, b"#!/bin/sh\nprintf ready\n")
            source.write_bytes(b"changed\n")
            stale = subprocess.run(command + ["--check"], capture_output=True, text=True)
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("runtime bundle is stale", stale.stderr)

    def test_cloud_init_declares_xz_dependency_and_base64_transport(self):
        root = Path(__file__).resolve().parents[1]
        config = (root / "infra" / "cloud-init.yaml").read_text()
        self.assertIn("packages:\n  - xz-utils", config)
        self.assertIn("encoding: base64", config)
        self.assertIn("__RUNTIME_BUNDLE_XZ_B64__", config)
        self.assertIn("[tar, -xJf, /opt/openclaw/runtime-assets.tar.xz", config)
        self.assertNotIn("encoding: gzip+base64", config)

    def test_sorted_flat_regular_archive_preserves_normalized_content(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = Path(directory) / "first.sh", Path(directory) / "second.service"
            first.write_bytes(b"#!/bin/sh\r\nexit 0\r\n")
            second.write_bytes(b"[Unit]\n")
            data = MODULE.archive_bytes([second, first])
            self.assertEqual(data, MODULE.archive_bytes([first, second]))
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                self.assertEqual(archive.getnames(), ["first.sh", "second.service"])
                for member in archive:
                    self.assertTrue(member.isfile())
                    self.assertEqual(member.uid, 0)
                    self.assertEqual(member.gid, 0)
                    self.assertEqual(member.mtime, 0)
                    self.assertEqual(member.mode, 0o644)
                self.assertEqual(archive.extractfile("first.sh").read(), b"#!/bin/sh\nexit 0\n")

    def test_duplicate_names_and_missing_sources_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing"
            with self.assertRaises(ValueError):
                MODULE.archive_bytes([missing])
            with self.assertRaises(ValueError):
                MODULE.archive_bytes([missing, missing])

    @unittest.skipUnless(sys.platform == "linux", "Root staging uses Linux ownership")
    def test_remote_staging_rejects_untrusted_paths_and_changed_bundles(self):
        prefix = []
        if os.geteuid() != 0:
            if not shutil.which("sudo") or subprocess.run(
                ["sudo", "-n", "true"], capture_output=True
            ).returncode:
                self.skipTest("Root ownership checks require passwordless sudo")
            prefix = ["sudo", "-n"]
        apply = (Path(MODULE.__file__).parent / "apply-runtime.ps1").read_text()
        program = re.search(r"\$stageProgram = @'\n(.*?)\n'@", apply, re.DOTALL)[1]
        bundle = Path(MODULE.__file__).parents[1] / "infra/runtime-assets.tar.xz.b64"
        digest = hashlib.sha256(base64.b64decode(bundle.read_bytes())).hexdigest()
        driver = r"""
import base64, hashlib, io, json, os, pathlib, pwd, stat, subprocess, sys, tarfile, tempfile
program, encoded, digest = json.loads(sys.stdin.read())
with tempfile.TemporaryDirectory(prefix="openclaw-stage-test-", dir=pwd.getpwuid(0).pw_dir) as folder:
    root = pathlib.Path(folder) / "runtime"
    code = program.replace('Path("/var/lib/openclaw-runtime")', "Path(" + repr(str(root)) + ")")
    def run(payload=encoded, expected=digest):
        return subprocess.run([sys.executable, "-c", code, expected],
                              input=payload, text=True, capture_output=True)
    bad = run(expected="0" * 64)
    assert bad.returncode != 0 and not list(root.glob("apply-*"))
    result = run()
    assert result.returncode == 0, result.stderr
    stage = pathlib.Path(result.stdout.strip())
    assert stage.parent == root and stage.stat().st_uid == 0
    assert stat.S_IMODE(stage.stat().st_mode) == 0o700
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(encoded)), mode="r:xz") as archive:
        for item in archive:
            path = stage / item.name
            assert path.stat().st_uid == 0 and stat.S_IMODE(path.stat().st_mode) == 0o400
            assert path.read_bytes() == archive.extractfile(item).read()
    os.chmod(root, 0o777)
    assert run().returncode != 0
    os.chmod(root, 0o755)
    real = root.with_name("real")
    root.rename(real)
    root.symlink_to(real, target_is_directory=True)
    assert run().returncode != 0
    root.unlink()
    real.rename(root)
    for name, kind in (("../escape", tarfile.REGTYPE), ("linked", tarfile.SYMTYPE)):
        content = io.BytesIO()
        with tarfile.open(fileobj=content, mode="w:xz") as archive:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.linkname = "/bin/sh" if kind == tarfile.SYMTYPE else ""
            archive.addfile(item)
        payload = content.getvalue()
        assert run(base64.b64encode(payload).decode(), hashlib.sha256(payload).hexdigest()).returncode != 0
    assert len(list(root.glob("apply-*"))) == 1
print("root staging verified")
"""
        result = subprocess.run(
            [*prefix, sys.executable, "-c", driver],
            input=json.dumps([program, bundle.read_text(), digest]),
            text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("root staging verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
