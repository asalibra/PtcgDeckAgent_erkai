param(
	[string]$GodotExe = "",
	[string]$UserDataRoot = "",
	[string[]]$Suites = @(
		"res://tests/test_battle_replay_locator.gd",
		"res://tests/test_battle_replay_controller.gd",
		"res://tests/test_battle_replay_snapshot_loader.gd",
		"res://tests/test_match_record_index.gd",
		"res://tests/test_net_lobby_replay_regression.gd",
		"res://tests/test_battle_ui_features.gd"
	)
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runnerScript = Join-Path $scriptRoot "run_godot_tests.ps1"

if (-not (Test-Path -LiteralPath $runnerScript)) {
	throw "Replay regression runner dependency not found: $runnerScript"
}

$results = @()

foreach ($suiteScript in $Suites) {
	Write-Host "=== Replay regression: $suiteScript ==="
	$invokeArgs = @{
		Runner = "focused"
		SuiteScript = $suiteScript
	}
	if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
		$invokeArgs["GodotExe"] = $GodotExe
	}
	if (-not [string]::IsNullOrWhiteSpace($UserDataRoot)) {
		$invokeArgs["UserDataRoot"] = $UserDataRoot
	}

	& $runnerScript @invokeArgs
	$exitCode = $LASTEXITCODE
	$results += [PSCustomObject]@{
		Suite = $suiteScript
		ExitCode = $exitCode
	}
	if ($exitCode -ne 0) {
		Write-Host "Replay regression failed at $suiteScript" -ForegroundColor Red
		break
	}
}

Write-Host ""
Write-Host "=== Replay regression summary ==="
foreach ($result in $results) {
	$label = if ($result.ExitCode -eq 0) { "PASS" } else { "FAIL" }
	Write-Host ("{0} {1}" -f $label.PadRight(4), $result.Suite)
}

$failed = @($results | Where-Object { $_.ExitCode -ne 0 })
if ($failed.Count -gt 0) {
	exit 1
}

exit 0