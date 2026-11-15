# Runs `PokeTokenBar.exe --language-probe` as CHILD processes under other user settings and asserts what the app does.
# Changes the CI runner's own HKCU language values and its machine time zone for the duration, and puts them back.
# Usage: check-language.ps1 -Exe bundle\PokeTokenBar.exe [-OutDir lang-probe]
param([Parameter(Mandatory)][string]$Exe, [string]$OutDir = 'lang-probe')
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$failed = @()
function Probe([string]$name, [string[]]$extra = @()) {
    $out = Join-Path (Resolve-Path $OutDir).Path "$name.txt"
    Remove-Item -ErrorAction SilentlyContinue $out
    $p = Start-Process -FilePath $Exe -ArgumentList (@('--language-probe', $out) + $extra) -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw "$name: probe hung" }
    if (-not (Test-Path $out)) { throw "$name: no output (exit $($p.ExitCode))" }
    $h = @{}; foreach ($l in Get-Content $out) { $i = $l.IndexOf('='); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
    Write-Host "---- $name"; Get-Content $out | ForEach-Object { Write-Host "  $_" }
    $h
}
function Check([string]$name, [bool]$ok, [string]$detail) {
    Write-Host ("{0} {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
    if (-not $ok) { $script:failed += $name }
}
$desktop = 'HKCU:\Control Panel\Desktop'; $intl = 'HKCU:\Control Panel\International'
$oldUi = (Get-ItemProperty $desktop -ErrorAction SilentlyContinue).PreferredUILanguages
$oldLocale = (Get-ItemProperty $intl).LocaleName
$oldTz = (Get-TimeZone).Id
try {
    # 1. as provisioned (English)
    $en = Probe 'english' @('--seed-language', 'en')
    Check 'language.en.detect' ($en['AppLanguage.systemDefault'] -eq 'en' -and $en['migration.after'] -eq 'en') "systemDefault=$($en['AppLanguage.systemDefault']) migration $($en['migration.before'])->$($en['migration.after'])"
    # 2. display language Korean (the user's PC): the per-user value GetUserPreferredUILanguages reads
    Set-ItemProperty $desktop PreferredUILanguages ([string[]]@('ko-KR')) -Type MultiString
    Set-ItemProperty $intl LocaleName 'ko-KR'
    $ko = Probe 'korean' @('--seed-language', 'en')
    $api = $ko['GetUserPreferredUILanguages']
    Write-Host "corelibs Locale.preferredLanguages under Korean: $($ko['Locale.preferredLanguages']) ; Locale.current=$($ko['Locale.current'])"
    if ($api -like '*ko*') {
        Check 'language.ko.detect' ($ko['AppLanguage.systemDefault'] -eq 'ko') "GetUserPreferredUILanguages=$api systemDefault=$($ko['AppLanguage.systemDefault'])"
        Check 'language.ko.tray' ($ko['tray.titles'] -like '*지금 새로고침*') "tray: $($ko['tray.titles'])"
        Check 'language.ko.migration' ($ko['migration.before'] -eq 'en' -and $ko['migration.after'] -eq 'ko') "saved en -> $($ko['migration.before'])->$($ko['migration.after'])"
    } else {
        Write-Host "::warning::the runner's GetUserPreferredUILanguages did not follow HKCU PreferredUILanguages (got '$api'); the Korean child cannot be forced here, the mapping is covered by injected-value tests"
        Check 'language.ko.forced' $false "GetUserPreferredUILanguages=$api after setting HKCU PreferredUILanguages=ko-KR"
    }
    # 3. time zone: the day boundary follows TimeZone.current
    & tzutil /s 'Korea Standard Time'
    $tz = Probe 'korea-tz'
    Check 'timezone.seoul' ($tz['TimeZone.current'] -eq 'Asia/Seoul' -and $tz['TimeZone.current.offsetMinutes'] -eq '540') "TimeZone.current=$($tz['TimeZone.current']) offset=$($tz['TimeZone.current.offsetMinutes']) Win32 key=$($tz['Win32 TimeZoneKeyName'])"
} finally {
    if ($oldUi) { Set-ItemProperty $desktop PreferredUILanguages ([string[]]$oldUi) -Type MultiString } else { Remove-ItemProperty $desktop PreferredUILanguages -ErrorAction SilentlyContinue }
    Set-ItemProperty $intl LocaleName $oldLocale
    & tzutil /s $oldTz
}
if ($failed) { Write-Host "::error::language checks failed: $($failed -join ', ')"; exit 1 }
