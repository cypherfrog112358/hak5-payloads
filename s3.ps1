<#
================================================================================
 Screenshare over LAN - V3 (Sender an ZimaOS-Relay)

 Nimmt den Bildschirm auf und schickt die Bilder an den Relay auf dem
 Homeserver. Der Relay zeigt sie im Browser an - auf jedem Geraet im LAN:

     http://10.42.42.101:8090/

 Das Ziel oeffnet KEINEN Port: es verbindet sich nur nach aussen (HTTP POST).
 Damit gibt es keine Firewall-Frage und es sind keine Adminrechte noetig.

 Relay auf dem Server:  python3 /DATA/AppData/screenshare/relay.py
 Anzeige/Status:        http://10.42.42.101:8090/   und  .../status

 Beenden: ESC auf dem Ziel 5 Sekunden gedrueckt halten.
 Optional:  -RemoveAutostart   entfernt den Autostart-Eintrag wieder.
================================================================================
#>

param(
    [switch]$RemoveAutostart,
    [string]$RelayHost = '10.42.42.101',
    [int]$RelayPort = 8090
)

$fps           = 15          # Bilder pro Sekunde (Zielwert)
$jpegQuality   = 65          # 10-100
$maxWidth      = 1280        # 0 = nicht verkleinern
$captureAll    = 0           # 0 = primaerer Monitor, 1 = alle Monitore
$hide          = 1           # 1 = Konsolenfenster ausblenden
$showInfo      = 0           # 1 = CMD-Fenster mit Aufruf-URL oeffnen
$exitSeconds   = 5           # ESC-Dauer zum Beenden
$autostart     = 1           # 1 = bei jeder Anmeldung automatisch starten
$logFile       = $null       # z. B. 'C:\Temp\screenshare-v3.log'

$selfPath = $MyInvocation.MyCommand.Path

# --- Logdatei ---------------------------------------------------------------
if (-not $logFile) {
    try {
        $selfDir = Split-Path -Parent $selfPath
        if (-not $selfDir) { $selfDir = (Get-Location).Path }
        $logFile = Join-Path $selfDir 'screenshare-v3.log'
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
$runName = 'Screenshare-Over-LAN-V3'
if ($RemoveAutostart) {
    try { Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue } catch { }
    Write-Log "Autostart entfernt"
    exit
}

Write-Log ("Start (V3). pid=" + $pid + " pfad=" + $selfPath + " relay=" + $RelayHost + ":" + $RelayPort)

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
# skalierten Displays nur die obere linke Ecke.
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

$urlText = 'http://' + $RelayHost + ':' + $RelayPort + '/'
Write-Log ("Anzeige: " + $urlText)

# --- Autostart (HKCU, ohne Adminrechte) ------------------------------------
if ($autostart -eq 1 -and $selfPath) {
    try {
        $runCmd = 'powershell -w h -ExecutionPolicy Bypass -File "' + $selfPath + '"'
        Set-ItemProperty -Path $runKey -Name $runName -Value $runCmd -ErrorAction Stop
        Write-Log "Autostart eingetragen"
    } catch { Write-Log ("Autostart fehlgeschlagen: " + $_.Exception.Message) }
}

# --- Hinweis (ohne Fenster) -------------------------------------------------
$notify = $null
try { Set-Clipboard -Value $urlText -ErrorAction SilentlyContinue } catch { }
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "Screenshare aktiv"
    $notify.BalloonTipText = ("Ansehen: " + $urlText)
    $notify.Visible = $true
    $notify.ShowBalloonTip(10000)
} catch { }

if ($showInfo -eq 1) {
    try {
        $infoCmd = 'title Screenshare & echo. & echo   Ansehen auf jedem Geraet im LAN:  ' + $urlText +
                   ' & echo. & echo   Beenden: ESC auf dem Ziel 5 Sekunden halten. & echo.'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', $infoCmd | Out-Null
        Write-Log "Info-Fenster (cmd) geoeffnet"
    } catch { Write-Log ("Info-Fenster fehlgeschlagen: " + $_.Exception.Message) }
}

# --- Konsolenfenster ausblenden --------------------------------------------
if ($hide -eq 1){
    Start-Sleep -Seconds 3
    try {
        $Async = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
        $Type = Add-Type -MemberDefinition $Async -name Win32ShowWindowAsync3 -namespace Win32Functions3 -PassThru
        $hwnd = (Get-Process -PID $pid).MainWindowHandle
        if ($hwnd -ne [System.IntPtr]::Zero) {
            $Type::ShowWindowAsync($hwnd, 0)
        } else {
            $Host.UI.RawUI.WindowTitle = 'hideme3'
            $Proc = (Get-Process | Where-Object { $_.MainWindowTitle -eq 'hideme3' })
            $Type::ShowWindowAsync($Proc.MainWindowHandle, 0)
        }
    } catch { }
}

# Escape to exit key detection
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Keyboard3
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

# --- HTTP POST an den Relay (nur ausgehend) --------------------------------
function Send-Frame([byte[]]$data) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($RelayHost, $RelayPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(3000)) { throw 'connect timeout' }
        $c.EndConnect($ar)
        $c.NoDelay = $true
        $s = $c.GetStream()
        $head = "POST /push HTTP/1.1`r`nHost: " + $RelayHost + ":" + $RelayPort + "`r`nContent-Type: image/jpeg`r`nContent-Length: " +
                $data.Length + "`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $s.Write($hb, 0, $hb.Length)
        $s.Write($data, 0, $data.Length)
        $s.Flush()
    } finally {
        try { $c.Close() } catch { }
    }
}

# --- Sende-Schleife ---------------------------------------------------------
Write-Log "Sende-Schleife gestartet"

# Puffer einmal anlegen und wiederverwenden (spart pro Bild ~20 MB Allokation)
$full = [System.Drawing.Bitmap]::new($captureW, $captureH)
$full.SetResolution($screenDpi, $screenDpi)
$gFull = [System.Drawing.Graphics]::FromImage($full)

$src = $full
$gOut = $null
if ($maxWidth -gt 0 -and $captureW -gt $maxWidth) {
    $outH = [int][Math]::Round($captureH * ($maxWidth / [double]$captureW))
    $scaled = [System.Drawing.Bitmap]::new($maxWidth, $outH)
    $scaled.SetResolution($screenDpi, $screenDpi)
    $gOut = [System.Drawing.Graphics]::FromImage($scaled)
    $gOut.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
    $gOut.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $gOut.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $src = $scaled
}
$msBuf = New-Object System.IO.MemoryStream
$online = $false
$next = Get-Date

while ($true) {
    # --- Beenden per ESC (5 s halten) ---------------------------------------
    if ([Keyboard3]::GetAsyncKeyState($VK_ESCAPE) -lt 0) {
        if (-not $startTime) { $startTime = Get-Date }
        if (((Get-Date) - $startTime).TotalSeconds -ge $exitSeconds) {
            try { $notify.Visible = $false; $notify.Dispose() } catch { }
            Write-Log "Beendet per ESC"
            if ($hide -ne 1) { try { (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0) } catch { } }
            Start-Sleep -Seconds 1
            exit
        }
    } else {
        $startTime = $null
    }

    try {
        $gFull.CopyFromScreen($srcRect.X, $srcRect.Y, 0, 0, (New-Object System.Drawing.Size($captureW, $captureH)))
        if ($gOut) { $gOut.DrawImage($full, 0, 0, $src.Width, $src.Height) }

        $msBuf.SetLength(0)
        if ($jpegCodec) {
            $src.Save($msBuf, $jpegCodec, $encParams)
        } else {
            $src.Save($msBuf, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        $bytes = $msBuf.ToArray()

        Send-Frame $bytes
        if (-not $online) { Write-Log ("Relay erreichbar (" + $bytes.Length + " B/Frame)"); $online = $true }
    } catch {
        if ($online) { Write-Log ("Relay nicht erreichbar: " + $_.Exception.Message); $online = $false }
        Start-Sleep -Milliseconds 500
    }

    $next = $next.AddMilliseconds($frameInterval)
    $wait = ($next - (Get-Date)).TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) } else { $next = Get-Date }
}
