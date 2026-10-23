<#
================================================================================
 Screenshare over LAN - V2 (ein Skript, kein Empfaenger noetig)

 Nimmt den Bildschirm auf und stellt ihn DIREKT per HTTP im LAN bereit.
 Auf dem Ziel wird nur dieses Skript gestartet - danach im Browser eines
 beliebigen Geraets im selben LAN aufrufen:

     http://<IP-des-Ziels>:8080/

 Die IP-Adresse wird automatisch ermittelt und in einem CMD-Fenster sowie als
 Sprechblase angezeigt. Es wird kein zusaetzliches Programm und keine Datei
 auf dem anzeigenden Geraet benoetigt.

 Technik: eigener TCP-Server statt HTTP.sys -> keine URL-Reservierung, kein
 Adminrecht zum Starten noetig. Fuer den Zugriff aus dem LAN muss die Firewall
 den Port einmal zulassen (mit Adminrechten wird die Regel automatisch
 angelegt, sonst fragt Windows beim ersten Zugriff).

 Beenden: ESC auf dem Ziel 5 Sekunden gedrueckt halten.
 Optional:  -RemoveAutostart   entfernt den Autostart-Eintrag wieder.
================================================================================
#>

param(
    [switch]$RemoveAutostart
)

$port          = 8080        # HTTP-Port
$fps           = 20          # Bilder pro Sekunde
$jpegQuality   = 70          # 10-100
$maxWidth      = 1600        # 0 = nicht verkleinern
$captureAll    = 0           # 0 = primaerer Monitor, 1 = alle Monitore
$hide          = 1           # 1 = Konsolenfenster ausblenden
$showInfo      = 1           # 1 = CMD-Fenster mit Aufruf-URL oeffnen
$exitSeconds   = 5           # ESC-Dauer zum Beenden
$autostart     = 1           # 1 = bei jeder Anmeldung automatisch starten
$logFile       = $null       # z. B. 'C:\Temp\screenshare-v2.log'

$selfPath = $MyInvocation.MyCommand.Path
$isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Logdatei ---------------------------------------------------------------
if (-not $logFile) {
    try {
        $selfDir = Split-Path -Parent $selfPath
        if (-not $selfDir) { $selfDir = (Get-Location).Path }
        $logFile = Join-Path $selfDir 'screenshare-v2.log'
    } catch { $logFile = $null }
}
function Write-Log([string]$msg) {
    try {
        if ($logFile) {
            Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
        }
    } catch { }
}

# --- Autostart --------------------------------------------------------------
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'Screenshare-Over-LAN-V2'
if ($RemoveAutostart) {
    try { Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue } catch { }
    Write-Log "Autostart entfernt"
    Write-Host "Autostart entfernt." -ForegroundColor Green
    exit
}

Write-Log ("Start (V2). admin=" + $isAdmin + " pid=" + $pid + " pfad=" + $selfPath)

# --- Vorherige Instanz beenden (gleicher Pfad) ------------------------------
try {
    if ($selfPath) {
        $me = $pid
        $old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
               Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine -like ('*' + $selfPath + '*') }
        foreach ($o in $old) {
            Write-Log ("Beende vorherige Instanz PID " + $o.ProcessId)
            Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($old) { Start-Sleep -Milliseconds 800 }
    }
} catch { }

# ------------------------------------------------- DPI: Voraussetzung fuer Capture
# PowerShell ist per Default nicht DPI-aware -> CopyFromScreen liefert auf
# skalierten Displays nur die obere linke Ecke. Gleiche Logik wie in V1.
Add-Type @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct SS_POINT { public int X; public int Y; }
public class ScreenInfo {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("gdi32.dll")]  public static extern int GetDeviceCaps(IntPtr hdc, int index);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(SS_POINT pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetScaleFactorForMonitor(IntPtr hmon, out int scale);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint dpiX, out uint dpiY);
}
"@
$setDpiAware = [ScreenInfo]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    [Console]::BackgroundColor = "Black"
    Clear-Host
    [Console]::SetWindowSize(88, 24)
    [Console]::Title = "Screenshare"
} catch { }

$physW = 0; $physH = 0
try {
    $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
          Where-Object { $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0 } |
          Select-Object -First 1
    if ($vc) {
        $physW = [int]$vc.CurrentHorizontalResolution
        $physH = [int]$vc.CurrentVerticalResolution
    }
} catch { }

$scalePct = 0
$effDpi = 0
try {
    $pt = New-Object SS_POINT
    $pt.X = 10; $pt.Y = 10
    $hmon = [ScreenInfo]::MonitorFromPoint($pt, 2)
    if ($hmon -ne [IntPtr]::Zero) {
        [void][ScreenInfo]::GetScaleFactorForMonitor($hmon, [ref]$scalePct)
        $dx = 0; $dy = 0
        [void][ScreenInfo]::GetDpiForMonitor($hmon, 0, [ref]$dx, [ref]$dy)
        $effDpi = [int]$dx
    }
} catch { }

if ($captureAll -eq 1) {
    $srcRect = [System.Windows.Forms.SystemInformation]::VirtualScreen
} else {
    $srcRect = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
}

$scaleFactor = 1.0
if ($scalePct -gt 0) {
    $realDpi = [int]($scalePct * 96 / 100)
    if ($effDpi -gt 0 -and $effDpi -lt $realDpi) { $scaleFactor = $scalePct / 100.0 }
}
if ($scaleFactor -eq 1.0 -and $physW -gt 0 -and $srcRect.Width -gt 0 -and $srcRect.Width -lt $physW) {
    $scaleFactor = $physW / [double]$srcRect.Width
}

$captureW = [int][Math]::Round($srcRect.Width  * $scaleFactor)
$captureH = [int][Math]::Round($srcRect.Height * $scaleFactor)
if ($captureW -lt 1) { $captureW = $srcRect.Width }
if ($captureH -lt 1) { $captureH = $srcRect.Height }

$hdc = [ScreenInfo]::GetDC([IntPtr]::Zero)
$screenDpi = [ScreenInfo]::GetDeviceCaps($hdc, 88)
[ScreenInfo]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null
if ($screenDpi -lt 72 -or $screenDpi -gt 960) { $screenDpi = 96 }

Write-Log ("Capture: " + $captureW + "x" + $captureH + " (logisch " + $srcRect.Width + "x" + $srcRect.Height +
           ", scale=" + $scalePct + "% effDpi=" + $effDpi + " screenDpi=" + $screenDpi + " aware=" + $setDpiAware + ")")

# --- eigene IP-Adresse (Interface mit Standardroute) ------------------------
$localIP = $null
try {
    $alias = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
              Sort-Object -Property RouteMetric | Select-Object -First 1).InterfaceAlias
    if ($alias) {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $alias -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
    }
} catch { }
if (-not $localIP) {
    try {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1).IPAddress
    } catch { }
}
if (-not $localIP) { $localIP = '127.0.0.1' }
$urlText = 'http://' + $localIP + ':' + $port + '/'
Write-Log ("IP: " + $localIP + "  URL: " + $urlText)

# --- Firewall: Regel anlegen (nur mit Adminrechten moeglich) ---------------
if ($isAdmin) {
    try {
        Get-NetFirewallRule -DisplayName "Screenshare Over LAN" -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "Screenshare Over LAN" -Direction Inbound -Protocol TCP `
            -LocalPort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Firewall-Regel fuer TCP $port angelegt"
    } catch { Write-Log ("Firewall-Regel fehlgeschlagen: " + $_.Exception.Message) }
}

# --- Autostart (HKCU, ohne Adminrechte) ------------------------------------
if ($autostart -eq 1 -and $selfPath) {
    try {
        $runCmd = 'powershell -w h -ExecutionPolicy Bypass -File "' + $selfPath + '"'
        Set-ItemProperty -Path $runKey -Name $runName -Value $runCmd -ErrorAction Stop
        Write-Log "Autostart eingetragen"
    } catch { Write-Log ("Autostart fehlgeschlagen: " + $_.Exception.Message) }
}

# --- TCP-Server (kein HTTP.sys, kein urlacl) -------------------------------
if ($port -lt 1 -or $port -gt 65535) { $port = 8080 }
$listener = $null
try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
    $listener.Start()
} catch {
    Write-Log ("Port " + $port + " nicht bindbar: " + $_.Exception.Message)
    Write-Host ("Port " + $port + " ist belegt.") -ForegroundColor Red
    exit 1
}
Write-Log ("Server laeuft auf " + $urlText)

# --- Hinweis + Info-Fenster -------------------------------------------------
$notify = $null
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "Screenshare aktiv"
    $notify.BalloonTipText = ("Im Browser aufrufen: " + $urlText)
    $notify.Visible = $true
    $notify.ShowBalloonTip(8000)
} catch { }

if ($showInfo -eq 1) {
    try {
        $infoCmd = 'title Screenshare & echo. & echo   Im Browser aufrufen:  ' + $urlText +
                   ' & echo. & echo   Gleiches LAN noetig. Beim ersten Zugriff Firewall bestaetigen.' +
                   ' & echo. & echo   Beenden: ESC auf dem Ziel 5 Sekunden halten. & echo.'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', $infoCmd | Out-Null
        Write-Log "Info-Fenster (cmd) geoeffnet"
    } catch { Write-Log ("Info-Fenster fehlgeschlagen: " + $_.Exception.Message) }
}

# Code to hide the console on Windows 10 and 11
if ($hide -eq 1){
    Start-Sleep -Seconds 4
    try {
        $Async = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
        $Type = Add-Type -MemberDefinition $Async -name Win32ShowWindowAsync2 -namespace Win32Functions2 -PassThru
        $hwnd = (Get-Process -PID $pid).MainWindowHandle
        if ($hwnd -ne [System.IntPtr]::Zero) {
            $Type::ShowWindowAsync($hwnd, 0)
        } else {
            $Host.UI.RawUI.WindowTitle = 'hideme2'
            $Proc = (Get-Process | Where-Object { $_.MainWindowTitle -eq 'hideme2' })
            $Type::ShowWindowAsync($Proc.MainWindowHandle, 0)
        }
    } catch { }
}

# Escape to exit key detection
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Keyboard2
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@
$VK_ESCAPE = 0x1B
$startTime = $null

# JPEG-Encoder einmalig vorbereiten
$jpegCodec = $null
try {
    $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                 Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
} catch { }
$encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$jpegQuality)

$frameInterval = [int](1000 / $fps)
if ($frameInterval -lt 20) { $frameInterval = 20 }

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
</style>
</head>
<body>
<img src="/stream" alt="Screenshare">
</body>
</html>
"@
$pageBytes = [System.Text.Encoding]::UTF8.GetBytes($page)

# --- HTTP-Hilfsfunktionen ---------------------------------------------------
function Read-Request($client) {
    $stream = $client.GetStream()
    $buf = New-Object byte[] 16384
    $ms = New-Object System.IO.MemoryStream
    $headerEnd = -1
    $deadline = (Get-Date).AddSeconds(5)
    $all = $null
    while ($headerEnd -lt 0 -and (Get-Date) -lt $deadline) {
        if (-not $stream.DataAvailable) { Start-Sleep -Milliseconds 5; continue }
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
    $pieces = $lines[0].Split(' ')
    $method = ''
    $target = ''
    if ($pieces.Count -ge 2) { $method = $pieces[0]; $target = $pieces[1] }
    return @{ method = $method; target = $target }
}

function Send-Response($client, $status, $ctype, [byte[]]$body) {
    try {
        $head = "HTTP/1.1 " + $status + "`r`nContent-Type: " + $ctype + "`r`nContent-Length: " + $body.Length +
                "`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $s = $client.GetStream()
        $s.Write($hb, 0, $hb.Length)
        if ($body.Length -gt 0) { $s.Write($body, 0, $body.Length) }
        $s.Flush()
    } catch { }
    try { $client.Close() } catch { }
}

# --- Stream-Worker: nimmt auf und schreibt direkt in die Verbindung --------
$streamWorker = {
    param($client, $capW, $capH, $dpi, $maxW, $interval, $rect, $codec, $params)
    $s = $client.GetStream()
    try {
        $head = "HTTP/1.1 200 OK`r`nContent-Type: multipart/x-mixed-replace; boundary=frame`r`nCache-Control: no-store`r`nPragma: no-cache`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $s.Write($hb, 0, $hb.Length)
        $s.Flush()

        $next = Get-Date
        while ($true) {
            $bitmap = [System.Drawing.Bitmap]::new($capW, $capH)
            $bitmap.SetResolution($dpi, $dpi)
            $gfx = [System.Drawing.Graphics]::FromImage($bitmap)
            $gfx.CopyFromScreen($rect.X, $rect.Y, 0, 0, (New-Object System.Drawing.Size($capW, $capH)))
            $gfx.Dispose()

            if ($maxW -gt 0 -and $capW -gt $maxW) {
                $newHeight = [int][Math]::Round($capH * ($maxW / $capW))
                $small = [System.Drawing.Bitmap]::new($maxW, $newHeight)
                $small.SetResolution($dpi, $dpi)
                $g2 = [System.Drawing.Graphics]::FromImage($small)
                $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g2.DrawImage($bitmap, 0, 0, $maxW, $newHeight)
                $g2.Dispose()
                $bitmap.Dispose()
                $bitmap = $small
            }

            $ms = New-Object System.IO.MemoryStream
            if ($codec) {
                $bitmap.Save($ms, $codec, $params)
            } else {
                $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            }
            $bitmap.Dispose()
            $bytes = $ms.ToArray()
            $ms.Dispose()

            $hdr = [System.Text.Encoding]::ASCII.GetBytes("--frame`r`nContent-Type: image/jpeg`r`nContent-Length: " + $bytes.Length + "`r`n`r`n")
            $s.Write($hdr, 0, $hdr.Length)
            $s.Write($bytes, 0, $bytes.Length)
            $tail = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
            $s.Write($tail, 0, $tail.Length)
            $s.Flush()

            $next = $next.AddMilliseconds($interval)
            $wait = ($next - (Get-Date)).TotalMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) } else { $next = Get-Date }
        }
    } catch { }
    try { $client.Close() } catch { }
}

# --- Server-Schleife --------------------------------------------------------
Write-Log "Server-Schleife gestartet"
$lastSingle = $null

while ($true) {
    # --- Beenden per ESC (5 s halten) ---------------------------------------
    if ([Keyboard2]::GetAsyncKeyState($VK_ESCAPE) -lt 0) {
        if (-not $startTime) { $startTime = Get-Date }
        if (((Get-Date) - $startTime).TotalSeconds -ge $exitSeconds) {
            try { $notify.Visible = $false; $notify.Dispose() } catch { }
            Write-Log "Beendet per ESC"
            try { $listener.Stop() } catch { }
            (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0)
            Start-Sleep -Seconds 1
            exit
        }
    } else {
        $startTime = $null
    }

    if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 80
        continue
    }

    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $req = Read-Request $client
        if (-not $req) { try { $client.Close() } catch { }; continue }

        $path = $req.target
        if ($path.Contains('?')) { $path = $path.Substring(0, $path.IndexOf('?')) }

        if ($path -eq '/stream') {
            try {
                $rs = [runspacefactory]::CreateRunspace()
                $rs.Open()
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript($streamWorker)
                [void]$ps.AddArgument($client)
                [void]$ps.AddArgument($captureW)
                [void]$ps.AddArgument($captureH)
                [void]$ps.AddArgument($screenDpi)
                [void]$ps.AddArgument($maxWidth)
                [void]$ps.AddArgument($frameInterval)
                [void]$ps.AddArgument($srcRect)
                [void]$ps.AddArgument($jpegCodec)
                [void]$ps.AddArgument($encParams)
                [void]$ps.BeginInvoke()
                Write-Log ("Zuschauer verbunden: " + $client.Client.RemoteEndPoint.Address)
            } catch {
                Write-Log ("Stream-Worker fehlgeschlagen: " + $_.Exception.Message)
                try { $client.Close() } catch { }
            }
        }
        elseif ($path -eq '/latest.jpg') {
            $bits = [System.Drawing.Bitmap]::new($captureW, $captureH)
            $bits.SetResolution($screenDpi, $screenDpi)
            $gx = [System.Drawing.Graphics]::FromImage($bits)
            $gx.CopyFromScreen($srcRect.X, $srcRect.Y, 0, 0, (New-Object System.Drawing.Size($captureW, $captureH)))
            $gx.Dispose()
            if ($maxWidth -gt 0 -and $captureW -gt $maxWidth) {
                $nh = [int][Math]::Round($captureH * ($maxWidth / $captureW))
                $sm = [System.Drawing.Bitmap]::new($maxWidth, $nh)
                $sm.SetResolution($screenDpi, $screenDpi)
                $gx2 = [System.Drawing.Graphics]::FromImage($sm)
                $gx2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $gx2.DrawImage($bits, 0, 0, $maxWidth, $nh)
                $gx2.Dispose()
                $bits.Dispose()
                $bits = $sm
            }
            $ms2 = New-Object System.IO.MemoryStream
            if ($jpegCodec) { $bits.Save($ms2, $jpegCodec, $encParams) } else { $bits.Save($ms2, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
            $bits.Dispose()
            $jpg = $ms2.ToArray()
            $ms2.Dispose()
            Send-Response $client '200 OK' 'image/jpeg' $jpg
        }
        elseif ($path -eq '/status') {
            $json = '{"ok":true,"url":"' + $urlText + '","capture":"' + $captureW + 'x' + $captureH + '"}'
            Send-Response $client '200 OK' 'application/json' ([System.Text.Encoding]::ASCII.GetBytes($json))
        }
        elseif ($path -eq '/' -or $path -eq '/index.html') {
            Send-Response $client '200 OK' 'text/html; charset=utf-8' $pageBytes
        }
        else {
            Send-Response $client '404 Not Found' 'text/plain' ([System.Text.Encoding]::ASCII.GetBytes('not found'))
        }
    } catch {
        Write-Log ("Fehler: " + $_.Exception.Message)
        try { if ($client) { $client.Close() } } catch { }
        Start-Sleep -Milliseconds 100
    }
}
