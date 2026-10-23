<#
================================================================================
 Screenshare over LAN - V2 (Sender, OHNE Administratorrechte)

 Unterschied zu V1 (Screenshare-Over-LAN-fixed.ps1):
   V1 oeffnet einen HTTP-Server auf dem Ziel -> braucht Admin (Firewall-Regel,
   URL-Reservierung) und ist aus dem LAN erreichbar.
   V2 oeffnet KEINEN Port. Es nimmt den Bildschirm auf und schickt jedes Bild
   per HTTP-POST an einen Empfaenger im selben LAN. Damit funktioniert es auch
   als normaler Benutzer ohne UAC/Adminrechte (keine Firewall-Regel noetig,
   nur ausgehender Verkehr).

 Empfaenger: Screenshare-Receiver.py (Python 3, nur Standardbibliothek) auf
 einem beliebigen Rechner im LAN starten, z. B.:
     python Screenshare-Receiver.py 8090 geheim
 Dann im Browser des Clients:  http://<IP-des-Empfaengers>:8090/?token=geheim

 Konfiguration unten: $serverUrl und $token muessen zum Empfaenger passen.
 Beenden: ESC auf dem Ziel 5 Sekunden gedrueckt halten.
================================================================================
#>

param(
    [string]$Server = '',    # ueberschreibt $serverUrl (z. B. http://192.168.0.10:8090)
    [string]$Token  = ''     # ueberschreibt $token
)

$serverUrl    = 'http://192.168.0.10:8090'   # Empfaenger im LAN (IP:Port)
$token        = 'geheim'                     # muss zum Empfaenger passen
$fps          = 2                            # Bilder pro Sekunde (HTTP-POST)
$jpegQuality  = 60                           # 10-100
$maxWidth     = 1280                         # 0 = nicht verkleinern
$captureAll   = 0                            # 0 = primaerer Monitor, 1 = alle
$hide         = 1                            # 1 = Konsolenfenster ausblenden
$showInfo     = 1                            # 1 = CMD-Fenster mit Status öffnen
$exitSeconds  = 5                            # ESC-Dauer zum Beenden
$logFile      = $null                        # z. B. 'C:\PS\screenshare-v2.log'
$sendTimeout  = 8                            # Sekunden pro Upload

if ($Server) { $serverUrl = $Server }
if ($Token)  { $token = $Token }

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
Write-Log ("Start (V2/Sender). admin=" + $isAdmin + " pid=" + $pid + " pfad=" + $selfPath)
Write-Log ("Empfaenger: " + $serverUrl + "  fps=" + $fps + "  maxWidth=" + $maxWidth + "  quality=" + $jpegQuality)

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
    [Console]::SetWindowSize(80, 20)
    [Console]::Title = "Screenshare Sender (V2)"
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

# --- Upload-Ziel ------------------------------------------------------------
if (-not $serverUrl) {
    Write-Host "FEHLER: `$serverUrl ist leer - Empfaenger im LAN eintragen." -ForegroundColor Red
    Write-Log "FEHLER: serverUrl leer"
    exit 1
}
$uploadUrl = $serverUrl.TrimEnd('/') + '/upload?token=' + [System.Uri]::EscapeDataString($token)
$wc = New-Object System.Net.WebClient
$wc.Headers.Add('User-Agent', 'ScreenshareSender/2.0')
$wc.Timeout = $sendTimeout * 1000

# --- Hinweis + Info-Fenster -------------------------------------------------
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "Screenshare aktiv (Sender V2)"
    $notify.BalloonTipText = ("Sendet an " + $serverUrl)
    $notify.Visible = $true
    $notify.ShowBalloonTip(8000)
} catch { }

if ($showInfo -eq 1) {
    try {
        $infoCmd = 'title Screenshare Sender (V2) & echo. & echo   Sendet an: ' + $serverUrl +
                   ' & echo. & echo   Ansehen:  http://' + ($serverUrl -replace '^https?://','') -replace '/.*$','' +
                   ' (Token im Browser noetig) & echo. & echo   Beenden: ESC auf dem Ziel 5 Sekunden halten. & echo.'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', $infoCmd | Out-Null
        Write-Log "Info-Fenster (cmd) geoeffnet"
    } catch {
        Write-Log ("Info-Fenster fehlgeschlagen: " + $_.Exception.Message)
    }
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
if ($frameInterval -lt 100) { $frameInterval = 100 }

# --- Aufnahme + Upload ------------------------------------------------------
$failCount = 0
$lastFailLog = Get-Date
$nextFrame = Get-Date
$framesSent = 0
Write-Log "Sender-Schleife gestartet"

while ($true) {
    # --- Beenden per ESC (5 s halten) ---------------------------------------
    if ([Keyboard2]::GetAsyncKeyState($VK_ESCAPE) -lt 0) {
        if (-not $startTime) { $startTime = Get-Date }
        if (((Get-Date) - $startTime).TotalSeconds -ge $exitSeconds) {
            try { $notify.Visible = $false; $notify.Dispose() } catch { }
            Write-Log ("Beendet per ESC. Gesendete Bilder: " + $framesSent)
            (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0)
            Start-Sleep -Seconds 1
            exit
        }
    } else {
        $startTime = $null
    }

    # --- Bildschirm aufnehmen (DPI-korrekt) ---------------------------------
    try {
        $bitmap = [System.Drawing.Bitmap]::new($captureW, $captureH)
        $bitmap.SetResolution($screenDpi, $screenDpi)
        $gfx = [System.Drawing.Graphics]::FromImage($bitmap)
        $gfx.CopyFromScreen($srcRect.X, $srcRect.Y, 0, 0, (New-Object System.Drawing.Size($captureW, $captureH)))
        $gfx.Dispose()

        if ($maxWidth -gt 0 -and $captureW -gt $maxWidth) {
            $newHeight = [int][Math]::Round($captureH * ($maxWidth / $captureW))
            $small = [System.Drawing.Bitmap]::new($maxWidth, $newHeight)
            $small.SetResolution($screenDpi, $screenDpi)
            $g2 = [System.Drawing.Graphics]::FromImage($small)
            $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g2.DrawImage($bitmap, 0, 0, $maxWidth, $newHeight)
            $g2.Dispose()
            $bitmap.Dispose()
            $bitmap = $small
        }

        $ms = New-Object System.IO.MemoryStream
        if ($jpegCodec) {
            $bitmap.Save($ms, $jpegCodec, $encParams)
        } else {
            $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        $bitmap.Dispose()
        $bytes = $ms.ToArray()
        $ms.Dispose()
    } catch {
        Write-Log ("Aufnahme fehlgeschlagen: " + $_.Exception.Message)
        Start-Sleep -Milliseconds 500
        continue
    }

    # --- Upload -------------------------------------------------------------
    try {
        [void]$wc.UploadData($uploadUrl, 'POST', $bytes)
        $framesSent++
        if ($failCount -gt 0) { Write-Log ("Verbindung wieder da (Bild " + $framesSent + ")"); $failCount = 0 }
    } catch {
        $failCount++
        if ($failCount -eq 1 -or ((Get-Date) - $lastFailLog).TotalSeconds -ge 30) {
            Write-Log ("Upload fehlgeschlagen (" + $failCount + "x): " + $_.Exception.Message)
            $lastFailLog = Get-Date
        }
    }

    # --- Takt --------------------------------------------------------------
    $nextFrame = $nextFrame.AddMilliseconds($frameInterval)
    $wait = ($nextFrame - (Get-Date)).TotalMilliseconds
    if ($wait -gt 0) {
        Start-Sleep -Milliseconds ([int]$wait)
    } else {
        $nextFrame = Get-Date
    }
}
