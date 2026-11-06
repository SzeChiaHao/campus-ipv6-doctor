@echo off
chcp 65001 >nul
title IPv6 体检
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ipv6-doctor.ps1" %*
echo.
pause
