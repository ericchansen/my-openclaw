import os
from pathlib import Path
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required; exercised in Linux CI")
class ValidationRunnerTests(unittest.TestCase):
    def test_warning_exit_does_not_fail_ci_or_hide_failed_checks(self):
        runner = Path(__file__).resolve().parents[1] / "scripts/test-repository.ps1"
        script = r"""
$ErrorActionPreference = "Stop"
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($env:RUNNER, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Runner syntax error" }
$statements = $ast.EndBlock.Statements
if ($statements[-1] -isnot [Management.Automation.Language.ExitStatementAst]) {
    throw "Runner needs an explicit success exit after its failure guard"
}
$failures = [Collections.Generic.List[string]]::new()
if ($env:FAILED_CHECK -eq "1") { $failures.Add("fixture check failed") }
$global:LASTEXITCODE = 1
. ([scriptblock]::Create(($statements[-3..-1].Extent.Text -join "`n")))
"""
        for failed, expected in (("0", 0), ("1", 1)):
            with self.subTest(failed_check=failed):
                result = subprocess.run(
                    ["pwsh", "-NoProfile", "-Command", script],
                    env={**os.environ, "RUNNER": str(runner), "FAILED_CHECK": failed},
                    capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
