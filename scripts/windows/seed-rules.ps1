# The trust rules for a build seed (seed-restore.ps1), as pure functions so seed-rules.tests.ps1 can run them against fake data in CI.
# A seed is the .build folder of an earlier run, restored into the workspace of a later one: whatever is in the archive becomes input of
# a trusted job. Three layers: WHO may have produced it, WHAT the archive may contain, and what its metadata may claim.

# Layer 1. The ids of runs whose artifacts may be consumed, newest first: runs of THIS repository (head_repository, not just a branch
# named alike: `branch=` matches the head branch by name, also on a fork) started by a push or a dispatch, i.e. by someone with write
# access. Never a pull_request run, never a fork's.
function Select-SeedRunIds([string]$RunsJson, [string]$Repo) {
    $runs = ($RunsJson | ConvertFrom-Json).workflow_runs
    foreach ($r in $runs) {
        $fromThisRepo = $r.head_repository -and $r.head_repository.full_name -eq $Repo
        if ($fromThisRepo -and ($r.event -eq 'push' -or $r.event -eq 'workflow_dispatch')) { $r.id }
    }
}

# Layer 2. Problems with an archive listing (an empty result = fine). $Names: `tar -tf`; $Verbose: `tar -tvf` (the first column is the
# entry type, symbolic links end in " -> target"). Only .build/ and Package.resolved may be extracted; a link must stay inside the
# workspace (a later member could be written through it); no device nodes, no hard links, no `..`, no drive letters, no streams.
function Test-SeedArchive([string[]]$Names, [string[]]$Verbose, [string]$Workspace = '') {
    $problems = @()
    if (-not $Names -or $Names.Count -eq 0) { return @('the archive lists nothing') }
    foreach ($raw in $Names) {
        $n = ($raw -replace '\\', '/') -replace '^\./', ''
        $n = $n.TrimEnd('/')
        $okRoot = ($n -eq '.build') -or $n.StartsWith('.build/') -or ($n -eq 'Package.resolved')
        if (-not $okRoot) { $problems += "member outside .build and Package.resolved: $raw"; continue }
        if ($n -match '(^|/)\.\.(/|$)' -or $n.StartsWith('/') -or $n -match '^[A-Za-z]:' -or $n.Contains(':')) { $problems += "unsafe member name: $raw" }
    }
    foreach ($line in $Verbose) {
        if (-not $line) { continue }
        $type = $line.Substring(0, 1)
        if ($type -eq '-' -or $type -eq 'd') { continue }
        if ($type -eq 'l') {
            if ($line -notmatch ' -> (.+)$') { $problems += "unreadable link entry: $line"; continue }
            $t = ($Matches[1] -replace '\\', '/').Trim()
            $absolute = $t.StartsWith('/') -or $t -match '^[A-Za-z]:'
            $inWorkspace = $absolute -and $Workspace -and ($t.TrimEnd('/') + '/').ToLowerInvariant().StartsWith((($Workspace -replace '\\', '/').TrimEnd('/') + '/').ToLowerInvariant())
            if (($absolute -and -not $inWorkspace) -or $t -match '(^|/)\.\.(/|$)') { $problems += "link leaves the workspace: $line" }
            continue
        }
        $problems += "entry type '$type' is not allowed: $line"
    }
    return $problems
}

# Layer 3. What the metadata may claim. Returns Clean (build from scratch), Reason, UseResolved (Package.resolved may be used: only
# when Package.swift is the file the seed was built with, otherwise a changed dependency list would never resolve).
function Test-SeedMeta($Meta, [datetime]$Now, [int]$MaxChain, [int]$MaxAgeHours, [string]$SwiftNow, [string]$ImageNow, [string]$PackageSwiftNow) {
    function Bad([string]$why) { [pscustomobject]@{ Clean = $true; Reason = $why; UseResolved = $false } }
    if ($null -eq $Meta) { return Bad 'no metadata' }
    $chain = $Meta.chainLength
    if (-not (($chain -is [int]) -or ($chain -is [long]))) { return Bad "chainLength '$chain' is not an integer" }
    if ($chain -lt 0) { return Bad "chainLength $chain is negative" }
    if ($chain -ge $MaxChain) { return Bad "the chain of incremental builds is $chain long (limit $MaxChain)" }
    $cleanAt = $null; $builtAt = $null
    try { $cleanAt = ([datetime]$Meta.cleanAt).ToUniversalTime(); $builtAt = ([datetime]$Meta.builtAt).ToUniversalTime() } catch { return Bad 'cleanAt or builtAt is not a date' }
    $nowU = $Now.ToUniversalTime()
    if ($cleanAt -gt $builtAt) { return Bad 'cleanAt is after builtAt' }
    if ($builtAt -gt $nowU.AddMinutes(5)) { return Bad 'builtAt is in the future' }
    if (($nowU - $cleanAt).TotalHours -ge $MaxAgeHours) { return Bad "the last clean build is $([math]::Round(($nowU - $cleanAt).TotalHours, 1)) h old (limit $MaxAgeHours)" }
    if ($Meta.sha -isnot [string] -or $Meta.sha -notmatch '^[0-9a-f]{40}$') { return Bad 'sha is not a commit id' }
    if ([string]$Meta.swift -ne $SwiftNow -or [string]$Meta.image -ne $ImageNow) { return Bad "built with '$($Meta.swift)' on '$($Meta.image)', this run has '$SwiftNow' on '$ImageNow'" }
    [pscustomobject]@{ Clean = $false; Reason = 'metadata accepted'; UseResolved = ([string]$Meta.packageSwift -ne '' -and [string]$Meta.packageSwift -eq $PackageSwiftNow) }
}
