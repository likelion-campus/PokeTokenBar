# Picks the MSVC toolset the C/C++ targets are compiled against and exports it to the job (GITHUB_ENV), then prints the choice.
# Why: the MSVC STL refuses a clang older than it expects (yvals_core.h: _EMIT_STL_ERROR(STL1000, "... expected Clang N or newer")), and the
# clang shipped with Swift is fixed (6.3.2) while the runner image brings new Visual Studio toolsets without notice (image 20261116: a toolset
# that wants Clang 22). Clang takes the toolset from VCToolsInstallDir when it is set, else the newest. So: the newest installed toolset whose
# STL accepts THIS clang. Prints "msvc-toolset: <version> (needs clang N, have M) image <ImageVersion>"; fails when none fits.
# Writes VCToolsInstallDir, VCToolsVersion and PTB_MSVC_TOOLSET to GITHUB_ENV.
$ErrorActionPreference = 'Stop'
$clangOut = (& clang --version 2>&1 | Out-String)
$m = [regex]::Match($clangOut, 'clang version (\d+)')
if (-not $m.Success) { throw "cannot read the clang version from: $clangOut" }
$have = [int]$m.Groups[1].Value
$roots = @(Get-ChildItem (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\*\*\VC\Tools\MSVC\*') -Directory -ErrorAction SilentlyContinue)
$cands = foreach ($d in $roots) {
    $h = Join-Path $d.FullName 'include\yvals_core.h'
    if (-not (Test-Path $h)) { continue }
    $text = Get-Content $h -Raw
    # the STL's own check: "#if __clang_major__ < N" before the STL1000 error ("expected Clang N ..." in the message)
    $need = [regex]::Match($text, 'STL1000,\s*"Unexpected compiler version, expected Clang (\d+)')
    if (-not $need.Success) { $need = [regex]::Match($text, 'STL1000: Unexpected compiler version, expected Clang (\d+)') }
    if (-not $need.Success) { continue }
    [pscustomobject]@{ Dir = $d.FullName; Version = [version]$d.Name; Need = [int]$need.Groups[1].Value }
}
$all = ($cands | Sort-Object Version | ForEach-Object { "$($_.Version) (clang $($_.Need))" }) -join ', '
"msvc toolsets installed: $all; clang $have"
$pick = $cands | Where-Object { $_.Need -le $have -and $_.Version.Major -eq 14 -and $_.Version.Minor -ge 40 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pick) { throw "no MSVC toolset (14.40 or newer) accepts clang $have; installed: $all" }
$dir = $pick.Dir.TrimEnd('\') + '\'
"VCToolsInstallDir=$dir" >> $env:GITHUB_ENV
"VCToolsVersion=$($pick.Version)" >> $env:GITHUB_ENV
"PTB_MSVC_TOOLSET=$($pick.Version)" >> $env:GITHUB_ENV
$line = "msvc-toolset: $($pick.Version) (needs clang $($pick.Need), have $have) image $env:ImageVersion"
$line
if ($env:GITHUB_STEP_SUMMARY) { $line >> $env:GITHUB_STEP_SUMMARY }
