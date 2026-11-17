# Restores the SwiftPM .build folder of the latest completed run (a failed test does not spoil the build: the seed is uploaded only after the build step succeeded) (a "seed") so a build is incremental, and stamps
# every tracked file's mtime from its content (restore-mtimes.ps1). Why an artifact and not actions/cache: a cache entry is only
# visible to its own branch and the default branch (main), and agents run CI on their own branches; a run's artifacts can be
# downloaded from any run of the repository. Prints and writes to GITHUB_OUTPUT: clean (true/false), reason, seed_run.
#
# The build is CLEAN (no seed) when: -Clean is set (release mode, kit builds, the clean_build input), the chain of incremental
# builds behind the seed is -MaxChain long or older than -MaxAgeHours (windows-port only: it re-builds from scratch about every
# 8 runs / day and uploads that as the next seed, so a cache-masked breakage cannot live longer than that), or no seed exists.
# Usage: seed-restore.ps1 -Workflow windows.yml -Artifact ptb-seed-debug [-Clean] [-IsPort] [-MaxChain 8] [-MaxAgeHours 24]
# Needs env GH_TOKEN (actions: read), GITHUB_REPOSITORY.
# Package.resolved is git-ignored on purpose (.gitignore) and nothing pins swift-crypto (`from: "3.0.0"`, Windows manifest branch only; the
# Mac manifest on main has no dependency). It is used only inside the seed: the seed carries the file the clean build resolved.
param([Parameter(Mandatory)][string]$Workflow, [Parameter(Mandatory)][string]$Artifact, [switch]$Clean, [switch]$IsPort,
      [int]$MaxChain = 8, [int]$MaxAgeHours = 24, [string]$Branch = 'windows-port')
$ErrorActionPreference = 'Stop'
$repo = $env:GITHUB_REPOSITORY
function Out-Result([string]$clean, [string]$reason, [string]$run) {
    "seed: clean=$clean reason='$reason' seed_run=$run"
    if ($env:GITHUB_OUTPUT) { "clean=$clean", "reason=$reason", "seed_run=$run" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
}
& ./scripts/windows/restore-mtimes.ps1
if ($Clean) { Out-Result 'true' 'clean build requested (release mode, kit build or clean_build)' ''; return }
$seed = $null
# The newest seed of this branch's own earlier runs, else of windows-port (a new branch starts from the trunk's).
foreach ($b in @($env:GITHUB_REF_NAME, $Branch) | Where-Object { $_ } | Select-Object -Unique) {
    # Only runs of THIS repository started by a push or a dispatch (someone with write access): a pull request from a fork can carry a
    # branch called windows-port, and its run must never become the seed of the trunk.
    $runs = gh api "repos/$repo/actions/workflows/$Workflow/runs?branch=$b&status=completed&per_page=30" --jq ".workflow_runs[]|select(.head_repository.full_name==`"$repo`" and (.event==`"push`" or .event==`"workflow_dispatch`"))|.id" 
    foreach ($id in $runs) {
        $a = gh api "repos/$repo/actions/runs/$id/artifacts?name=$Artifact" --jq '[.artifacts[]|select(.expired==false)][0]|select(.!=null)|.id'
        if ($a) { $seed = $id; break }
    }
    if ($seed) { "seed found on branch $b"; break }
}
if (-not $seed) { Out-Result 'true' "no successful $Branch run of $Workflow has a live $Artifact artifact" ''; return }
New-Item -ItemType Directory -Force -Path seed-in | Out-Null
gh run download $seed --repo $repo --name $Artifact --dir seed-in
if ($LASTEXITCODE -ne 0) { Out-Result 'true' "download of $Artifact from run $seed failed" ''; return }
$meta = Get-Content seed-in/seed-meta.json -Raw | ConvertFrom-Json
$ageH = ([datetime]::UtcNow - [datetime]::Parse($meta.cleanAt).ToUniversalTime()).TotalHours
"seed run ${seed}: chain length $($meta.chainLength), last clean build $([math]::Round($ageH, 1)) h ago, built from $($meta.sha)"
if ($IsPort -and ($meta.chainLength -ge $MaxChain -or $ageH -ge $MaxAgeHours)) {
    Out-Result 'true' "scheduled clean build on $Branch (chain $($meta.chainLength) of $MaxChain, $([math]::Round($ageH, 1)) h of $MaxAgeHours)" $seed
    return
}
$swiftNow = ((swift --version 2>&1 | Select-Object -First 1) -as [string]).Trim()
if ($meta.swift -ne $swiftNow -or $meta.image -ne [string]$env:ImageVersion) {
    Out-Result 'true' "the seed was built with '$($meta.swift)' on image '$($meta.image)', this run has '$swiftNow' on '$($env:ImageVersion)'" $seed
    return
}
try {
    ./scripts/windows/build-seed.ps1 -Unpack seed-in/seed.tar.zst
} catch {
    # A damaged seed must never fail the build or leave half a .build behind: start from scratch.
    Remove-Item -Recurse -Force .build, Package.resolved -ErrorAction SilentlyContinue
    Out-Result 'true' "the seed of run $seed could not be unpacked: $($_.Exception.Message)" $seed
    return
}
Copy-Item seed-in/seed-meta.json seed-prev-meta.json
Out-Result 'false' "incremental on the seed of run $seed" $seed
