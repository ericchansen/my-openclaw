import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "scripts/openclaw-restore-verify.sh").read_text()


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "Linux shell contract")
class RestoreRecordTests(unittest.TestCase):
    def test_global_empty_agent_field_does_not_shift_snapshot_path(self):
        query = re.search(r"done < <\(jq -er '(.*?)'", SOURCE)[1]
        read = re.search(r"while (IFS=.*?read -r role agent_id relative); do", SOURCE)[1]
        for record, expected in (
            ({"role": "global", "path": "sqlite/global-snapshot"},
             ["global", "", "sqlite/global-snapshot"]),
            ({"role": "agent", "agentId": "fixture", "path": "sqlite/agent-snapshot"},
             ["agent", "fixture", "sqlite/agent-snapshot"]),
        ):
            with self.subTest(role=record["role"]):
                row = subprocess.run(
                    ["jq", "-er", query], input=json.dumps({"sqliteSnapshots": [record]}),
                    text=True, capture_output=True, check=True).stdout
                result = subprocess.run(
                    ["bash", "-c", read + '; printf "%s\\n" "$role" "$agent_id" "$relative"'],
                    input=row, text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.splitlines(), expected)


if __name__ == "__main__":
    unittest.main()
