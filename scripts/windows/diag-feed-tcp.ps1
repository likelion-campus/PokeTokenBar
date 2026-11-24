# DIAGNOSTIC (branch diag/update-runner-loss-2 only). update-feed-server.ps1 with the same parameters, modes, answers, request log
# and port file, but served from user-mode sockets (TcpListener on 127.0.0.1 and ::1) instead of HttpListener, which on Windows
# is http.sys, a kernel driver. Experiment 5 copies it over update-feed-server.ps1 in one arm: if the lost runner needs http.sys,
# that arm never loses one. One connection at a time, "Connection: close" on every answer.
param(
    [Parameter(Mandatory)][string]$Payload,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('ok', 'tampered', 'short', 'long', 'redirect', 'badurl', 'slow')][string]$Mode = 'ok',
    [Parameter(Mandatory)][string]$PortFile,
    [Parameter(Mandatory)][string]$LogFile
)
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Payload).Path)
$name = "PokeTokenBar-Setup-$Version-win-x64.exe"
$digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
$served = switch ($Mode) {
    'tampered' { $b = [byte[]]$bytes.Clone(); $i = [int]($b.Length / 2); $b[$i] = $b[$i] -bxor 1; , $b }
    'short' { $b = [byte[]]::new($bytes.Length - 1); [Array]::Copy($bytes, $b, $b.Length); , $b }
    'long' { $b = [byte[]]::new($bytes.Length + 1); [Array]::Copy($bytes, $b, $bytes.Length); , $b }
    default { , $bytes }
}
# One port free on both loopbacks (localhost may resolve to ::1 first).
$v4 = $null; $v6 = $null
for ($try = 0; $try -lt 20 -and -not $v6; $try++) {
    $v4 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $v4.Start()
    $port = $v4.LocalEndpoint.Port
    try { $v6 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::IPv6Loopback, $port); $v6.Start() } catch { $v4.Stop(); $v6 = $null }
}
if (-not $v6) { throw 'no port free on both loopbacks' }
$path = "/releases/download/v$Version/$name"
$address = if ($Mode -eq 'badurl') { "http://127.0.0.1:$port/elsewhere/v$Version/$name" } else { "http://127.0.0.1:$port$path" }
$release = [ordered]@{
    url = "http://127.0.0.1:$port/releases/1"; tag_name = "v$Version"; name = "v$Version"
    html_url = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v$Version"
    draft = $false; prerelease = $false; created_at = '2026-11-16T00:00:00Z'; published_at = '2026-11-16T00:00:00Z'
    assets = @([ordered]@{ name = $name; label = ''; content_type = 'application/x-msdownload'; state = 'uploaded'; size = $bytes.Length
                           digest = "sha256:$digest"; browser_download_url = $address })
}
$json = [System.Text.Encoding]::UTF8.GetBytes(($release | ConvertTo-Json -Depth 5 -Compress))
Set-Content -Path $PortFile -Value $port -NoNewline
"feed (tcp): 127.0.0.1/::1 port $port, v$Version, mode $Mode, $($bytes.Length) bytes sha256 $digest, serving $($served.Length) bytes"

function Send-Head($Stream, [int]$Code, [string]$Reason, [hashtable]$Headers) {
    $sb = [System.Text.StringBuilder]::new("HTTP/1.1 $Code $Reason`r`n")
    foreach ($k in $Headers.Keys) { [void]$sb.Append("${k}: $($Headers[$k])`r`n") }
    [void]$sb.Append("Connection: close`r`n`r`n")
    $head = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($head, 0, $head.Length)
}
function Serve($client) {
    try {
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $buffer = [byte[]]::new(16384); $got = 0
        while ($got -lt $buffer.Length) {
            $n = $stream.Read($buffer, $got, $buffer.Length - $got)
            if ($n -le 0) { break }
            $got += $n
            if ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $got).Contains("`r`n`r`n")) { break }
        }
        $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $got)
        $requestLine = ($text -split "`r`n")[0] -split ' '
        $method = $requestLine[0]; $target = if ($requestLine.Count -gt 1) { $requestLine[1] } else { '/' }
        $hostLine = ($text -split "`r`n" | Where-Object { $_ -match '^(?i)host:' } | Select-Object -First 1) -replace '^(?i)host:\s*', ''
        $reqHost = ($hostLine -replace ':\d+$', '').Trim('[', ']')
        $reqPath = ($target -split '\?')[0]
        Add-Content -Path $LogFile -Value "$method $reqHost $reqPath"
        if ($reqPath -eq '/releases/latest') {
            Send-Head $stream 200 'OK' @{ 'Content-Type' = 'application/json; charset=utf-8'; 'Content-Length' = $json.Length }
            $stream.Write($json, 0, $json.Length)
        } elseif ($reqPath -eq $path -and $Mode -eq 'redirect' -and $reqHost -eq '127.0.0.1') {
            Send-Head $stream 302 'Found' @{ 'Location' = "http://localhost:$port$path"; 'Content-Length' = 0 }
        } elseif ($reqPath -eq $path -and $Mode -eq 'slow') {
            Send-Head $stream 200 'OK' @{ 'Content-Type' = 'application/octet-stream'; 'Content-Length' = $served.Length }
            for ($at = 0; $at -lt $served.Length; $at += 262144) {
                $stream.Write($served, $at, [Math]::Min(262144, $served.Length - $at)); $stream.Flush()
                Start-Sleep -Milliseconds 500
            }
        } elseif ($reqPath -eq $path) {
            Send-Head $stream 200 'OK' @{ 'Content-Type' = 'application/octet-stream'; 'Content-Length' = $served.Length }
            $stream.Write($served, 0, $served.Length)
        } else {
            Send-Head $stream 404 'Not Found' @{ 'Content-Length' = 0 }
        }
        $stream.Flush()
    } catch {
        "serve: $($_.Exception.Message)"  # the client went away (a cancel, a refusal)
    } finally {
        try { $client.Close() } catch { }
    }
}
$t4 = $v4.AcceptTcpClientAsync(); $t6 = $v6.AcceptTcpClientAsync()
while ($true) {
    $i = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($t4, $t6))
    if ($i -eq 0) { $c = $t4.Result; $t4 = $v4.AcceptTcpClientAsync() } else { $c = $t6.Result; $t6 = $v6.AcceptTcpClientAsync() }
    Serve $c
}
