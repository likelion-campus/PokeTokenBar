# Runs `PokeTokenBar.exe --language-probe` as CHILD processes under other user settings and asserts what the app does.
# Changes the CI runner's own HKCU language values and its machine time zone for the duration, and puts them back.
# Usage: check-language.ps1 -Exe bundle\PokeTokenBar.exe [-OutDir lang-probe]
param([Parameter(Mandatory)][string]$Exe, [string]$OutDir = 'lang-probe')
$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$failed = @()
function Probe([string]$name, [string[]]$extra = @()) {
    $out = Join-Path (Resolve-Path $OutDir).Path "${name}.txt"
    Remove-Item -ErrorAction SilentlyContinue $out
    $p = Start-Process -FilePath $Exe -ArgumentList (@('--language-probe', $out) + $extra) -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw "${name}: probe hung" }
    if (-not (Test-Path $out)) { throw "${name}: no output (exit $($p.ExitCode))" }
    $h = @{}; foreach ($l in Get-Content $out) { $i = $l.IndexOf('='); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
    Write-Host "---- ${name}"; Get-Content $out | ForEach-Object { Write-Host "  $_" }
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
    Check 'timezone.utc' ($en['env TZ (published)'] -like 'UTC*' -and $en['TimeZone.current.offsetMinutes'] -eq '0') "UTC runner: TimeZone.current=$($en['TimeZone.current']) TZ=$($en['env TZ (published)']) (Foundation alone gave GMT here: the zone's English StandardName 'Coordinated Universal Time' is not a Windows zone id)"
    Check 'language.en.detect' ($en['AppLanguage.systemDefault'] -eq 'en' -and $en['migration.after'] -eq 'en') "systemDefault=$($en['AppLanguage.systemDefault']) migration $($en['migration.before'])->$($en['migration.after'])"
    # 2. The whole app-side chain for a Korean display language. The runner has no Korean language pack, so its
    #    GetUserPreferredUILanguages cannot be switched (tried below, informational): the first Win32 value is injected.
    $ko = Probe 'korean-injected' @('--seed-language', 'en', '--inject-ui-language', 'ko-KR')
    Check 'language.ko.detect' ($ko['inject.detected'] -eq 'ko') "ko-KR -> $($ko['inject.detected'])"
    Check 'language.ko.tray' ($ko['inject.tray.titles'] -like '*지금 새로고침*' -and $ko['inject.tray.titles'] -like '*종료*') "tray: $($ko['inject.tray.titles'])"
    Check 'language.ko.firstRunHint' ($ko['inject.firstRunHint'] -like 'PokeTokenBar가*') "hint: $($ko['inject.firstRunHint'])"
    Check 'language.ko.migration' ($ko['migration.before'] -eq 'en' -and $ko['migration.after'] -eq 'ko') "saved en -> $($ko['migration.before'])->$($ko['migration.after'])"
    $ja = Probe 'japanese-injected' @('--inject-ui-language', 'ja-JP')
    Check 'language.ja.detect' ($ja['inject.detected'] -eq 'ja') "ja-JP -> $($ja['inject.detected'])"
    $zh = Probe 'chinese-injected' @('--inject-ui-language', 'zh-Hans-CN')
    Check 'language.zh.detect' ($zh['inject.detected'] -eq 'en') "zh-Hans-CN -> $($zh['inject.detected']) (unsupported: English, as on the Mac)"
    # Informational: can HKCU alone change what the real API returns? (Needs the language pack; expected not.)
    try {
        Set-ItemProperty $desktop PreferredUILanguages ([string[]]@('ko-KR')) -Type MultiString
        Set-ItemProperty $intl LocaleName 'ko-KR'
        $real = Probe 'korean-hkcu'
        Write-Host "INFO real GetUserPreferredUILanguages after HKCU PreferredUILanguages=ko-KR: $($real['GetUserPreferredUILanguages']); GetUserDefaultLocaleName=$($real['GetUserDefaultLocaleName']); corelibs Locale.preferredLanguages=$($real['Locale.preferredLanguages']) Locale.current=$($real['Locale.current'])"
        # Stage 7 (D11): the region seams follow the regional format HKCU now names, where corelibs stays en_001 / Monday.
        Check 'region.ko.seams' ($real['region.locale'] -like 'ko*' -and $real['region.grouped'] -eq $real['region.win32.numberInteger'] -and $real['region.firstWeekday'] -match '^[1-7]$') "HKCU LocaleName=ko-KR: region.locale=$($real['region.locale']) firstWeekday=$($real['region.firstWeekday']) (Win32 IFIRSTDAYOFWEEK=$($real['region.win32.IFIRSTDAYOFWEEK']), corelibs $($real['region.foundation.firstWeekday'])) grouped=$($real['region.grouped']) Windows=$($real['region.win32.number']) corelibs Locale.current grouped=$($real['region.foundation.grouped'])"
    } catch { Write-Host "INFO could not set the HKCU language values: $_" }
    # Stage 7 (R4): what Foundation's formatters write in the app language each display language maps to. Informational:
    # a formatter that traps ends only its own child process.
    foreach ($tag in @('ko-KR', 'ja-JP', 'en-US')) {
        try { $null = Probe "formatters-$tag" @('--inject-ui-language', $tag, '--formatter-probe') }
        catch { Write-Host "INFO formatter probe ${tag}: $_" }
    }
    try {
        $trap = Probe 'formatter-trap' @('--inject-ui-language', 'ko-KR', '--formatter-trap')
        Write-Host "INFO DateComponentsFormatter in a child process: $(if ($trap['trap.survived']) { $trap['trap.survived'] } else { 'trapped: no trap.survived line after trap.start' })"
    } catch { Write-Host "INFO formatter trap probe: $_" }
    # 2b. diagnostics: which time-zone calls trap in this build, one by one. Each crash is recorded and the run restarted past it.
    function Hunt([string]$label) {
        $hunt = Join-Path (Resolve-Path $OutDir).Path "tz-hunt-$label.txt"
        $from = 0; $crashes = @()
        for ($round = 0; $round -lt 20; $round++) {
            $hp = Start-Process -FilePath $Exe -ArgumentList @('--tz-hunt', $hunt, '--from', "$from") -PassThru; $null = $hp.Handle
            if (-not $hp.WaitForExit(60000)) { Stop-Process -Id $hp.Id -Force }
            $last = (Get-Content $hunt | Where-Object { $_ -like 'start *' } | Select-Object -Last 1)
            if ($hp.ExitCode -eq 0) { break }
            $crashes += "$last (exit $($hp.ExitCode))"
            $from = [int]($last -split ' ')[1] + 1
        }
        Write-Host "---- tz-hunt $label"; Get-Content $hunt | ForEach-Object { Write-Host "  $_" }
        Write-Host "HUNT $label crashes: $(if ($crashes) { $crashes -join ' | ' } else { 'none' })"
        $crashes
    }
    $crashesUtc = Hunt 'utc'
    Check 'timezone.noTrap.utc' (-not $crashesUtc) "calls that trap under the published UTC zone: $($crashesUtc -join ' | ')"
    # 3. time zone: the day boundary follows TimeZone.current
    & tzutil /s 'Korea Standard Time'
    $tz = Probe 'korea-tz'
    $crashesSeoul = Hunt 'seoul'
    Check 'timezone.noTrap.seoul' (-not $crashesSeoul) "calls that trap under the published Seoul zone: $($crashesSeoul -join ' | ')"
    Check 'timezone.seoul' ($tz['TimeZone.current'] -eq 'Asia/Seoul' -and $tz['TimeZone.current.offsetMinutes'] -eq '540' -and $tz['env TZ (published)'] -like 'Asia/Seoul*') "TimeZone.current=$($tz['TimeZone.current']) offset=$($tz['TimeZone.current.offsetMinutes']) Win32 key=$($tz['Win32 TimeZoneKeyName'])"
} finally {
    if ($oldUi) { Set-ItemProperty $desktop PreferredUILanguages ([string[]]$oldUi) -Type MultiString } else { Remove-ItemProperty $desktop PreferredUILanguages -ErrorAction SilentlyContinue }
    Set-ItemProperty $intl LocaleName $oldLocale
    & tzutil /s $oldTz
}
if ($failed) { Write-Host "::error::language checks failed: $($failed -join ', ')"; exit 1 }
