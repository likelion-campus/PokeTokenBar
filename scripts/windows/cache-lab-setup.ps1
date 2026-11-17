# CI proof tool (cache-lab.yml), not product code: adds the probe markers the lab looks for in the linked exe, then commits them
# locally so the git index equals the working tree (restore-mtimes.ps1 reads blob ids from the index).
$ErrorActionPreference = 'Stop'
$leaf = 'Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPopoverWindow.swift'
$t = Get-Content $leaf -Raw
$old = 'return "popover idle probe exit: mode='
if (-not $t.Contains($old)) { throw "leaf marker not found in $leaf" }
Set-Content -NoNewline -Path $leaf -Value $t.Replace($old, 'return ptbPkgProbe + ptbGhostTag() + "popover idle probe exit: mode=')
Set-Content -Path 'Sources/PokeTokenBar/ZPkgProbe.swift' -Value @(
    '#if PTB_CACHE_PROBE', 'let ptbPkgProbe = "PTBPROBE-PKG-ON-0123456789"', '#else', 'let ptbPkgProbe = "PTBPROBE-PKG-OFF-0123456789"', '#endif')
Set-Content -Path 'Sources/PokeTokenBar/ZGhostA.swift' -Value @(
    '@_cdecl("ptb_ghost_dup") public func ptbGhostDupA() -> Int32 { 41 }',
    'func ptbGhostTag() -> String { "PTBPROBE-GHOST-A-0123456789" }')
git add -A
git -c user.name=lab -c user.email=lab@example.invalid commit -q -m 'cache lab: probe markers'
'cache-lab-setup: markers added and committed locally'
