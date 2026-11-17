# CI proof tool (cache-lab.yml): after a restored .build, change one thing at a time, rebuild incrementally and check BEHAVIOUR:
# the linked exe must contain the new string (and not the old), or the build must fail where it has to. Prints one line per
# scenario and fails if any expectation is not met. -Flavor debug builds `swift build --build-tests`, release builds the app
# product the way windows-app does (resources first, -c release).
param([Parameter(Mandatory)][ValidateSet('debug', 'release')][string]$Flavor)
$ErrorActionPreference = 'Stop'
$exe = ".build/$Flavor/PokeTokenBarWin.exe"
$script:rows = @()
$script:failed = 0
$script:lastOut = ''

function Stamp { & ./scripts/windows/restore-mtimes.ps1 | Out-Null }
function Commit([string]$msg) { git add -A; git -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m $msg }
function Edit([string]$path, [string]$old, [string]$new) {
    $t = Get-Content -Raw -Path $path
    $i = $t.IndexOf($old)
    if ($i -lt 0) { throw "'$old' not found in $path" }
    Set-Content -NoNewline -Path $path -Value ($t.Substring(0, $i) + $new + $t.Substring($i + $old.Length))
}
function Build([bool]$DeleteExe = $false) {
    if ($DeleteExe -and (Test-Path $exe)) { Remove-Item $exe -Force }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $extra = @(./scripts/windows/swift-build-args.ps1)
    $args = if ($Flavor -eq 'release') { @('build', '-c', 'release', '--product', 'PokeTokenBarWin', '-Xlinker', $env:PTB_RES) + $extra } else { @('build', '--build-tests') + $extra }
    $out = (& swift @args 2>&1 | Out-String)
    $sw.Stop()
    $script:lastOut = $out
    $lines = @([regex]::Matches($out, '(?m)^\[\d+/\d+\] Compiling .*$') | ForEach-Object { $_.Value })
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Compiles = $lines.Count; Lines = $lines; Out = $out }
}
function Has([string]$s, [string]$enc = 'ascii') {
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $exe).Path)
    $hay = [Text.Encoding]::Latin1.GetString($bytes)
    $needle = if ($enc -eq 'utf16') { [Text.Encoding]::Latin1.GetString([Text.Encoding]::Unicode.GetBytes($s)) } else { $s }
    $hay.Contains($needle)
}
function Report([string]$name, $b, [bool]$ok, [string]$note) {
    $verdict = if ($ok) { 'PASS' } else { $script:failed++; 'FAIL' }
    $line = "{0} {1}: build {2} s, {3} compile lines, ok={4} - {5}" -f $verdict, $name, $b.Seconds, $b.Compiles, $b.Ok, $note
    $line
    if ($b.Compiles -gt 0 -and $b.Compiles -le 6) { $b.Lines | ForEach-Object { "      $_" } }
    $script:rows += "| $verdict | $name | $($b.Seconds) | $($b.Compiles) | $note |"
}

# The unchanged tree, as restored from the seed.
Stamp
$b = Build
Report 'no change' $b ($b.Ok -and $b.Compiles -eq 0) 'nothing may compile; seconds show what a restored cache costs'

$b = Build
Report 'no change (again, same job)' $b ($b.Ok -and $b.Compiles -eq 0) 'a second build in a row'

# 1 leaf Swift file
Edit 'Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPopoverWindow.swift' 'popover idle probe exit: mode=' 'popover idle probe exit2: mode='
Commit leaf; Stamp; $b = Build
Report 'leaf Swift file' $b ($b.Ok -and (Has 'popover idle probe exit2: mode=') -and -not (Has 'popover idle probe exit: mode=')) 'new string in the exe, old one gone'

# 2 widely used file, body edit (debug: file-level incremental; release is one whole-module compile either way)
if ($Flavor -eq 'debug') {
Edit 'Sources/PokeTokenBar/Core/CompanionModel.swift' '"shiny-charm"' '"shiny-charmQ"'
Commit wide; Stamp; $b = Build
Report 'widely used file (body)' $b ($b.Ok -and (Has 'shiny-charmQ')) 'new string in the exe'
}

# 3 widely used file, interface change: rename an enum case (and every use inside its own file); the uses in OTHER files must fail
$cm = 'Sources/PokeTokenBar/Core/CompanionModel.swift'
$orig = Get-Content -Raw -Path $cm
$changed = $orig.Replace('case shinyCharm', 'case shinyCharm2').Replace('case .shinyCharm:', 'case .shinyCharm2:')
Set-Content -NoNewline -Path $cm -Value $changed
Commit iface; Stamp; $b = Build
$errFiles = @([regex]::Matches($b.Out, '(?m)([^\s]+\.swift):\d+:\d+: error') | ForEach-Object { Split-Path $_.Groups[1].Value -Leaf } | Sort-Object -Unique)
Report 'interface change (renamed ItemKind case)' $b ((-not $b.Ok) -and $errFiles.Count -gt 0 -and ($errFiles -notcontains 'CompanionModel.swift')) "must FAIL in the files that use it, not in the edited one; errors in: $($errFiles -join ', ')"
Set-Content -NoNewline -Path $cm -Value $orig
Commit iface-back; Stamp
if ($Flavor -eq 'debug') { $b = Build
Report 'interface change reverted' $b ($b.Ok -and (Has 'shiny-charmQ')) 'builds again, body edit still in' }

# 4 C++ file
Edit 'Sources/CPlazaD2D/clipboard.cpp' 'clipboard format not present' 'clipboard format not presentQ'
Commit cpp; Stamp; $b = Build
Report 'C++ file (CPlazaD2D)' $b ($b.Ok -and (Has 'clipboard format not presentQ')) 'new string in the exe'

# 5 resource compiled into the exe (release only: the .res is a plain -Xlinker input llbuild does not track)
if ($Flavor -eq 'release') {
    Edit 'Sources/PokeTokenBarWin/PokeTokenBar.rc' 'VALUE "CompanyName", "likelion-campus"' 'VALUE "CompanyName", "likelion-campusQ"'
    Commit rc; Stamp
    $env:PTB_RES = (& ./scripts/windows/build-resources.ps1 -Out resources | Select-Object -Last 1) -replace '\\', '/'
    $b = Build
    $fresh = Has 'likelion-campusQ' 'utf16'
    Report 'resource (.res) without deleting the exe' $b $true "informational: new .res embedded = $fresh (false = llbuild does not see a changed .res: the exe must be deleted before the build)"
    if (-not $fresh) { $b = Build $true }
    Report 'resource (.res) with the exe deleted first' $b ($b.Ok -and (Has 'likelion-campusQ' 'utf16')) 'new VERSIONINFO in the exe'
}

# 6 Package.swift: a compile-time define
Edit 'Package.swift' 'swiftSettings: [.define("PTB_SHARED_ONLY")]' 'swiftSettings: [.define("PTB_SHARED_ONLY"), .define("PTB_CACHE_PROBE")]'
Commit pkg; Stamp; $b = Build
Report 'Package.swift (new define)' $b ($b.Ok -and (Has 'PTBPROBE-PKG-ON-') -and -not (Has 'PTBPROBE-PKG-OFF-')) 'the #if branch switched'
Edit 'Package.swift' ', .define("PTB_CACHE_PROBE")' ''
Commit pkg-back; Stamp
if ($Flavor -eq 'debug') { $b = Build
Report 'Package.swift reverted' $b ($b.Ok -and (Has 'PTBPROBE-PKG-OFF-') -and -not (Has 'PTBPROBE-PKG-ON-')) 'the #if branch switched back' }

# 7 a file deleted and another one with the same symbols added: a stale object linked in would be a duplicate symbol
Remove-Item 'Sources/PokeTokenBar/ZGhostA.swift'
Set-Content -Path 'Sources/PokeTokenBar/ZGhostB.swift' -Value @('@_cdecl("ptb_ghost_dup") public func ptbGhostDupB() -> Int32 { 42 }', 'func ptbGhostTag() -> String { "PTBPROBE-GHOST-B-0123456789" }')
Commit ghost; Stamp; $b = Build
Report 'deleted file + new file with the same symbols' $b ($b.Ok -and (Has 'PTBPROBE-GHOST-B-') -and -not (Has 'PTBPROBE-GHOST-A-')) 'links, new marker in, old marker not linked'

# 8 everything back to the first commit of the lab (debug only: in release it is one more whole-module compile)
if ($Flavor -eq 'debug') {
$base = (git log --format=%H --grep='cache lab: probe markers' -n 1)
git reset -q --hard $base
Stamp
if ($Flavor -eq 'release') { $env:PTB_RES = (& ./scripts/windows/build-resources.ps1 -Out resources | Select-Object -Last 1) -replace '\\', '/' }
$b = Build $true
$back = (Has 'popover idle probe exit: mode=') -and -not (Has 'popover idle probe exit2: mode=') -and -not (Has 'shiny-charmQ') -and -not (Has 'clipboard format not presentQ') -and (Has 'PTBPROBE-GHOST-A-') -and -not (Has 'PTBPROBE-GHOST-B-')
if ($Flavor -eq 'release') { $back = $back -and -not (Has 'likelion-campusQ' 'utf16') }
Report 'all changes reverted (reset to the seed commit)' $b ($b.Ok -and $back) 'every marker is back to the seed state'

}

$summary = @("### cache lab: $Flavor", '', '| | scenario | build s | compile lines | what was checked |', '|---|---|---|---|---|') + $script:rows
$summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
if ($script:failed -gt 0) { throw "$($script:failed) scenario(s) failed" }
'all scenarios passed'
