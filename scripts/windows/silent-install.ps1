# Silent install of this build's installer on a fresh profile, and what it left (windows-app.yml: step id install, in the
# installer job and in every idle-gate shard). Run from the repository root with the artifact ptb-build unpacked there
# (installer-out\, bundle\) and PTB_VERSION set. Writes install-stamps.json for the release manifest.
. ./scripts/windows/ci-helpers.ps1
# A fresh profile on this throwaway runner: nothing of the earlier steps' settings or state.
Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PtbPlist, "$PtbPlist.bak", (Join-Path $env:LOCALAPPDATA 'PokeTokenBar')
$v = $env:PTB_VERSION
$setup = Resolve-Path "installer-out\PokeTokenBar-Setup-$v-win-x64.exe"
$code = Invoke-Setup $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=$PWD\install.log")
Assert-That ($code -eq 0) 'install.exit' "exit $code"
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
Assert-That (Test-Path $exe) 'install.exe' $exe
$same = (Get-FileHash $exe).Hash -eq (Get-FileHash bundle\PokeTokenBar.exe).Hash
$missing = @(Get-ChildItem bundle -Recurse -File | Where-Object { -not (Test-Path (Join-Path $PtbInstallDir $_.FullName.Substring((Resolve-Path bundle).Path.Length + 1))) })
Assert-That ($same -and $missing.Count -eq 0) 'install.files' "exe identical to the bundle's: $same; bundle files missing from the install: $($missing.Count)"
Assert-That ((Get-Content (Join-Path $PtbInstallDir 'PokeTokenBar.version') -Raw).Trim() -eq $v) 'install.version' $v
Assert-That (Test-Path (Join-Path $PtbInstallDir 'licenses\THIRD-PARTY.txt')) 'install.licenses' 'licenses\THIRD-PARTY.txt'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\PokeTokenBar.lnk'
Assert-That (Test-Path $lnk) 'install.startMenu' $lnk
$shell = New-Object -ComObject Shell.Application
$item = $shell.NameSpace((Split-Path $lnk)).ParseName((Split-Path $lnk -Leaf))
$aumid = $item.ExtendedProperty('System.AppUserModel.ID')
Assert-That ($aumid -eq 'LikelionCampus.PokeTokenBar') 'install.aumid' "shortcut AppUserModelID='$aumid'"
$key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' | Where-Object { $_.PSChildName -like '{6CE57293-9940-4B5E-A604-4C4FEECBF049}*' }
Assert-That ($null -ne $key) 'install.uninstallKey' "$($key.PSChildName) DisplayVersion=$($key.GetValue('DisplayVersion'))"
Assert-That ($key.GetValue('DisplayVersion') -eq $v) 'install.displayVersion' "Uninstall DisplayVersion=$($key.GetValue('DisplayVersion')), expected $v"
Assert-That ($null -eq (Get-RunValue)) 'install.noRunValue' "HKCU Run PokeTokenBar: $(Get-RunValue)"
Assert-That (-not (Get-Process PokeTokenBar -ErrorAction SilentlyContinue)) 'install.noLaunchWithFlag' '/NOLAUNCH=1 left no running instance'
$item = Get-Item $exe
"installed exe: $($item.VersionInfo.FileVersion) $($item.Length) bytes"
# What the install showed, for the release manifest (the install folder is gone by then).
[ordered]@{ fileVersion = $item.VersionInfo.FileVersion; versionFile = (Get-Content (Join-Path $PtbInstallDir 'PokeTokenBar.version') -Raw).Trim()
            uninstallDisplayVersion = $key.GetValue('DisplayVersion') } | ConvertTo-Json | Set-Content install-stamps.json -Encoding utf8NoBOM
