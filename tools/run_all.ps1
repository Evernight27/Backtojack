# Runs the full headless check suite for BackToJack.
# Usage:
#   .\run_all.ps1             # all *_check.gd tools + sim_validate
#   .\run_all.ps1 -AllSim     # also sim_counting_systems + sim_multiseed (slow)

param([switch]$AllSim)

$godot = "E:\Godot_v4.7-stable_win64_console.exe"
$scripts = @((Get-ChildItem (Join-Path $PSScriptRoot "*_check.gd") | Sort-Object Name).Name + "sim_validate.gd")
if ($AllSim) { $scripts += @("sim_counting_systems.gd", "sim_multiseed.gd") }

$failed = @()
foreach ($s in $scripts) {
    Write-Host "== $s ==" -ForegroundColor Cyan
    & $godot --headless --script "res://tools/$s" 2>&1 |
        Where-Object { $_ -match "PASS|FAIL|failure" } |
        ForEach-Object { Write-Host "   $_" }
    if ($LASTEXITCODE -ne 0) {
        $failed += $s
        Write-Host "   (exit $LASTEXITCODE)" -ForegroundColor Red
    }
}

if ($failed.Count -eq 0) {
    Write-Host "ALL PASS ($($scripts.Count) scripts)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
