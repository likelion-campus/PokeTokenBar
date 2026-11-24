# Restores the SwiftPM .build folder of an earlier run (a "seed") so a build is incremental, and stamps the modification times
# (restore-mtimes.ps1, stamp-changed.ps1). Why an artifact and not actions/cache: a cache entry is only visible to its own branch and
# the default branch (main), and agents run CI on their own branches; a run's artifacts can be downloaded from any run of the
# repository. Prints and writes to GITHUB_OUTPUT: clean (true/false), reason, seed_run.
#
# WHO may produce a seed (seed-rules.ps1, tested by seed-rules.yml): completed runs of THIS repository started by a push or a dispatch
# of the same branch, else of the trunk (-Branch, windows-port). A pull_request run (a fork's or not) is never a candidate, and a
# pull_request run consumes only its BASE branch's seed. WHAT the archive may hold: only .build and Package.resolved, links inside the
# workspace. WHAT the metadata may claim: validated, never trusted (chain length, dates, sha, toolchain).
# The build is clean (no seed) when: no usable seed exists; the chain of incremental builds behind it is -MaxChain long or its last clean
# build -MaxAgeHours old (for every consumer: PRs and dispatches too; a failed scheduled clean build cannot keep an old seed in use);
# another Swift version or runner image; anything about the seed is invalid, hangs, or cannot be unpacked or compared with its commit.
# Callers that must never use a seed (release mode, kit/* branches, clean_build) do not call this script at all (a workflow `if:`).
# Package.resolved is tracked: it pins the revision of every dependency (swift-crypto and its swift-asn1; the Mac manifest on main has no
# dependency, so the Mac never uses it). The commit's file always wins over the seed's copy; after changing the dependencies in Package.swift,
# refresh it with `PTB_SHARED_ONLY=1 swift package resolve` and commit it, or the build (which passes --only-use-versions-from-resolved-file) fails.
# Usage: seed-restore.ps1 -Workflow windows.yml -Artifact ptb-seed-debug [-Branch windows-port] [-MaxChain 8] [-MaxAgeHours 24]
# Needs env GH_TOKEN (actions: read), GITHUB_REPOSITORY; reads GITHUB_EVENT_NAME, GITHUB_BASE_REF, GITHUB_REF_NAME, GITHUB_WORKSPACE.
param([Parameter(Mandatory)][string]$Workflow, [Parameter(Mandatory)][string]$Artifact, [string]$Branch = 'windows-port',
      [int]$MaxChain = 8, [int]$MaxAgeHours = 24)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/seed-rules.ps1"
$repo = $env:GITHUB_REPOSITORY
function Out-Result([string]$clean, [string]$reason, [string]$run) {
    "seed: clean=$clean reason='$reason' seed_run=$run"
    if ($env:GITHUB_OUTPUT) { "clean=$clean", "reason=$reason", "seed_run=$run" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}
function Go-Clean([string]$reason, [string]$run) {
    # Whatever a half-used seed left behind goes: a clean build starts from nothing.
    Remove-Item -Recurse -Force .build, seed-in, seed-prev-meta.json -ErrorAction SilentlyContinue
    git checkout -- Package.resolved   # tracked: a clean build uses the committed pins, never the file a half-used seed left
    & ./scripts/windows/restore-mtimes.ps1 | Out-Null
    Out-Result 'true' $reason $run
}
& ./scripts/windows/restore-mtimes.ps1

# A pull request restores its BASE branch's seed only; everything else its own branch's, then the trunk's.
$branches = @(Get-SeedBranches $env:GITHUB_EVENT_NAME $env:GITHUB_BASE_REF $env:GITHUB_REF_NAME $Branch)
foreach ($b in $branches) {
    if (-not (Test-BranchName $b)) { Go-Clean "the branch name '$b' is not one that may go into a query" ''; return }
}
$seed = $null
try {
    foreach ($b in $branches) {
        $json = gh api "repos/$repo/actions/workflows/$Workflow/runs?branch=$([uri]::EscapeDataString($b))&status=completed&per_page=30"
        if ($LASTEXITCODE -ne 0) { throw "gh api exited with $LASTEXITCODE" }
        foreach ($id in (Select-SeedRunIds ($json -join "`n") $repo)) {
            $a = gh api "repos/$repo/actions/runs/$id/artifacts?name=$Artifact" --jq '[.artifacts[]|select(.expired==false)][0]|select(.!=null)|.id'
            if ($LASTEXITCODE -ne 0) { throw "gh api (artifacts of run $id) exited with $LASTEXITCODE" }
            if ($a) { $seed = $id; break }
        }
        if ($seed) { "seed found on branch $b"; break }
    }
} catch { Go-Clean "the search for a seed failed: $($_.Exception.Message)" ''; return }
if (-not $seed) { Go-Clean "no push or dispatch run of $Workflow on $($branches -join ', ') has a live $Artifact artifact" ''; return }

# Download with a limit of its own: a hung download must not hold the build for the step's 15 minutes.
New-Item -ItemType Directory -Force -Path seed-in | Out-Null
$dl = Start-Process -FilePath gh -ArgumentList @('run', 'download', "$seed", '--repo', $repo, '--name', $Artifact, '--dir', 'seed-in') -NoNewWindow -PassThru
if (-not $dl.WaitForExit(300000)) { Stop-Process -Id $dl.Id -Force -ErrorAction SilentlyContinue; Go-Clean "the download of $Artifact from run $seed took over 5 minutes" $seed; return }
if ($dl.ExitCode -ne 0 -or -not (Test-Path seed-in/seed.tar.zst) -or -not (Test-Path seed-in/seed-meta.json)) { Go-Clean "the download of $Artifact from run $seed failed or is incomplete" $seed; return }

$meta = $null
try { $meta = Get-Content seed-in/seed-meta.json -Raw | ConvertFrom-Json } catch { Go-Clean "seed-meta.json of run $seed is not JSON" $seed; return }
$swiftNow = ((swift --version 2>&1 | Select-Object -First 1) -as [string]).Trim()
$pkgNow = (git rev-parse HEAD:Package.swift)
$verdict = Test-SeedMeta $meta ([datetime]::UtcNow) $MaxChain $MaxAgeHours $swiftNow ([string]$env:ImageVersion) $pkgNow ([string]$env:PTB_MSVC_TOOLSET)
if ($verdict.Clean) { Go-Clean "seed of run ${seed}: $($verdict.Reason)" $seed; return }
"seed run ${seed}: chain length $($meta.chainLength), last clean build $($meta.cleanAt), built from $($meta.sha)"

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$names = @(& $tar --zstd -tf seed-in/seed.tar.zst); $namesRc = $LASTEXITCODE
$verbose = @(& $tar --zstd -tvf seed-in/seed.tar.zst); $verboseRc = $LASTEXITCODE
if ($namesRc -ne 0 -or $verboseRc -ne 0) { Go-Clean "the archive of run $seed cannot be listed" $seed; return }
$problems = @(Test-SeedArchive $names $verbose $env:GITHUB_WORKSPACE)
if ($problems.Count -gt 0) { Go-Clean "the archive of run $seed was refused: $($problems | Select-Object -First 3)" $seed; return }

try { ./scripts/windows/build-seed.ps1 -Unpack seed-in/seed.tar.zst } catch { Go-Clean "the seed of run $seed could not be unpacked: $($_.Exception.Message)" $seed; return }
# Package.resolved is tracked (it pins the dependency revisions): the commit's file always wins over the seed's copy, so a seed can never change what is linked.
git checkout -- Package.resolved
if (-not $verdict.UseResolved) { "Package.swift changed since the seed: the seed's Package.resolved is not used (the committed one is)" }
try { & ./scripts/windows/stamp-changed.ps1 -Base $meta.sha } catch { Go-Clean "the seed's commit could not be compared with this one: $($_.Exception.Message)" $seed; return }
Copy-Item seed-in/seed-meta.json seed-prev-meta.json
Out-Result 'false' "incremental on the seed of run $seed" $seed
