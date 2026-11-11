# 看门狗：主脚本退出（包括直接关掉控制台窗口）后，自动还原系统代理。
param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$Snapshot
)

$ErrorActionPreference = 'SilentlyContinue'
while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
  Start-Sleep -Seconds 2
}

try {
  # 主进程被强杀时，mitmproxy 的 python 子进程可能还活着并占着端口，一并清掉
  $mitmPidFile = Join-Path (Split-Path $Snapshot -Parent) 'mitm.pid'
  if (Test-Path $mitmPidFile) {
    $mp = [int](Get-Content $mitmPidFile -Raw)
    if ($mp) { taskkill /PID $mp /T /F 2>$null | Out-Null }
    Remove-Item -LiteralPath $mitmPidFile -ErrorAction SilentlyContinue
  }

  # 主进程被强杀时，HUD 子进程也要一并结束
  $hudPidFile = Join-Path (Split-Path $Snapshot -Parent) 'hud.pid'
  if (Test-Path $hudPidFile) {
    $hp = [int](Get-Content $hudPidFile -Raw)
    if ($hp) { Stop-Process -Id $hp -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $hudPidFile -ErrorAction SilentlyContinue
  }
}
catch { }

try {
  if (-not (Test-Path $Snapshot)) { return }
  $snap = Get-Content $Snapshot -Raw | ConvertFrom-Json
  $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  Set-ItemProperty $reg -Name ProxyEnable -Value ([int]$snap.Enable)
  Set-ItemProperty $reg -Name ProxyServer -Value ([string]$snap.Server)
  if ($snap.Override) { Set-ItemProperty $reg -Name ProxyOverride -Value ([string]$snap.Override) }

  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinInetW {
  [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
"@
  [WinInetW]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [WinInetW]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}
catch { }
