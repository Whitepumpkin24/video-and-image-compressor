@echo off
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VideoImageCompressor.ps1"
exit /b