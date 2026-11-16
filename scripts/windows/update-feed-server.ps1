# A loopback stand-in for GitHub's release feed and asset download (windows-app.yml, step in-app-update; in-app-update.ps1
# starts one per scenario as its own process and stops it). Listens on 127.0.0.1 and localhost (the redirect's other host)
# until stopped:
#   GET /releases/latest                          the latest release for -Version in GitHub's shape: tag v<V>, not a draft or
#                                                 prerelease, one installer asset named PokeTokenBar-Setup-<V>-win-x64.exe, state
#                                                 uploaded, -Payload's size and "sha256:<hex>" digest, its address on this server
#   GET /releases/download/v<V>/<that name>       the bytes, as -Mode says
# -Mode: ok | tampered (one byte in the middle flipped, same size) | short (one byte less) | long (one byte more) |
#        redirect (302 from 127.0.0.1 to the same path on localhost, which serves the bytes) | badurl (the JSON's address is
#        off the release pattern) | slow (the bytes in 256 KiB pieces, 0.5 s apart)
# The size and digest in the JSON are always -Payload's own. Each request is appended to -LogFile as "<method> <host> <path>";
# the port it chose is written to -PortFile once it listens. Nothing leaves the machine.
# Usage: pwsh -File update-feed-server.ps1 -Payload <exe> -Version 2.5.641 -Mode ok -PortFile port.txt -LogFile requests.log
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
# The bytes served (byte arrays copied, never sliced: a PowerShell slice of 33 MB is an object array).
$served = switch ($Mode) {
    'tampered' { $b = [byte[]]$bytes.Clone(); $i = [int]($b.Length / 2); $b[$i] = $b[$i] -bxor 1; , $b }
    'short' { $b = [byte[]]::new($bytes.Length - 1); [Array]::Copy($bytes, $b, $b.Length); , $b }
    'long' { $b = [byte[]]::new($bytes.Length + 1); [Array]::Copy($bytes, $b, $bytes.Length); , $b }
    default { , $bytes }
}

$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

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
"feed: 127.0.0.1:$port, v$Version, mode $Mode, $($bytes.Length) bytes sha256 $digest, serving $($served.Length) bytes"

function Send-Body($Response, [byte[]]$Body, [string]$Type) {
    $Response.ContentType = $Type
    $Response.ContentLength64 = $Body.Length
    $Response.OutputStream.Write($Body, 0, $Body.Length)
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    Add-Content -Path $LogFile -Value "$($request.HttpMethod) $($request.Url.Host) $($request.Url.AbsolutePath)"
    try {
        if ($request.Url.AbsolutePath -eq '/releases/latest') {
            Send-Body $response $json 'application/json; charset=utf-8'
        } elseif ($request.Url.AbsolutePath -eq $path -and $Mode -eq 'redirect' -and $request.Url.Host -eq '127.0.0.1') {
            $response.StatusCode = 302
            $response.RedirectLocation = "http://localhost:$port$path"
            $response.ContentLength64 = 0
        } elseif ($request.Url.AbsolutePath -eq $path -and $Mode -eq 'slow') {
            $response.ContentType = 'application/octet-stream'
            $response.ContentLength64 = $served.Length
            for ($at = 0; $at -lt $served.Length; $at += 262144) {
                $response.OutputStream.Write($served, $at, [Math]::Min(262144, $served.Length - $at))
                $response.OutputStream.Flush()
                Start-Sleep -Milliseconds 500
            }
        } elseif ($request.Url.AbsolutePath -eq $path) {
            Send-Body $response $served 'application/octet-stream'
        } else {
            $response.StatusCode = 404
            $response.ContentLength64 = 0
        }
    } catch {
        "serve $($request.Url.AbsolutePath): $($_.Exception.Message)"  # the client went away (a cancel, a refusal)
    } finally {
        try { $response.Close() } catch { }
    }
}
