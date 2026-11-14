# Collects the Windows app into one self-contained folder: the exe, the Swift runtime DLLs, the version file.
# Usage: package.ps1 -Out bundle [-Version 1.2.3] [-Exe .build\release\PokeTokenBarWin.exe]
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Version = "0.0.0-dev",
    [string]$Exe = ".build\release\PokeTokenBarWin.exe"
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $Exe)) { throw "exe not found: $Exe" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Copy-Item $Exe (Join-Path $Out "PokeTokenBar.exe")
Set-Content -Path (Join-Path $Out "PokeTokenBar.version") -Value $Version -NoNewline
# Runtime DLLs sit in two folders: dispatch.dll and BlocksRuntime.dll live under Toolchains, the rest under Runtimes (F21).
$sdk = Join-Path $env:LOCALAPPDATA "Programs\Swift"
$roots = @(Get-ChildItem (Join-Path $sdk "Runtimes\*\usr\bin") -ErrorAction SilentlyContinue) +
         @(Get-ChildItem (Join-Path $sdk "Toolchains\*\usr\bin") -ErrorAction SilentlyContinue)
if (-not $roots) { throw "no Swift runtime folders under $sdk" }
foreach ($r in $roots) {
    Get-ChildItem $r.FullName -Filter *.dll | ForEach-Object {
        $dest = Join-Path $Out $_.Name
        if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest }
    }
}
Write-Host ("bundle: {0} files" -f (Get-ChildItem $Out).Count)
