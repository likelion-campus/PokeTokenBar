# Tests of seed-rules.ps1 against fake data (CI: .github/workflows/seed-rules.yml; no network, no repository needed).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/seed-rules.ps1"
$script:failed = 0; $script:count = 0
function Check([bool]$ok, [string]$what) { $script:count++; if ($ok) { "PASS $what" } else { $script:failed++; "FAIL $what" } }

# ---- layer 1: which runs
$repo = 'likelion-campus/PokeTokenBar'
function Run($id, $event, $headRepo) { @{ id = $id; event = $event; head_repository = $(if ($headRepo) { @{ full_name = $headRepo } } else { $null }) } }
$runs = @{ workflow_runs = @(
    (Run 1 'pull_request' $repo), (Run 2 'push' 'someone/PokeTokenBar'), (Run 3 'pull_request' 'someone/PokeTokenBar'),
    (Run 4 'push' $null), (Run 5 'workflow_dispatch' $repo), (Run 6 'schedule' $repo), (Run 7 'push' $repo), (Run 8 'workflow_dispatch' 'someone/PokeTokenBar')
) } | ConvertTo-Json -Depth 5
$ids = @(Select-SeedRunIds $runs $repo)
Check (($ids -join ',') -eq '5,7') "only own-repo push/dispatch runs are seed candidates, in order (got $($ids -join ','))"
Check (@(Select-SeedRunIds (@{ workflow_runs = @() } | ConvertTo-Json) $repo).Count -eq 0) 'no runs, no candidates'

Check ((@(Get-SeedBranches 'pull_request' 'windows-port' '123/merge' 'windows-port') -join ',') -eq 'windows-port') 'a pull request searches its base branch only'
Check ((@(Get-SeedBranches 'pull_request' '' '123/merge' 'windows-port') -join ',') -eq 'windows-port') 'a pull request without a base falls back to the trunk, never to its own ref'
Check ((@(Get-SeedBranches 'push' '' 'feat/x' 'windows-port') -join ',') -eq 'feat/x,windows-port') 'a push searches its own branch, then the trunk'
Check ((@(Get-SeedBranches 'push' '' 'windows-port' 'windows-port') -join ',') -eq 'windows-port') 'windows-port searches itself once'
Check ((@(Get-SeedBranches 'workflow_dispatch' '' 'feat/x' 'ci/other') -join ',') -eq 'feat/x,ci/other') 'a dispatch with another trunk (rehearsal)'

# ---- layer 2: the archive
$goodNames = @('.build/', '.build/debug', '.build/x86_64-unknown-windows-msvc/debug/a.o', '.build/checkouts/swift-crypto/Package.swift', 'Package.resolved')
$goodVerbose = @('drwxrwxrwx  0 0      0           0 Nov 17 22:48 .build/', '-rw-rw-rw-  0 0      0           4 Nov 17 22:48 .build/.lock',
                 'lrw-rw-rw-  0 0      0           0 Nov 17 22:48 .build/debug -> x86_64-unknown-windows-msvc/debug')
Check ((Test-SeedArchive $goodNames $goodVerbose 'D:\a\PokeTokenBar\PokeTokenBar').Count -eq 0) 'the real layout of a seed (a .build/debug link) is accepted'
foreach ($bad in @('scripts/windows/seed-restore.ps1', 'Package.swift', '.buildx/evil', '../x', '.build/../scripts/x.ps1', '/etc/passwd', 'C:/x', 'C:\x', '.build/a:stream', './scripts/x', '.github/workflows/windows.yml')) {
    Check ((Test-SeedArchive ($goodNames + $bad) $goodVerbose).Count -gt 0) "the archive is refused for the member '$bad'"
}
Check ((Test-SeedArchive @() @()).Count -gt 0) 'an empty listing is refused'
foreach ($link in @('lrwxrwxrwx 0 0 0 0 Nov 17 22:48 .build/x -> ../scripts', 'lrwxrwxrwx 0 0 0 0 Nov 17 22:48 .build/x -> /etc', 'lrwxrwxrwx 0 0 0 0 Nov 17 22:48 .build/x -> C:\Windows', 'lrwxrwxrwx 0 0 0 0 Nov 17 22:48 .build/x -> a/../../b')) {
    Check ((Test-SeedArchive $goodNames ($goodVerbose + $link) 'D:\a\PokeTokenBar\PokeTokenBar').Count -gt 0) "the link is refused: $link"
}
Check ((Test-SeedArchive $goodNames ($goodVerbose + 'lrwxrwxrwx 0 0 0 0 Nov 17 22:48 .build/x -> D:\a\PokeTokenBar\PokeTokenBar\.build\y') 'D:\a\PokeTokenBar\PokeTokenBar').Count -eq 0) 'an absolute link inside the workspace is accepted'
Check ((Test-SeedArchive $goodNames ($goodVerbose + 'hrw-r--r-- 0 0 0 0 Nov 17 22:48 .build/h link to .build/lock') 'D:\w').Count -gt 0) 'a hard link is refused'
Check ((Test-SeedArchive $goodNames ($goodVerbose + 'crw-r--r-- 0 0 0 0 Nov 17 22:48 .build/dev') 'D:\w').Count -gt 0) 'a device node is refused'

# ---- layer 3: the metadata
$now = [datetime]'2026-11-17T12:00:00Z'
$sha = 'a' * 40
function Meta([hashtable]$over) {
    $m = @{ cleanAt = '2026-11-17T09:00:00Z'; builtAt = '2026-11-17T11:30:00Z'; chainLength = 2; sha = $sha; swift = 'Swift version 6.3.2'; image = '20261103.298.1'; packageSwift = 'p1' }
    foreach ($k in $over.Keys) { $m[$k] = $over[$k] }
    ($m | ConvertTo-Json | ConvertFrom-Json)
}
function Verdict($m, $pkg = 'p1') { Test-SeedMeta $m $now 8 24 'Swift version 6.3.2' '20261103.298.1' $pkg }
$ok = Verdict (Meta @{})
Check ((-not $ok.Clean) -and $ok.UseResolved) 'a sane seed is accepted and Package.resolved may be used'
Check ((Verdict (Meta @{}) 'p2').UseResolved -eq $false -and (-not (Verdict (Meta @{}) 'p2').Clean) ) 'a changed Package.swift: incremental, but Package.resolved is not used'
Check ((Verdict (Meta @{ packageSwift = '' })).UseResolved -eq $false) 'a seed without the Package.swift id does not get Package.resolved'
$cases = [ordered]@{
    'chainLength -100000'      = @{ chainLength = -100000 }
    'chainLength at the limit' = @{ chainLength = 8 }
    'chainLength over the limit' = @{ chainLength = 9 }
    'chainLength as a string'  = @{ chainLength = '2' }
    'chainLength missing'      = @{ chainLength = $null }
    'cleanAt in 2099'          = @{ cleanAt = '2099-01-01T00:00:00Z'; builtAt = '2099-01-02T00:00:00Z' }
    'cleanAt after builtAt'    = @{ cleanAt = '2026-11-17T11:45:00Z' }
    'builtAt in the future'    = @{ builtAt = '2026-11-17T13:00:00Z' }
    'cleanAt 25 h ago'         = @{ cleanAt = '2026-11-16T10:30:00Z' }
    'cleanAt not a date'       = @{ cleanAt = 'yesterday' }
    'sha not hex'              = @{ sha = 'zzzz' }
    'sha too short'            = @{ sha = 'abc123' }
    'another Swift'            = @{ swift = 'Swift version 6.2.0' }
    'another image'            = @{ image = '20261101.1.0' }
    'no swift'                 = @{ swift = $null }
}
foreach ($name in $cases.Keys) { Check ((Verdict (Meta $cases[$name])).Clean) "metadata with $name means a clean build" }
Check ((Test-SeedMeta $null $now 8 24 'x' 'y' 'z').Clean) 'no metadata means a clean build'

"$($script:count - $script:failed) of $($script:count) checks passed"
if ($script:failed -gt 0) { throw "$($script:failed) check(s) failed" }
