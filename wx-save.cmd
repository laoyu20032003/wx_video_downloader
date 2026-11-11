@echo off
chcp 65001 >nul
title wx-save - WeChat Channels hover + F8
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0wx-dl.ps1" -NoAuto -Hud %*
echo.
echo [wx-save] exited. Proxy restored.
pause >nul
