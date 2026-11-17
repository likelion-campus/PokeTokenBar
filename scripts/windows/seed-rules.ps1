# The trust rules for a build seed (seed-restore.ps1), as pure functions so seed-rules.tests.ps1 can run them against fake data in CI.
# A seed is the .build folder of an earlier run, restored into the workspace of a later one: whatever is in the archive becomes input of
# a trusted job. Three layers: WHO may have produced it, WHAT the archive may contain, and what its metadata may claim.

# A branch name that may go into an API query string: letters, digits, . _ - /, no `..`, not starting with - or /, at most 100 characters.
function Test-BranchName([string]$Name) {
    return ($Name -match '^[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}$') -and ($Name -notmatch '\.\.') -and (-not $Name.EndsWith('/'))
}

# Which branches' runs are searched, in order. A pull_request run (its checkout is a merge ref, its ref name `<n>/merge`) takes its BASE
# branch's seed only; any other run its own branch's, then the trunk's.
function Get-SeedBranches([string]$EventName, [string]$BaseRef, [string]$RefName, [string]$Trunk) {
    if ($EventName -eq 'pull_request') { @($BaseRef, $Trunk) | Where-Object { $_ } | Select-Object -First 1 }
    else { @($RefName, $Trunk) | Where-Object { $_ } | Select-Object -Unique }
}

# Layer 1. The ids of runs whose artifacts may be consumed, newest first: runs of THIS repository (head_repository, not just a branch
# named alike: `branch=` matches the head branch by name, also on a fork) started by a push or a dispatch, i.e. by someone with write
# access. Never a pull_request run, never a fork's.
function Select-SeedRunIds([string]$RunsJson, [string]$Repo) {
    # An empty or malformed answer (a network failure prints nothing) THROWS: the caller turns it into a clean build.
    if ([string]::IsNullOrWhiteSpace($RunsJson)) { throw 'the runs query returned nothing' }
    $parsed = $RunsJson | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['workflow_runs']) { throw 'the runs query returned no workflow_runs' }
    $runs = $parsed.workflow_runs
    foreach ($r in $runs) {
        $fromThisRepo = $r.head_repository -and $r.head_repository.full_name -eq $Repo
        if ($fromThisRepo -and ($r.event -eq 'push' -or $r.event -eq 'workflow_dispatch')) { $r.id }
    }
}

# Where a link at $Member pointing at $Target ends up, relative to the workspace root (forward slashes, no leading slash), or $null
# when it leaves the workspace or cannot be resolved. An absolute target must be inside $Workspace.
function Resolve-SeedLink([string]$Member, [string]$Target, [string]$Workspace) {
    $isAbs = $Target.StartsWith('/') -or $Target -match '^[A-Za-z]:'
    if ($isAbs) {
        $ws = (($Workspace -replace '\\', '/')).TrimEnd('/')
        if (-not $ws -or -not ($Target.TrimEnd('/') + '/').ToLowerInvariant().StartsWith(($ws + '/').ToLowerInvariant())) { return $null }
        $parts = $Target.Substring($ws.Length).Trim('/').Split('/')
    } else {
        $dir = if ($Member.Contains('/')) { $Member.Substring(0, $Member.LastIndexOf('/')) } else { '' }
        $parts = (($dir + '/' + $Target).Trim('/')).Split('/')
    }
    $stack = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $parts) {
        if ($p -eq '' -or $p -eq '.') { continue }
        if ($p -eq '..') { if ($stack.Count -eq 0) { return $null }; $stack.RemoveAt($stack.Count - 1); continue }
        $stack.Add($p)
    }
    return ($stack -join '/')
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
    $links = @()
    foreach ($line in $Verbose) {
        if (-not $line) { continue }
        $type = $line.Substring(0, 1)
        if ($type -eq '-' -or $type -eq 'd') { continue }
        if ($type -eq 'l') {
            if ($line -notmatch ' (?:\d\d:\d\d|\d{4}) (.+?) -> (.+)$') { $problems += "unreadable link entry: $line"; continue }
            $member = (($Matches[1] -replace '\\', '/') -replace '^\./', '').TrimEnd('/')
            $target = ($Matches[2] -replace '\\', '/').Trim()
            $links += $member
            $resolved = Resolve-SeedLink $member $target $Workspace
            if ($null -eq $resolved -or -not ($resolved -eq '.build' -or $resolved.StartsWith('.build/'))) { $problems += "link does not resolve under .build/: $line"; }
            continue
        }
        $problems += "entry type '$type' is not allowed: $line"
    }
    # Nothing may be extracted THROUGH a link: no member under a listed link (a link to the workspace plus members below it would write anywhere).
    foreach ($raw in $Names) {
        $n = ((($raw -replace '\\', '/') -replace '^\./', '')).TrimEnd('/')
        foreach ($l in $links) { if ($n.StartsWith($l + '/')) { $problems += "member below a link: $raw (link $l)"; break } }
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
