@echo off
chcp 65001 >nul
title wx-dl - WeChat Channels downloader
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0wx-dl.ps1" %*
echo.
echo [wx-dl] exited. Close this window or press any key.
pause >nul