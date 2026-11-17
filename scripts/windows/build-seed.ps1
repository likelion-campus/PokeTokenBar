# Packs / unpacks the SwiftPM .build folder (and Package.resolved, which pins the dependency versions the build resolved: with it a
# warm build does not ask the network again, see scripts/windows/swift-build-args.ps1) as a zstd tar (pax format: nanosecond mtimes
# survive, llbuild compares them).
# Usage: build-seed.ps1 -Pack <file.tar.zst> | -Unpack <file.tar.zst>   (from the repository root)
param([string]$Pack = '', [string]$Unpack = '')
$ErrorActionPreference = 'Stop'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if ($Pack) {
    $items = @('.build') + @(if (Test-Path Package.resolved) { 'Package.resolved' })
    & $tar --format pax --zstd -cf $Pack @items
    if ($LASTEXITCODE -ne 0) { throw "tar pack failed ($LASTEXITCODE)" }
    "packed .build: {0:N0} MB" -f ((Get-Item $Pack).Length / 1MB)
} elseif ($Unpack) {
    # Explicit operands: only .build and Package.resolved are ever extracted, whatever else an archive lists.
    $listed = @(& $tar --zstd -tf $Unpack)
    $operands = @('.build') + @(if ($listed -contains 'Package.resolved') { 'Package.resolved' })
    & $tar --zstd -xf $Unpack @operands
    if ($LASTEXITCODE -ne 0) { throw "tar unpack failed ($LASTEXITCODE)" }
    "unpacked {0:N0} MB into .build" -f ((Get-Item $Unpack).Length / 1MB)
} else { throw 'give -Pack or -Unpack' }
