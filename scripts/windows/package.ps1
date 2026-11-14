# Collects the Windows app into one self-contained folder: the exe, the DLLs it needs, the version file and the licences.
#
# The DLL set is the dependency closure of the exe, read with `dumpbin /dependents` recursively (not "every DLL in the
# toolchain"). Each import is resolved in this order:
#   1. Visual C++ runtime (vcruntime140*, msvcp140*, ...)  -> the Visual Studio redist folder (not System32)
#   2. a Windows DLL (api-ms-win-*, or present in System32) -> the OS provides it, nothing is shipped
#   3. a file in the Swift SDK (Runtimes\*\usr\bin and Toolchains\*\usr\bin; dispatch.dll and BlocksRuntime.dll are in the
#      latter, F21)                                         -> shipped
#   anything else -> exit 1 ("no source"). A shipped DLL must match a line of windows\licenses\map.txt -> else exit 1.
# Also fails when the bundled exe is not named like WindowsInstall.shippedExecutableName, when an OpenSSL DLL would ship
# (OpenSSL is linked statically), or when the exe lacks the version resource for -Version.
# Usage: package.ps1 -Out bundle [-Version 2.5.634] [-Exe .build\release\PokeTokenBarWin.exe]
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$Version = "",
    [string]$Exe = ".build\release\PokeTokenBarWin.exe"
)
$ErrorActionPreference = "Stop"
if (-not $Version) {
    $m = [regex]::Match((Get-Content scripts\build-app.sh -Raw), '(?m)^VERSION="(\d+\.\d+\.\d+)"')
    if (-not $m.Success) { throw 'no VERSION="x.y.z" in scripts\build-app.sh' }
    $Version = $m.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "version must be x.y.z, got '$Version'" }
if (-not (Test-Path $Exe)) { throw "exe not found: $Exe" }
$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$message) { Write-Host "FAIL package: $message"; $failures.Add($message) }

# The exe name is frozen in Swift (the settings plist is named after the process); read it from there.
$m = [regex]::Match((Get-Content Sources\PokeTokenBar\Platform\Windows\WindowsInstall.swift -Raw), 'shippedExecutableName\s*=\s*"([^"]+)"')
if (-not $m.Success) { throw "shippedExecutableName not found in WindowsInstall.swift" }
$exeName = $m.Groups[1].Value
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
Copy-Item $Exe (Join-Path $Out $exeName)
Set-Content -Path (Join-Path $Out "PokeTokenBar.version") -Value $Version -NoNewline
$bundleExes = @(Get-ChildItem $Out -Filter *.exe)
if ($bundleExes.Count -ne 1 -or $bundleExes[0].Name -cne $exeName) { Fail "the bundle's exe is '$($bundleExes.Name -join ',')', expected '$exeName'" }
else { Write-Host "PASS exe name: $exeName" }
$fv = (Get-Item (Join-Path $Out $exeName)).VersionInfo
if ($fv.FileVersion -ne "$Version.0" -or $fv.FileDescription -ne "PokeTokenBar") {
    Fail "exe version resource is FileVersion='$($fv.FileVersion)' FileDescription='$($fv.FileDescription)', expected '$Version.0' / 'PokeTokenBar' (was the .res linked?)"
} else { Write-Host "PASS version resource: FileVersion=$($fv.FileVersion) FileDescription=$($fv.FileDescription)" }

# --- tools and source folders
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = if (Test-Path $vswhere) { & $vswhere -latest -products * -property installationPath } else { $null }
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $dumpbin -and $vsPath) {
    $dumpbin = Get-ChildItem (Join-Path $vsPath "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe") -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $dumpbin) { throw "dumpbin.exe not found (Visual Studio $vsPath)" }
$redist = $null
if ($vsPath) {
    $redist = Get-ChildItem (Join-Path $vsPath "VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'onecore|debug_nonredist' } | Sort-Object FullName -Descending | Select-Object -First 1
}
Write-Host "dumpbin: $dumpbin"
Write-Host "VC redist: $(if ($redist) { $redist.FullName } else { '(not found)' })"
$sdk = Join-Path $env:LOCALAPPDATA "Programs\Swift"
$swiftDirs = @(Get-ChildItem (Join-Path $sdk "Runtimes\*\usr\bin") -ErrorAction SilentlyContinue) +
             @(Get-ChildItem (Join-Path $sdk "Toolchains\*\usr\bin") -ErrorAction SilentlyContinue)
if (-not $swiftDirs) { throw "no Swift runtime folders under $sdk" }
$system32 = Join-Path $env:windir "System32"
$vcPattern = '^(vcruntime140.*|msvcp140.*|concrt140|vccorlib140|vcomp140)\.dll$'

function Find-In($dirs, [string]$name) {
    foreach ($d in $dirs) { $p = Join-Path $d.FullName $name; if (Test-Path $p) { return $p } }
    return $null
}
function Imports([string]$file) {
    $text = (& $dumpbin /nologo /dependents $file) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $file" }
    [regex]::Matches($text, '(?m)^\s+([\w\.\-\+]+\.dll)\s*$', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique
}

# --- closure
$shipped = [ordered]@{}   # lower-case name -> @{ Name; Source; Origin }
$os = [System.Collections.Generic.SortedSet[string]]::new()
$queue = New-Object System.Collections.Queue
$queue.Enqueue((Join-Path $Out $exeName))
$seen = @{}
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($dep in (Imports $file)) {
        if ($seen.ContainsKey($dep)) { continue }
        $seen[$dep] = $true
        if ($dep -match $vcPattern) {
            $src = if ($redist) { Join-Path $redist.FullName $dep } else { $null }
            if ($src -and (Test-Path $src)) { $origin = "Visual C++ redist" } else { Fail "$dep (imported by $(Split-Path $file -Leaf)): not in the Visual C++ redist folder"; continue }
        }
        elseif ($dep -like 'api-ms-win-*' -or $dep -like 'ext-ms-*' -or (Test-Path (Join-Path $system32 $dep))) { [void]$os.Add($dep); continue }
        else {
            $src = Find-In $swiftDirs $dep
            if (-not $src) { $src = Get-ChildItem $swiftDirs.FullName -Filter $dep -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
            if (-not $src) { Fail "$dep (imported by $(Split-Path $file -Leaf)): not an OS DLL and no source in the Swift SDK or the VC redist"; continue }
            $origin = "Swift SDK $((Split-Path $src -Parent).Substring($sdk.Length + 1))"
        }
        $dest = Join-Path $Out (Split-Path $src -Leaf)
        Copy-Item $src $dest
        $shipped[$dep] = @{ Name = (Split-Path $src -Leaf); Source = $src; Origin = $origin }
        $queue.Enqueue($dest)
    }
}
"OS DLLs the closure uses (not shipped): $($os -join ', ')"

# --- OpenSSL is linked statically: no OpenSSL DLL may ship
$ssl = @($shipped.Values | Where-Object { $_.Name -match '^(libssl|libcrypto|ssleay|libeay)' })
if ($ssl) { Fail "an OpenSSL DLL would ship: $($ssl.Name -join ', ')" } else { Write-Host "PASS no OpenSSL DLL in the closure (OpenSSL is linked statically)" }

# --- licences
$licenseDir = Join-Path $Out "licenses"
New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
$map = Get-Content windows\licenses\map.txt | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
    $f = $_ -split "`t"
    if ($f.Count -lt 3) { throw "bad line in windows\licenses\map.txt: $_" }
    [pscustomobject]@{ Pattern = $f[0]; Licenses = @($f[1] -split ',' | ForEach-Object { $_.Trim() }); Component = $f[2] }
}
$index = New-Object System.Collections.Generic.List[string]
$index.Add("PokeTokenBar $Version - third-party components shipped in this folder")
$index.Add("")
$index.Add("PokeTokenBar.exe  (PokeTokenBar itself, MIT License: PokeTokenBar-LICENSE.txt; statically links OpenSSL 3, Apache-2.0: openssl-LICENSE.txt)")
foreach ($entry in $shipped.Values) {
    $line = $map | Where-Object { $entry.Name -like $_.Pattern } | Select-Object -First 1
    if (-not $line) { Fail "$($entry.Name) ($($entry.Origin)) matches no line in windows\licenses\map.txt"; continue }
    foreach ($l in $line.Licenses) {
        $p = Join-Path windows\licenses $l
        if (-not (Test-Path $p)) { Fail "$($entry.Name): licence file windows\licenses\$l is missing"; continue }
        Copy-Item $p (Join-Path $licenseDir $l) -Force
    }
    $index.Add(("{0}  [{1}]  {2}  licence: {3}" -f $entry.Name, $entry.Origin, $line.Component, ($line.Licenses -join ', ')))
}
Copy-Item LICENSE (Join-Path $licenseDir "PokeTokenBar-LICENSE.txt")
Copy-Item windows\licenses\openssl-LICENSE.txt (Join-Path $licenseDir "openssl-LICENSE.txt")
Set-Content -Path (Join-Path $licenseDir "THIRD-PARTY.txt") -Value $index -Encoding utf8

# --- the list
Write-Host "---- shipped files"
Get-ChildItem $Out -File | Sort-Object Name | ForEach-Object {
    $o = if ($shipped.Contains($_.Name.ToLowerInvariant())) { $shipped[$_.Name.ToLowerInvariant()].Origin } else { "app" }
    "{0,-42} {1,12:N0}  {2}" -f $_.Name, $_.Length, $o
}
$total = (Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("bundle: {0} files in {1}, {2:N0} bytes; licences: {3}" -f (Get-ChildItem $Out -Recurse -File).Count, $Out, $total, ((Get-ChildItem $licenseDir).Name -join ', '))
if ($failures.Count -gt 0) { Write-Host "::error::packaging failed: $($failures.Count) problem(s)"; exit 1 }
Write-Host "PASS package: closure, names, licences"
