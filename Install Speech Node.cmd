@echo off
rem Double-click to install, update and start the speech node on this computer (see scripts\install-windows.ps1).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-windows.ps1" %*
