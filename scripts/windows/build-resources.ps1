# Compiles Sources\PokeTokenBarWin\PokeTokenBar.rc into <Out>\PokeTokenBar.res (version info, icon, manifest) and prints the
# absolute path of the .res on its last line, to pass to the link as `-Xlinker <path>`.
# The version is the Mac's single source (scripts/build-app.sh VERSION="x.y.z") unless -Version is given.
# Usage: build-resources.ps1 [-Out resources] [-Version 2.5.634]
param([string]$Out = "resources", [string]$Version = "")
$ErrorActionPreference = "Stop"
if (-not $Version) {
    $m = [regex]::Match((Get-Content scripts\build-app.sh -Raw), '(?m)^VERSION="(\d+\.\d+\.\d+)"')
    if (-not $m.Success) { throw 'no VERSION="x.y.z" in scripts\build-app.sh' }
    $Version = $m.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "version must be x.y.z, got '$Version'" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$parts = $Version.Split('.')
Set-Content -Path (Join-Path $Out "ptb-version.rci") -Encoding ascii -Value @(
    "#define PTB_VERSION_COMMA $($parts[0]),$($parts[1]),$($parts[2]),0",
    "#define PTB_VERSION_TEXT ""$Version.0"""
)
$rc = Get-Command rc.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $rc) {
    $rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $rc) { throw "rc.exe not found (Windows SDK)" }
$res = Join-Path $Out "PokeTokenBar.res"
Write-Host "rc: $rc  version: $Version"
& $rc /nologo /I $Out /fo $res Sources\PokeTokenBarWin\PokeTokenBar.rc
if ($LASTEXITCODE -ne 0) { throw "rc.exe failed ($LASTEXITCODE)" }
Write-Host ("PASS resources: {0} ({1} bytes)" -f $res, (Get-Item $res).Length)
$res
