@echo off
setlocal
set "PWSH=%~dp0PowerShell\7\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh"
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Cnc.ps1" %*
exit /b %errorlevel%
