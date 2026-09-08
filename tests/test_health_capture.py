from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "scripts/openclaw-health-check.sh").read_text()
FUNCTION = SOURCE[SOURCE.index("capture_json() {"):SOURCE.index("\ngateway_ok=false")]


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "Linux capture contract")
class HealthCaptureTests(unittest.TestCase):
    def capture(self, command, seconds=3):
        with tempfile.TemporaryDirectory() as directory:
            script = (
                "set -Eeuo pipefail\nwork=\"$1\"\ncapture_max_bytes=2097152\n"
                + FUNCTION
                + f"\ncapture_json probe {seconds} bash -c \"$2\"\n"
                + "printf '%s %s\\n' \"$CAPTURE_EXIT\" \"$CAPTURE_REASON\"\n"
            )
            result = subprocess.run(["bash", "-c", script, "fixture", directory, command],
                                    capture_output=True, text=True, check=True, timeout=10)
            return result.stdout.strip()

    def test_empty_timeout_is_not_mislabeled_as_empty_success(self):
        self.assertEqual(self.capture("sleep 2", 1), "124 timeout")

    def test_nonzero_and_signal_exit_are_distinct(self):
        self.assertEqual(self.capture("exit 7"), "7 command_exit")
        self.assertEqual(self.capture("exit 137"), "137 terminated")

    def test_empty_success_and_invalid_json_are_explicit(self):
        self.assertEqual(self.capture("true"), "0 empty_output")
        self.assertEqual(self.capture("printf not-json"), "0 invalid_json")


if __name__ == "__main__":
    unittest.main()
