# Tests of resolved-swift-crypto.ps1 against fixture Package.resolved files (CI: .github/workflows/swift-crypto-rules.yml, no Windows needed).
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'resolved-swift-crypto.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ptb-crypto-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp | Out-Null
$pins = Join-Path $tmp 'pins.json'; '{ "swiftCrypto": "3.15.1" }' | Set-Content $pins
$env:GITHUB_ENV = Join-Path $tmp 'env.txt'
$failed = 0; $count = 0
function Check([bool]$ok, [string]$what) { $script:count++; if ($ok) { "PASS $what" } else { $script:failed++; "FAIL $what" } }
function Fixture([string]$name, [string]$json) { $p = Join-Path $tmp $name; Set-Content -Path $p -Value $json; $p }
function V2([string]$v) { '{ "originHash": "x", "pins": [ { "identity": "swift-asn1", "state": { "version": "1.7.4" } }, { "identity": "swift-crypto", "kind": "remoteSourceControl", "state": { "version": "' + $v + '" } } ], "version": 3 }' }
# Runs the script in a fresh pwsh and returns exit code and output (a throw is exit 1; ::warning:: is on stdout).
function Run([string]$resolved, [bool]$strict) {
    Remove-Item $env:GITHUB_ENV -ErrorAction SilentlyContinue
    $a = @('-NoProfile', '-File', $script, '-ResolvedPath', $resolved, '-PinsPath', $pins); if ($strict) { $a += '-Strict' }
    $out = (& pwsh @a 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out; Env = $(if (Test-Path $env:GITHUB_ENV) { Get-Content $env:GITHUB_ENV -Raw } else { '' }) }
}
foreach ($strict in $false, $true) {
    $m = if ($strict) { 'strict' } else { 'ordinary' }
    $r = Run (Fixture 'same.json' (V2 '3.15.1')) $strict
    Check ($r.Code -eq 0 -and $r.Env -match 'PTB_SWIFT_CRYPTO_VERSION=3\.15\.1' -and $r.Out -notmatch '::warning') "$m, same version: ok, exported, no warning"
    $r = Run (Fixture 'old.json' (V2 '3.15.0')) $strict
    if ($strict) { Check ($r.Code -ne 0 -and $r.Out -match 'resolved to 3\.15\.0, pinned 3\.15\.1') 'strict, drift: fails and says both versions' }
    else { Check ($r.Code -eq 0 -and $r.Out -match '::warning title=swift-crypto drift::swift-crypto resolved to 3\.15\.0, pinned 3\.15\.1' -and $r.Env -match '3\.15\.0') 'ordinary, drift: a warning naming both versions, exit 0, the resolved version exported' }
    $r = Run (Join-Path $tmp 'missing.json') $strict
    Check ($r.Code -ne 0 -and $r.Out -match 'no Package.resolved') "$m, no Package.resolved: fails"
    $r = Run (Fixture 'junk.json' 'not json {') $strict
    Check ($r.Code -ne 0 -and $r.Out -match 'not JSON') "$m, unparseable Package.resolved: fails"
    $r = Run (Fixture 'nocrypto.json' '{ "pins": [ { "identity": "swift-asn1", "state": { "version": "1.7.4" } } ], "version": 3 }') $strict
    Check ($r.Code -ne 0 -and $r.Out -match 'swift-crypto 0 times') "$m, no swift-crypto pin: fails"
    $r = Run (Fixture 'branch.json' '{ "pins": [ { "identity": "swift-crypto", "state": { "branch": "main", "revision": "abc" } } ], "version": 3 }') $strict
    Check ($r.Code -ne 0 -and $r.Out -match "expected a release version") "$m, a branch pin instead of a version: fails"
    $r = Run (Fixture 'v1.json' '{ "object": { "pins": [ { "package": "swift-crypto", "state": { "version": "3.15.1" } } ] }, "version": 1 }') $strict
    Check ($r.Code -eq 0) "$m, the older file layout (object.pins, package) is read"
}
Remove-Item -Recurse -Force $tmp
"$($count - $failed) of $count checks passed"
if ($failed -gt 0) { throw "$failed check(s) failed" }
