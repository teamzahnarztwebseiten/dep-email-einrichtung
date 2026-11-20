@echo off
rem Startet die Mail-Einrichtung (Windows PowerShell 5.1 ist in Windows 10/11 enthalten).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DEP-Mail-Einrichtung.ps1" %*
pause
