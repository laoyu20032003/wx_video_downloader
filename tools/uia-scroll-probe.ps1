<#
  uia-scroll-probe.ps1 — 验证视频号主页能否自动滚屏，并统计卡片去重数量。

  只读 UIA，不点击卡片。滚轮在卡片网格中心发送，结束时滚回顶部。
  用法：
    powershell -Sta -File tools\uia-scroll-probe.ps1
    powershell -Sta -File tools\uia-scroll-probe.ps1 -Steps 8 -Out work\scroll_probe.json
#>
param(
  [int]$Steps = 6,
  [int]$WaitMs = 650,
  [string]$Out = ""
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ScrollNative {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, uint e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@

$root = [System.Windows.Automation.AutomationElement]::RootElement
$win = $null
$pids = @(Get-Process Weixin, WeChatAppEx -ErrorAction SilentlyContinue | ForEach-Object Id)
foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
  try {
    if ($pids -notcontains [int]$w.Current.ProcessId) { continue }
    if ($w.Current.NativeWindowHandle -eq 0) { continue }
    $boxes = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'click-box')))
    if ($boxes.Count -gt 0) { $win = $w; break }
  } catch { }
}
if (-not $win) { Write-Host '没有找到视频号主页卡片窗口'; exit 1 }

$profile = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
  (New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'page-profile')))
if (-not $profile) { Write-Host '没有找到 page-profile'; exit 1 }

$pr = $profile.Current.BoundingRectangle
$cx = [int](($pr.Left + $pr.Right) / 2)
$cy = [int](($pr.Top + $pr.Bottom) / 2)
[void][ScrollNative]::SetForegroundWindow([IntPtr]$win.Current.NativeWindowHandle)
Start-Sleep -Milliseconds 250
[void][ScrollNative]::SetCursorPos($cx, $cy)

$boxCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'click-box')
$textCond = New-Object System.Windows.Automation.PropertyCondition(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
  [System.Windows.Automation.ControlType]::Text)

function Read-Cards {
  $boxes = $profile.FindAll([System.Windows.Automation.TreeScope]::Descendants, $boxCond)
  $rows = @()
  foreach ($b in $boxes) {
    try {
      $r = $b.Current.BoundingRectangle
      if ($r.Width -lt 80 -or $r.Height -lt 120) { continue }
      $texts = @()
      foreach ($t in $b.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)) {
        if ($t.Current.Name) { $texts += $t.Current.Name }
      }
      $key = ($texts -join '|')
      if (-not $key) { continue }
      $rows += [pscustomobject]@{
        key = $key
        duration = @($texts | Where-Object { $_ -match '^\d{1,2}:\d{2}(:\d{2})?$' } | Select-Object -First 1)[0]
        y = [int]$r.Y
        texts = ($texts -join ' / ')
      }
    } catch { }
  }
  return $rows
}

$all = @{}
$stepsLog = @()
$totalText = ''
foreach ($t in $profile.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)) {
  if ($t.Current.Name -match '(\d+)\s*条原创内容') { $totalText = $t.Current.Name; break }
}

for ($i = 0; $i -le $Steps; $i++) {
  $cards = @(Read-Cards)
  $new = 0
  foreach ($c in $cards) {
    if (-not $all.ContainsKey($c.key)) { $all[$c.key] = $c; $new++ }
  }
  $stepsLog += [pscustomobject]@{
    step = $i
    cardsInTree = $cards.Count
    uniqueInTree = @($cards | Group-Object key).Count
    newToSession = $new
    minY = if ($cards.Count) { ($cards | Measure-Object y -Minimum).Minimum } else { 0 }
    maxY = if ($cards.Count) { ($cards | Measure-Object y -Maximum).Maximum } else { 0 }
  }
  Write-Host ("step {0}: tree={1} unique={2} new={3} y={4}..{5}" -f `
    $i, $cards.Count, $stepsLog[-1].uniqueInTree, $new, $stepsLog[-1].minY, $stepsLog[-1].maxY)
  if ($i -lt $Steps) {
    [ScrollNative]::mouse_event(0x0800, 0, 0, -600, 0)
    Start-Sleep -Milliseconds $WaitMs
  }
}

# 滚回顶部，避免改变用户当前阅读位置
for ($i = 0; $i -lt $Steps; $i++) {
  [ScrollNative]::mouse_event(0x0800, 0, 0, 600, 0)
  Start-Sleep -Milliseconds 120
}

$result = [pscustomobject]@{
  captured = (Get-Date).ToString('o')
  totalText = $totalText
  pages = $Steps + 1
  uniqueCards = $all.Count
  steps = $stepsLog
  cards = @($all.Values | Sort-Object y)
}
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $PSScriptRoot) 'work\scroll_probe.json' }
$dir = Split-Path -Parent $Out
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Out -Encoding utf8
Write-Host ("total='{0}' unique={1} -> {2}" -f $totalText, $all.Count, $Out)
