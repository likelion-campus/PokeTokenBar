# Fetch the FIXTURE sprites listed in scripts/fixture-sprites.txt into -Out (stage 7 Task 9: the companion header's selftest
# captures and idle probes read them through PTB_SELFTEST_SPRITES, so the app itself asks no network). Public PokeAPI sprite
# files only. A file that cannot be fetched is reported and skipped (the capture then shows what the Mac shows offline: 🥚).
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$list = Join-Path $PSScriptRoot '..\fixture-sprites.txt'
$missing = @()
foreach ($line in Get-Content $list) {
    if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
    $file, $url = $line -split '\s+', 2
    $dest = Join-Path $Out $file
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { continue }
    $ok = $false
    foreach ($try in 1..3) {
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30; $ok = $true; break } catch { Start-Sleep -Seconds (2 * $try) }
    }
    if (-not $ok) { $missing += $file }
}
"fixture sprites: $((Get-ChildItem $Out).Count) files in $Out; missing: $($missing -join ', ')"
