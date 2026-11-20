@echo off
cd /d "%~dp0"
net session >nul 2>&1
if "%errorlevel%"=="0" goto run

echo Requesting administrator permission to see all applications and domain names.
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
if errorlevel 1 goto run
exit /b 0

:run
title Network monitor
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-monitor.ps1" %*
echo.
echo Monitor stopped.
pause
