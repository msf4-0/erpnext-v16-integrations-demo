@echo off
REM One-line launcher for setup.ps1 (no ExecutionPolicy flags to remember).
REM   setup.cmd              converge + verify the stack
REM   setup.cmd -VerifyOnly  read-only health report
REM   setup.cmd -Full        rebuild from zero, then converge
REM   setup.cmd -ForceFlow   rebuild and redeploy the Node-RED flow
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
