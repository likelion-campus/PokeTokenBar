# Diagnostic probe (runner only): which notification sources can be seen on this machine, and what the user-language
# APIs say. Prints facts; changes only HKCU values under the CI runner's own profile, never shipped code.
# Usage: probe-notifications.ps1 -OutDir <dir> [-Enable] [-Sources ps,forms,none]
param([Parameter(Mandatory)][string]$OutDir, [switch]$Enable, [string[]]$Sources = @('forms','toast'))
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $OutDir | Out-Null
Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class PtbProbe {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserPreferredUILanguages(uint f, out uint n, StringBuilder b, ref uint len);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern int GetUserDefaultLocaleName(StringBuilder b, int len);
  [DllImport("kernel32.dll")] public static extern ushort GetUserDefaultUILanguage();
  [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("kernel32.dll")] public static extern bool ProcessIdToSessionId(uint pid, out uint sid);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@
function Shot([string]$name) {
  $b = New-Object System.Drawing.Bitmap ([System.Windows.Forms.SystemInformation]::VirtualScreen.Width), ([System.Windows.Forms.SystemInformation]::VirtualScreen.Height)
  $g = [System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
  $b.Save((Join-Path $OutDir "$name.png")); $g.Dispose(); $b.Dispose()
}
function Pixels([string]$a, [string]$b) {
  $x = [System.Drawing.Bitmap]::FromFile((Join-Path $OutDir "$a.png")); $y = [System.Drawing.Bitmap]::FromFile((Join-Path $OutDir "$b.png"))
  $n = 0; for ($j = 0; $j -lt $x.Height; $j += 2) { for ($i = 0; $i -lt $x.Width; $i += 2) { if ($x.GetPixel($i, $j).ToArgb() -ne $y.GetPixel($i, $j).ToArgb()) { $n++ } } }
  $x.Dispose(); $y.Dispose(); $n
}
function Windows-Dump([string]$tag) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($k in $kids) { "{0} uia[{1}] class='{2}' name='{3}' pid={4} rect={5}" -f $tag, $kids.Count, $k.Current.ClassName, $k.Current.Name, $k.Current.ProcessId, $k.Current.BoundingRectangle }
}
"== machine"
(Get-CimInstance Win32_OperatingSystem | ForEach-Object { "{0} build {1}" -f $_.Caption, $_.BuildNumber })
$sid = 0; [void][PtbProbe]::ProcessIdToSessionId($PID, [ref]$sid); "session id=$sid console=$([PtbProbe]::WTSGetActiveConsoleSessionId()) SESSIONNAME=$env:SESSIONNAME  SM_REMOTESESSION=$([PtbProbe]::GetSystemMetrics(0x1000))"
"== languages"
$len = 0; $n = 0; [void][PtbProbe]::GetUserPreferredUILanguages(8, [ref]$n, $null, [ref]$len)
$sb = New-Object System.Text.StringBuilder $len; [void][PtbProbe]::GetUserPreferredUILanguages(8, [ref]$n, $sb, [ref]$len)
"GetUserPreferredUILanguages: n=$n " + ($sb.ToString().Replace([char]0, '|'))
$sl = New-Object System.Text.StringBuilder 100; [void][PtbProbe]::GetUserDefaultLocaleName($sl, 100); "GetUserDefaultLocaleName: $sl"
"GetUserDefaultUILanguage: 0x{0:x4}" -f [PtbProbe]::GetUserDefaultUILanguage()
"Get-WinUserLanguageList: " + ((Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ',')
"HKCU Desktop PreferredUILanguages: " + ((Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).PreferredUILanguages -join ',')
"HKCU International LocaleName: " + (Get-ItemProperty 'HKCU:\Control Panel\International' -ErrorAction SilentlyContinue).LocaleName
"TimeZone: " + (Get-TimeZone).Id
"== notification settings"
foreach ($p in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications', 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer') {
  if (Test-Path $p) { "$p : " + ((Get-ItemProperty $p | Get-Member -MemberType NoteProperty | Where-Object Name -notlike 'PS*' | ForEach-Object { "$($_.Name)=$((Get-ItemProperty $p).($_.Name))" }) -join '; ') + " ; subkeys=" + ((Get-ChildItem $p -ErrorAction SilentlyContinue | ForEach-Object PSChildName) -join ',') } else { "$p : (absent)" }
}
"Get-Service WpnService: " + (Get-Service WpnService -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Status)/$($_.StartType)" })
"Get-Service WpnUserService*: " + ((Get-Service 'WpnUserService*' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Status)" }) -join ',')
"Processes: " + ((Get-Process ShellExperienceHost, explorer, StartMenuExperienceHost, TextInputHost -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) -join ',')
if ($Enable) {
  "== enabling toasts for the test (HKCU of this runner profile only)"
  $pn = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; New-Item -Force $pn | Out-Null
  Set-ItemProperty $pn ToastEnabled 1 -Type DWord
  $ns = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; New-Item -Force $ns | Out-Null
  Set-ItemProperty $ns NOC_GLOBAL_SETTING_TOASTS_ENABLED 1 -Type DWord -ErrorAction SilentlyContinue
}
Shot 'before'
Windows-Dump 'before'
if ($Sources -contains 'forms') {
  "== System.Windows.Forms.NotifyIcon.ShowBalloonTip (legacy balloon from a known-good source)"
  $ni = New-Object System.Windows.Forms.NotifyIcon
  $ni.Icon = [System.Drawing.SystemIcons]::Information; $ni.Visible = $true
  $shown = $false; Register-ObjectEvent $ni BalloonTipShown -Action { $script:shown = $true } | Out-Null
  $ni.ShowBalloonTip(20000, 'PTB probe forms', 'WinForms balloon from the runner', [System.Windows.Forms.ToolTipIcon]::Info)
  foreach ($t in 1..4) { Start-Sleep -Seconds 1; [System.Windows.Forms.Application]::DoEvents() }
  Shot 'forms-after'; "forms: pixels changed vs before = $(Pixels 'before' 'forms-after'); BalloonTipShown event seen=$shown"
  Windows-Dump 'forms'
  $ni.Visible = $false; $ni.Dispose()
}
if ($Sources -contains 'toast') {
  "== WinRT toast with the Windows PowerShell AUMID (known-good source)"
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>PTB probe toast</text><text>WinRT toast from the runner</text></binding></visual></toast>')
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid)
    "notifier.Setting = " + $notifier.Setting
    $notifier.Show($toast)
    foreach ($t in 1..4) { Start-Sleep -Seconds 1 }
    Shot 'toast-after'; "toast: pixels changed vs before = $(Pixels 'before' 'toast-after')"
    Windows-Dump 'toast'
  } catch { "toast failed: $_" }
}
