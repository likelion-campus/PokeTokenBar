# After a seed was restored: every file that differs between the seed's commit and HEAD gets the modification time NOW.
# restore-mtimes.ps1 stamps every file from its content (2000-2008), which is exactly what llbuild needs (it compares size/mtime/inode
# with its record). swift-driver is different: it judges the C headers and clang modules a Swift file imports by "newer than the
# previous build" (ExternalDependencyCurrencyCache), so an edited header with a 2000-2008 stamp always looks current and no Swift file
# is recompiled against it: a renamed struct field would build green with the old layout in the Swift objects. Touching what changed
# fixes both: llbuild sees another mtime, the driver sees a newer file. Files that changed and changed back are equal to the seed's
# content and keep their stamp.
# Usage: stamp-changed.ps1 -Base <commit the seed was built from>. Fails when the commit cannot be had: the caller builds clean.
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Base)
$ErrorActionPreference = 'Stop'
git cat-file -e "$Base^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    git fetch --no-tags --depth=1 origin $Base
    if ($LASTEXITCODE -ne 0) { throw "the seed's commit $Base cannot be fetched" }
}
$names = (git diff --name-only --no-renames --diff-filter=ACMRT -z $Base HEAD) -split "`0" | Where-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw "git diff $Base HEAD failed" }
$now = [datetime]::UtcNow
$n = 0
foreach ($name in $names) {
    if (Test-Path -LiteralPath $name -PathType Leaf) { [IO.File]::SetLastWriteTimeUtc((Resolve-Path -LiteralPath $name).Path, $now); $n++ }
}
"stamp-changed: $n files differ from the seed's commit $($Base.Substring(0, 8)) and got the mtime now"
