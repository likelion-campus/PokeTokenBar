# Packs .build and the seed's metadata into seed-out/ for upload (artifact ptb-seed-*). Metadata: when the chain of incremental
# builds started from a clean build (cleanAt), how many incremental builds since (chainLength), the commit.
# Usage: seed-save.ps1 -Clean <true|false>   (the clean output of seed-restore.ps1)
param([Parameter(Mandatory)][string]$Clean)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path seed-out | Out-Null
$now = [datetime]::UtcNow.ToString('o')
$meta = if ($Clean -eq 'true' -or -not (Test-Path seed-prev-meta.json)) { @{ cleanAt = $now; chainLength = 0 } }
        else { $p = Get-Content seed-prev-meta.json -Raw | ConvertFrom-Json; @{ cleanAt = $p.cleanAt; chainLength = [int]$p.chainLength + 1 } }
$meta.sha = (git rev-parse HEAD)
$meta.swift = ((swift --version 2>&1 | Select-Object -First 1) -as [string]).Trim()
$meta.image = [string]$env:ImageVersion
$meta.packageSwift = (git rev-parse HEAD:Package.swift)   # Package.resolved is only reused while Package.swift is this blob
$meta.builtAt = $now
$meta | ConvertTo-Json | Set-Content seed-out/seed-meta.json -Encoding utf8
./scripts/windows/build-seed.ps1 -Pack seed-out/seed.tar.zst
Get-Content seed-out/seed-meta.json
