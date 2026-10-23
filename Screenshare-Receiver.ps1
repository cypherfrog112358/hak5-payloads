<#
================================================================================
 Screenshare over LAN - EMPFAENGER (reine PowerShell, kein Python)

 Nimmt JPEG-Bilder von "Screenshare-Over-LAN-V2" (Sender) per HTTP an und zeigt
 sie im Browser. Meldet sich per UDP-Broadcast im LAN an, damit der Sender
 automatisch findet, wohin er senden soll - keine IP eintragen, nichts
 konfigurieren.

 Start:  Screenshare-Receiver.cmd doppelklicken (oder dieses Skript ausfuehren)
 Danach im Browser eines beliebigen Geraets im LAN:  http://<IP>:8090/

 Beim ersten Start fragt die Windows-Firewall einmal - "Zulassen" klicken.
 Mit Administratorrechten wird die Regel automatisch angelegt.
================================================================================
#>

$port          = 8090        # HTTP-Port des Empfaengers
$discoveryPort = 8100        # UDP-Port fuer die automatische Erkennung
$announceSeconds = 2         # wie oft sich der Empfaenger anmeldet
$openBrowser   = 1           # 1 = Browser mit der Ansicht oeffnen
$logFile       = $null       # z. B. 'C:\Temp\receiver.log'

$selfPath = $MyInvocation.MyCommand.Path
$isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Logdatei ---------------------------------------------------------------
if (-not $logFile) {
    try {
        $selfDir = Split-Path -Parent $selfPath
        if (-not $selfDir) { $selfDir = (Get-Location).Path }
        $logFile = Join-Path $selfDir 'screenshare-receiver.log'
    } catch { $logFile = $null }
}
function Write-Log([string]$msg) {
    try {
        if ($logFile) {
            Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
        }
    } catch { }
}
try {
    [Console]::Title = "Screenshare Empfaenger"
    [Console]::BackgroundColor = "Black"
    [Console]::ForegroundColor = "Gray"
    Clear-Host
} catch { }

# --- lokale IP (Interface mit Standardroute) --------------------------------
function Get-LocalIP {
    $ip = $null
    try {
        $alias = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                  Sort-Object -Property RouteMetric | Select-Object -First 1).InterfaceAlias
        if ($alias) {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $alias -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
        }
    } catch { }
    if (-not $ip) {
        try {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                   Select-Object -First 1).IPAddress
        } catch { }
    }
    if (-not $ip) { $ip = '127.0.0.1' }
    return $ip
}
$localIP = Get-LocalIP

# --- Firewall-Regel (nur mit Adminrechten moeglich) -------------------------
if ($isAdmin) {
    try {
        Get-NetFirewallRule -DisplayName "Screenshare Receiver" -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "Screenshare Receiver" -Direction Inbound -Protocol TCP `
            -LocalPort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Firewall-Regel fuer TCP $port angelegt"
    } catch { }
}

# --- gemeinsamer Zustand (zwischen Runspaces geteilt) -----------------------
$state = [hashtable]::Synchronized(@{ frame = $null; ts = 0.0; size = 0; client = ''; count = 0 })

# --- HTTP-Listener ----------------------------------------------------------
if ($port -lt 1) { $port = 8090 }
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
    $listener.Start()
} catch {
    Write-Host ("Port " + $port + " ist belegt - laeuft der Empfaenger schon?") -ForegroundColor Yellow
    try {
        $st = Invoke-RestMethod -Uri ("http://127.0.0.1:" + $port + "/status") -TimeoutSec 3
        Write-Host ("Es laeuft bereits ein Empfaenger (" + $st.count + " Bilder empfangen).") -ForegroundColor Yellow
        if ($openBrowser -eq 1) { Start-Process ("http://127.0.0.1:" + $port + "/") | Out-Null }
    } catch {
        Write-Host "Der Port wird von einem anderen Programm benutzt." -ForegroundColor Red
    }
    exit 1
}
Write-Log ("Empfaenger gestartet. ip=" + $localIP + " port=" + $port + " admin=" + $isAdmin)

Write-Host ""
Write-Host "  Screenshare-Empfaenger laeuft" -ForegroundColor Green
Write-Host ("  Ansicht im Browser:  http://" + $localIP + ":" + $port + "/") -ForegroundColor White
Write-Host ("  Wartet auf Sender im LAN (UDP " + $discoveryPort + "), Beenden mit STRG+C") -ForegroundColor DarkGray
Write-Host ""

# --- Anmeldung im LAN (UDP-Broadcast) ---------------------------------------
$bcast = @('255.255.255.255', '127.0.0.1')
try {
    $parts = $localIP.Split('.')
    if ($parts.Count -eq 4) { $bcast += ($parts[0] + '.' + $parts[1] + '.' + $parts[2] + '.255') }
} catch { }

$announceWorker = {
    param($discoveryPort, $ip, $port, $seconds, $targets)
    $udp = New-Object System.Net.Sockets.UdpClient
    try { $udp.EnableBroadcast = $true } catch { }
    $msg = [System.Text.Encoding]::ASCII.GetBytes("SCREENSHARE2|" + $ip + "|" + $port)
    while ($true) {
        foreach ($t in $targets) {
            try {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($t), $discoveryPort)
                [void]$udp.Send($msg, $msg.Length, $ep)
            } catch { }
        }
        Start-Sleep -Seconds $seconds
    }
}
try {
    $rsAnn = [runspacefactory]::CreateRunspace()
    $rsAnn.Open()
    $psAnn = [powershell]::Create()
    $psAnn.Runspace = $rsAnn
    [void]$psAnn.AddScript($announceWorker)
    [void]$psAnn.AddArgument($discoveryPort)
    [void]$psAnn.AddArgument($localIP)
    [void]$psAnn.AddArgument($port)
    [void]$psAnn.AddArgument($announceSeconds)
    [void]$psAnn.AddArgument($bcast)
    [void]$psAnn.BeginInvoke()
} catch {
    Write-Log ("Anmeldung (UDP) fehlgeschlagen: " + $_.Exception.Message)
}

if ($openBrowser -eq 1) {
    try { Start-Process ("http://" + $localIP + ":" + $port + "/") | Out-Null } catch { }
}

# --- HTML-Ansicht -----------------------------------------------------------
$page = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Screenshare</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
 html, body { margin: 0; padding: 0; background: #000; width: 100%; height: 100%; overflow: hidden; }
 img { display: block; position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; object-fit: contain; object-position: center center; background: #000; }
 #info { position: fixed; left: 8px; bottom: 8px; color: #8f8; font: 12px monospace; background: rgba(0,0,0,0.65); padding: 4px 8px; border-radius: 4px; }
</style>
</head>
<body>
<img src="/stream" alt="Screenshare">
<div id="info">verbinde ...</div>
<script>
async function tick() {
  try {
    const r = await fetch('/status', { cache: 'no-store' });
    const d = await r.json();
    document.getElementById('info').textContent = d.ts
      ? 'Empfangen ' + new Date(d.ts * 1000).toLocaleTimeString() + '   ' + d.size + ' B   von ' + d.client + '   (' + d.count + ' Bilder)'
      : 'noch keine Bilder';
  } catch (e) { document.getElementById('info').textContent = 'keine Verbindung'; }
}
setInterval(tick, 1000); tick();
</script>
</body>
</html>
"@

# --- HTTP-Hilfsfunktionen ---------------------------------------------------
function Read-Request($client) {
    $stream = $client.GetStream()
    $buf = New-Object byte[] 16384
    $ms = New-Object System.IO.MemoryStream
    $headerEnd = -1
    $deadline = (Get-Date).AddSeconds(10)
    $all = $null
    while ($headerEnd -lt 0 -and (Get-Date) -lt $deadline) {
        if (-not $stream.DataAvailable) {
            if ($ms.Length -gt 0) { Start-Sleep -Milliseconds 2 } else { Start-Sleep -Milliseconds 5 }
            continue
        }
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $all = $ms.ToArray()
        for ($i = 0; $i -le $all.Length - 4; $i++) {
            if ($all[$i] -eq 13 -and $all[$i+1] -eq 10 -and $all[$i+2] -eq 13 -and $all[$i+3] -eq 10) {
                $headerEnd = $i + 4
                break
            }
        }
    }
    if ($headerEnd -lt 0 -or -not $all) { return $null }

    $head = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $head -split "`r`n"
    $requestLine = $lines[0]
    $method = ''
    $target = ''
    $pieces = $requestLine.Split(' ')
    if ($pieces.Count -ge 2) { $method = $pieces[0]; $target = $pieces[1] }

    $len = 0
    foreach ($l in $lines) {
        if ($l -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] }
    }

    $body = New-Object System.IO.MemoryStream
    $have = $all.Length - $headerEnd
    if ($have -gt 0) { $body.Write($all, $headerEnd, $have) }
    while ($body.Length -lt $len) {
        if (-not $stream.DataAvailable) {
            if ((Get-Date) -gt $deadline) { break }
            Start-Sleep -Milliseconds 2
            continue
        }
        $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $len - [int]$body.Length))
        if ($n -le 0) { break }
        $body.Write($buf, 0, $n)
    }
    return @{ method = $method; target = $target; body = $body.ToArray() }
}

function Send-Response($client, $status, $ctype, [byte[]]$body, $extra) {
    try {
        $head = "HTTP/1.1 " + $status + "`r`nContent-Type: " + $ctype + "`r`nContent-Length: " + $body.Length +
                "`r`nCache-Control: no-store`r`nConnection: close`r`n"
        if ($extra) { $head += $extra }
        $head += "`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $s = $client.GetStream()
        $s.Write($hb, 0, $hb.Length)
        if ($body.Length -gt 0) { $s.Write($body, 0, $body.Length) }
        $s.Flush()
    } catch { }
    try { $client.Close() } catch { }
}

# --- Stream-Worker (eigener Runspace, blockiert die Annahme nicht) ----------
$streamWorker = {
    param($client, $state)
    try {
        $s = $client.GetStream()
        $head = "HTTP/1.1 200 OK`r`nContent-Type: multipart/x-mixed-replace; boundary=frame`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $s.Write($hb, 0, $hb.Length)
        $s.Flush()
        while ($true) {
            $f = $state['frame']
            if ($f) {
                $hdr = [System.Text.Encoding]::ASCII.GetBytes("--frame`r`nContent-Type: image/jpeg`r`nContent-Length: " + $f.Length + "`r`n`r`n")
                $s.Write($hdr, 0, $hdr.Length)
                $s.Write($f, 0, $f.Length)
                $tail = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
                $s.Write($tail, 0, $tail.Length)
                $s.Flush()
            }
            Start-Sleep -Milliseconds 100
        }
    } catch { }
    try { $client.Close() } catch { }
}

# --- Annahme-Schleife -------------------------------------------------------
while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $req = Read-Request $client
        if (-not $req) { try { $client.Close() } catch { }; continue }

        $path = $req.target
        if ($path.Contains('?')) { $path = $path.Substring(0, $path.IndexOf('?')) }

        if ($req.method -eq 'POST' -and $path -eq '/upload') {
            $data = $req.body
            if ($data.Length -lt 4 -or $data[0] -ne 0xFF -or $data[1] -ne 0xD8) {
                Send-Response $client '400 Bad Request' 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('not a jpeg')) $null
                continue
            }
            $state['frame'] = $data
            $state['ts'] = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
            $state['size'] = $data.Length
            $state['client'] = ($client.Client.RemoteEndPoint.Address).ToString()
            $state['count'] = $state['count'] + 1
            Send-Response $client '204 No Content' 'text/plain' (New-Object byte[] 0) $null
        }
        elseif ($req.method -eq 'GET' -and $path -eq '/stream') {
            try {
                $rs = [runspacefactory]::CreateRunspace()
                $rs.Open()
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript($streamWorker)
                [void]$ps.AddArgument($client)
                [void]$ps.AddArgument($state)
                [void]$ps.BeginInvoke()
            } catch {
                try { $client.Close() } catch { }
            }
        }
        elseif ($req.method -eq 'GET' -and $path -eq '/latest.jpg') {
            $f = $state['frame']
            if ($f) {
                Send-Response $client '200 OK' 'image/jpeg' $f $null
            } else {
                Send-Response $client '404 Not Found' 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('no frame')) $null
            }
        }
        elseif ($req.method -eq 'GET' -and $path -eq '/status') {
            $json = '{"ts":' + ([string]$state['ts']).Replace(',', '.') + ',"size":' + $state['size'] +
                    ',"client":"' + $state['client'] + '","count":' + $state['count'] + '}'
            Send-Response $client '200 OK' 'application/json' ([System.Text.Encoding]::ASCII.GetBytes($json)) $null
        }
        elseif ($req.method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Send-Response $client '200 OK' 'text/html; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($page)) $null
        }
        else {
            Send-Response $client '404 Not Found' 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('not found')) $null
        }
    } catch {
        Write-Log ("Fehler: " + $_.Exception.Message)
        try { if ($client) { $client.Close() } } catch { }
        Start-Sleep -Milliseconds 100
    }
}
