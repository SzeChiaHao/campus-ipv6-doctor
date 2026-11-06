@echo off
chcp 65001 >nul
title IPv6 修复
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ipv6-doctor-fix.ps1" %*
echo.
pause
