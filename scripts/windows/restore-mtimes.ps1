# Gives every tracked file a modification time that is a function of its CONTENT (the git blob id), not of the checkout.
# A fresh checkout stamps every file "now", which makes llbuild (SwiftPM's build engine, it compares each input's recorded
# size/mtime/inode with the file) see every source as changed against a restored .build. With this, a file that did not change
# since the cached build has the same mtime in both runs, a changed file has another one, and a file that changes back gets
# its old one again (so it is rebuilt only when llbuild's record says so). The time is 2000-01-01 plus 28 bits of the blob id
# (about 8.5 years: always in the past, so nothing looks newer than a build output); two different contents collide with
# probability 2^-28 and then still differ in size nearly always.
# Run from the repository root after checkout and before any build. Usage: restore-mtimes.ps1
$ErrorActionPreference = 'Stop'
$epoch = [datetime]::SpecifyKind([datetime]'2000-01-01', [DateTimeKind]::Utc)
$entries = (git ls-files -s -z) -split "`0" | Where-Object { $_ }
$n = 0
foreach ($e in $entries) {
    # "<mode> <blob> <stage>\t<path>"
    $tab = $e.IndexOf("`t")
    $meta = $e.Substring(0, $tab).Split(' ')
    $path = $e.Substring($tab + 1)
    if ($meta[0] -eq '160000' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $seconds = [Convert]::ToInt64($meta[1].Substring(0, 7), 16) -band 0x0FFFFFFF
    [IO.File]::SetLastWriteTimeUtc((Resolve-Path -LiteralPath $path).Path, $epoch.AddSeconds($seconds))
    $n++
}
"restore-mtimes: $n tracked files stamped from their blob ids"
