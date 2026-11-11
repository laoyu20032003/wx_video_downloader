@echo off
chcp 65001 >nul
title wx-hud - WeChat Channels card status
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -Sta -NoProfile -ExecutionPolicy Bypass -File "%~dp0wx-hud.ps1" %*
