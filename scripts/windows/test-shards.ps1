# Splits the unit tests into N shards by test class and writes, per shard, chunk files shard-<i>.<k>.filters (one --filter regex
# per line) and shard-<i>.count (the tests the shard must execute), plus total.txt (every test the unsharded run would execute).
# Input: the output of `swift test --skip-build list` (one "Module.Class/testName" per line). Classes are dealt largest-first to the
# lightest shard, so shards stay level by test count. A shard runs its chunks one after the other: SwiftPM turns --filter into the
# explicit list of test names it hands to the xctest process, and Windows refuses a command line over about 32,000 characters
# (error 206 "The file name is invalid"; one chunk per ~20,000 characters of names stays well under it).
# Every test is in exactly one shard and chunk by construction; the result job still compares the executed counts with total.txt.
# Usage: test-shards.ps1 -List tests.txt -Shards 4 -Out shards
param([Parameter(Mandatory)][string]$List, [int]$Shards = 4, [string]$Out = 'shards', [int]$ChunkChars = 20000)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$tests = @(Get-Content $List | Where-Object { $_ -match '^[^\s/]+\.[^\s/]+/\S+$' } | Sort-Object -Unique)
if ($tests.Count -lt 1000) { throw "only $($tests.Count) tests listed (expected over 1000): the list step failed" }
$classes = $tests | Group-Object { $_.Substring(0, $_.IndexOf('/')) } |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Chars = ($_.Group | ForEach-Object { $_.Length + 1 } | Measure-Object -Sum).Sum } } |
    Sort-Object Count -Descending
$load = New-Object 'int[]' $Shards
$take = @(for ($k = 0; $k -lt $Shards; $k++) { , (New-Object System.Collections.ArrayList) })  # the comma keeps each list from being unrolled
foreach ($c in $classes) {
    $i = 0
    for ($k = 1; $k -lt $Shards; $k++) { if ($load[$k] -lt $load[$i]) { $i = $k } }
    [void]$take[$i].Add($c); $load[$i] += $c.Count
}
$chunks = 0
for ($i = 0; $i -lt $Shards; $i++) {
    # LF line endings: the shard step reads them with bash, where a CR would stay on the end of the regex and match nothing.
    $k = 1; $lines = @(); $chars = 0
    foreach ($c in ($take[$i] | Sort-Object Name)) {
        if ($lines.Count -gt 0 -and ($chars + $c.Chars) -gt $ChunkChars) {
            [IO.File]::WriteAllText((Join-Path $Out "shard-$($i + 1).$k.filters"), (($lines -join "`n") + "`n")); $k++; $lines = @(); $chars = 0; $chunks++
        }
        $lines += '^' + [regex]::Escape($c.Name) + '/'; $chars += $c.Chars
    }
    if ($lines.Count -gt 0) { [IO.File]::WriteAllText((Join-Path $Out "shard-$($i + 1).$k.filters"), (($lines -join "`n") + "`n")); $chunks++ }
    [IO.File]::WriteAllText((Join-Path $Out "shard-$($i + 1).count"), "$($load[$i])`n")
}
[IO.File]::WriteAllText((Join-Path $Out 'total.txt'), "$($tests.Count)`n")
"{0} tests in {1} classes -> shards of {2} in {3} chunks of at most {4} characters of names" -f $tests.Count, $classes.Count, ($load -join ', '), $chunks, $ChunkChars
