<#
  wx-hud.ps1 —— 视频号主页卡片状态 HUD（原型）

  作用：
    鼠标停在微信视频号作者主页的某张视频卡片上时，在鼠标旁显示一张小浮层：
      - 已验证下载过（按输出文件名里的时长匹配）：显示 ✓ 已下载 + 文件名
      - 没有下载：显示 未下载 + 时长/点赞 + 提示

  原理：
    微信 4.2 的 liteapp 页面无法注入，但 Chromium 的 UI Automation 树暴露了卡片结构：
      Group(class=click-box) -> Image(封面) + Text(时长) + Text(点赞) + Text(文案)
    本脚本只读 UIA，并在自己的一层透明置顶窗口里画提示，不修改微信页面。

  用法：
    pwsh -Sta -File wx-hud.ps1
    pwsh -Sta -File wx-hud.ps1 -OutDir "D:\视频号"
    pwsh -Sta -File wx-hud.ps1 -Diagnose     # 只打印识别到的卡片，不显示浮层
    pwsh -Sta -File wx-hud.ps1 -ForceShow    # 测试用：不要求微信在前台

  注意：
    - 必须 STA；wx-hud.cmd 已带 -Sta。
    - 只按“时长”匹配已下载文件（视频号_*_<秒>s.mp4），同一时长多文件时取最新。
    - 这是第一步：先把“卡片识别 + 状态显示”跑通，后续再做逐卡徽标和 F8 保存。
#>
param(
  [string]$OutDir = "",
  [int]$IntervalMs = 250,
  [switch]$Diagnose,
  [switch]$ForceShow,
  [int]$PinX = -1,
  [int]$PinY = -1,
  [int]$LingerSeconds = 4,
  [switch]$DebugState,
  [string]$FlowsFile = "",
  [string]$IndexFile = "",
  [string]$ToolScript = ""
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '视频号' }
if (-not $FlowsFile) { $FlowsFile = Join-Path $PSScriptRoot 'flows.log' }
if (-not $IndexFile) { $IndexFile = Join-Path $PSScriptRoot 'work\hud_index.json' }
if (-not $ToolScript) { $ToolScript = Join-Path $PSScriptRoot 'wx-dl.ps1' }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  Write-Host "需要 STA 线程：请用  pwsh -Sta -File wx-hud.ps1" -ForegroundColor Yellow
  exit 1
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HudNative {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
}
'@

[void][HudNative]::SetProcessDpiAwareness(2)   # per-monitor DPI；已设置过会返回错误，忽略

$script:hostCands = @()
$script:hostCandsTime = [datetime]::MinValue

function Get-WeChatHost {
  # 视频号卡片页可能出现在多个窗口里：Weixin 主窗口、WeChatAppEx 独立窗口、
  # 以及内嵌在播放窗口里的子页。用 UIA 顶层窗口遍历选“带 page-profile 的顶层窗口”，
  # 再按光标位置 / 前台窗口挑当前这个；内嵌页的元素本来就挂在顶层窗口的 UIA 树里。
  $pids = @(Get-Process Weixin, WeChatAppEx -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $now = Get-Date
  if (($now - $script:hostCandsTime).TotalSeconds -gt 1 -or @($script:hostCands).Count -eq 0) {
    $cands = @()
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $kids = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'page-profile')
    foreach ($k in $kids) {
      $c = $k.Current
      if ($pids -notcontains [int]$c.ProcessId) { continue }
      if ($c.IsOffscreen) { continue }
      $hwnd = [IntPtr]$c.NativeWindowHandle
      if ($hwnd -eq [IntPtr]::Zero) { continue }
      if (-not $k.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)) { continue }
      $cands += [pscustomobject]@{
        Hwnd  = $hwnd
        Pid   = [int]$c.ProcessId
        Rect  = $c.BoundingRectangle
        Title = $c.Name
      }
    }
    $script:hostCands = $cands
    $script:hostCandsTime = $now
  }
  if (@($script:hostCands).Count -eq 0) { return $null }

  $fg = [HudNative]::GetForegroundWindow()
  $fgPid = [uint32]0
  [void][HudNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)

  # 前台就是微信时，只有“前台顶层窗口本身带卡片页”才算卡片模式；
  # 否则（视频播放窗口）返回 null，让上层走“正在播放 · 按 F8 保存”分支。
  if ($pids -contains [int]$fgPid) {
    foreach ($h in $script:hostCands) {
      if ($h.Hwnd -eq [IntPtr]$fg) { return $h }
    }
    return $null
  }

  $pt = New-Object HudNative+POINT
  [void][HudNative]::GetCursorPos([ref]$pt)
  foreach ($h in $script:hostCands) {
    if ($h.Rect.Contains($pt.X, $pt.Y)) { return $h }
  }
  return $script:hostCands[0]
}

function ConvertTo-Seconds([string]$d) {
  if (-not $d) { return 0 }
  $parts = $d.Split(':') | ForEach-Object { [int]$_ }
  switch ($parts.Count) {
    2 { return $parts[0] * 60 + $parts[1] }
    3 { return $parts[0] * 3600 + $parts[1] * 60 + $parts[2] }
    default { return 0 }
  }
}

$script:filesByDuration = @{}
$script:lastIndexRefresh = [datetime]::MinValue

function Refresh-Index {
  $map = @{}
  if (Test-Path -LiteralPath $OutDir) {
    foreach ($f in Get-ChildItem -LiteralPath $OutDir -File -Filter '*.mp4' -ErrorAction SilentlyContinue) {
      if ($f.Name -match '_(\d+)s\.mp4$') {
        $sec = [int]$Matches[1]
        if (-not $map.ContainsKey($sec)) { $map[$sec] = New-Object System.Collections.ArrayList }
        [void]$map[$sec].Add($f)
      }
    }
  }
  $script:filesByDuration = $map
  $script:lastIndexRefresh = Get-Date
  Write-Verbose ("index: {0} durations" -f $map.Count)
}

$script:flowOffset = [long]0
$script:flowTail = ''
$script:recentMedia = New-Object System.Collections.ArrayList
$script:mediaFirst = @{}
$script:cardMedia = @{}
$script:hoverKey = ''
$script:hoverStart = [datetime]::MinValue
$script:index = @{}
$script:saving = $false
$script:saveProc = $null
$script:saveKey = ''
$script:saveDesc = ''
$script:saveDur = ''
$script:saveMedia = $null
$script:saveCandidates = @()
$script:saveCursor = 0
$script:saveTotal = 0
$script:saveOut = Join-Path $env:TEMP 'wx_hud_save_out.txt'
$script:saveErr = Join-Path $env:TEMP 'wx_hud_save_err.txt'
$script:notice = ''
$script:noticeUntil = [datetime]::MinValue
$script:f8Down = $false

function Set-Notice([string]$text, [int]$seconds = 3) {
  $script:notice = $text
  $script:noticeUntil = (Get-Date).AddSeconds($seconds)
}

function Get-MediaId([string]$url) {
  if ($url -match '[?&]m=([0-9a-fA-F]{8,})') { return $matches[1] }
  if ($url -match '[?&]encfilekey=([^&]+)') {
    $ek = [System.Uri]::UnescapeDataString($matches[1])
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
      $h = ([BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ek)))).Replace('-', '').ToLower()
      return 'ek' + $h.Substring(0, 30)
    } finally { $md5.Dispose() }
  }
  return $null
}

function Read-MediaFlows {
  if (-not (Test-Path -LiteralPath $FlowsFile)) { return }
  $fs = $null
  $chunk = ''
  try {
    $fs = [System.IO.File]::Open($FlowsFile, [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($fs.Length -lt $script:flowOffset) { $script:flowOffset = [long]0; $script:flowTail = '' }
    if ($fs.Length -eq $script:flowOffset) { return }
    $fs.Position = $script:flowOffset
    $size = [int]($fs.Length - $script:flowOffset)
    $buf = New-Object byte[] $size
    $read = 0
    while ($read -lt $size) {
      $n = $fs.Read($buf, $read, $size - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    $script:flowOffset = $fs.Position
    $chunk = $script:flowTail + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  } catch {
    return
  } finally {
    if ($fs) { $fs.Dispose() }
  }

  $idx = $chunk.LastIndexOf("`n")
  if ($idx -lt 0) { $script:flowTail = $chunk; return }
  $script:flowTail = $chunk.Substring($idx + 1)
  $now = Get-Date
  foreach ($line in ($chunk.Substring(0, $idx) -split "`n")) {
    $line = $line.TrimEnd([char]13)
    if (-not $line) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 5) { continue }
    if ($parts[1] -notin @('200', '206')) { continue }
    $url = $parts[4].Trim()
    if ($url -notmatch 'finder\.video\.qq\.com.*stodownload') { continue }
    if ($url -notmatch 'token=') { continue }
    $id = Get-MediaId $url
    if (-not $id) { continue }
    if (-not $script:mediaFirst.ContainsKey($id)) { $script:mediaFirst[$id] = $now }
    $rng = if ($parts.Count -ge 6) { ([string]$parts[5]).Trim() } else { '' }
    $rangeStart = [long]0
    $rangeEnd = [long]0
    if ($rng -match 'bytes=(\d+)-(\d+)') {
      $rangeStart = [long]$matches[1]
      $rangeEnd = [long]$matches[2]
    } elseif ($rng -match 'bytes=(\d+)-') {
      $rangeStart = [long]$matches[1]
      $rangeEnd = $rangeStart
    }
    [void]$script:recentMedia.Add([pscustomobject]@{
        M = $id; Url = $url; Time = $now; Status = $parts[1]
        RangeStart = $rangeStart; RangeEnd = $rangeEnd
      })
  }
  $cut = $now.AddSeconds(-30)
  while ($script:recentMedia.Count -gt 0 -and $script:recentMedia[0].Time -lt $cut) {
    $script:recentMedia.RemoveAt(0)
  }
  foreach ($key in @($script:mediaFirst.Keys)) {
    if ($script:mediaFirst[$key] -lt $cut) { $script:mediaFirst.Remove($key) }
  }
  while ($script:recentMedia.Count -gt 200) { $script:recentMedia.RemoveAt(0) }
}

function Get-MediaCandidates([int]$max = 3) {
  $cut = (Get-Date).AddSeconds(-4)
  $items = @($script:recentMedia | Where-Object { $_.Time -ge $cut })
  if ($items.Count -eq 0) { return @() }

  $groups = @{}
  foreach ($it in $items) {
    if (-not $groups.ContainsKey($it.M)) {
      $first = if ($script:mediaFirst.ContainsKey($it.M)) { $script:mediaFirst[$it.M] } else { $it.Time }
      $groups[$it.M] = [pscustomobject]@{
        M = $it.M; Url = $it.Url; First = $first; Last = $it.Time
        MaxEnd = [long]0; Count = 0
      }
    }
    $g = $groups[$it.M]
    $g.Last = $it.Time
    $g.Count++
    if ($it.RangeEnd -gt $g.MaxEnd) { $g.MaxEnd = [long]$it.RangeEnd }
    if ($it.Url) { $g.Url = $it.Url }
  }

  # 当前播放的视频通常先开始；预加载的下一条通常更晚出现。
  # 先按“最早开始”，再按最近 Range 末尾、请求数。
  $sorted = @($groups.Values | Sort-Object -Property `
      @{ Expression = { $_.First }; Ascending = $true }, `
      @{ Expression = { $_.MaxEnd }; Descending = $true }, `
      @{ Expression = { $_.Count }; Descending = $true })
  return @($sorted | Select-Object -First $max)
}

function Get-BoundMedia($card) {
  $target = if ($card) { $card } else { $script:lastTipCard }
  if (-not $target) { return $null }
  $k = Get-CardKey $target
  if ($script:cardMedia.ContainsKey($k)) { return $script:cardMedia[$k] }
  return $null
}

function Get-CurrentMedia {
  $c = @(Get-MediaCandidates 1)
  if ($c.Count -eq 0) { return $null }
  return $c[0]
}

function Load-Index {
  $script:index = @{}
  if (-not (Test-Path -LiteralPath $IndexFile)) { return }
  try {
    $j = Get-Content -LiteralPath $IndexFile -Raw | ConvertFrom-Json
    foreach ($e in @($j.entries)) {
      if ($e -and $e.key -and $e.file -and (Test-Path -LiteralPath $e.file)) {
        $script:index[[string]$e.key] = $e
      }
    }
  } catch { }
}

function Save-Index {
  try {
    $parent = Split-Path -Parent $IndexFile
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $entries = @($script:index.Values | Sort-Object time -Descending)
    [pscustomobject]@{ entries = $entries } | ConvertTo-Json -Depth 6 |
      Set-Content -LiteralPath $IndexFile -Encoding utf8
  } catch { }
}

function Get-CardKey($card) {
  $d = (($card.Description -replace '\s+', ' ').Trim())
  return ("{0}|{1}" -f $d, $card.Duration)
}

function Get-IndexedEntry($card, $media) {
  $key = Get-CardKey $card
  if ($script:index.ContainsKey($key)) {
    $e = $script:index[$key]
    if ($e.file -and (Test-Path -LiteralPath $e.file)) { return $e }
    $script:index.Remove($key)
  }
  if ($media) {
    foreach ($e in $script:index.Values) {
      if ($e.m -eq $media.M -and $e.file -and (Test-Path -LiteralPath $e.file)) { return $e }
    }
  }
  # 文案可能被 UIA 截断/为空，索引键对不上时再按时长兜底
  if ($card.Duration) {
    foreach ($e in $script:index.Values) {
      if ($e.duration -eq $card.Duration -and $e.file -and (Test-Path -LiteralPath $e.file)) { return $e }
    }
  }
  return $null
}

function Get-Cards([IntPtr]$hwnd) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  if (-not $root) { return @() }

  $wr = $root.Current.BoundingRectangle

  # 卡片网格的真实可视区域是 class=page-profile 的容器，用它裁剪掉滚出屏幕的虚拟项
  $viewCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'page-profile')
  $viewEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $viewCond)
  $vr = if ($viewEl) { $viewEl.Current.BoundingRectangle } else { $wr }

  $cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'click-box')
  $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

  $cards = New-Object System.Collections.ArrayList
  foreach ($c in $found) {
    $r = $c.Current.BoundingRectangle
    if ($r.IsEmpty -or $r.Width -lt 80 -or $r.Height -lt 120) { continue }

    # 只保留和页面可视区有实际交集的卡片
    $ix = [Math]::Max($r.X, $vr.X); $iy = [Math]::Max($r.Y, $vr.Y)
    $ax = [Math]::Min($r.Right, $vr.Right); $ay = [Math]::Min($r.Bottom, $vr.Bottom)
    if (($ax - $ix) -lt 40 -or ($ay - $iy) -lt 60) { continue }

    $dur = ''; $desc = ''; $like = ''
    $cover = [System.Windows.Rect]::Empty
    $kids = $c.FindAll([System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($k in $kids) {
      $kc = $k.Current
      if ($kc.ControlType.ProgrammaticName -eq 'ControlType.Image' -and $kc.Name -eq '封面') {
        $cover = $kc.BoundingRectangle
        continue
      }
      if ($kc.ControlType.ProgrammaticName -ne 'ControlType.Text') { continue }
      $t = [string]$kc.Name
      if ($t -match '^\d{1,2}:\d{2}(:\d{2})?$') { $dur = $t }
      elseif ($t -match '^\d+(\.\d+)?[万wW]?$') { $like = $t }
      elseif ($t.Length -gt $desc.Length) { $desc = $t }
    }
    if (-not $dur) { continue }
    if ($cover.IsEmpty) { $cover = $r }

    # 只保留完整落在可视区里的卡片：滚出视窗/被头部遮住一半的卡片不显示徽标和提示
    if ($cover.Top -lt ($vr.Top - 2) -or $cover.Bottom -gt ($vr.Bottom + 2)) { continue }
    if ($cover.Left -lt ($vr.Left - 2) -or $cover.Right -gt ($vr.Right + 2)) { continue }

    [void]$cards.Add([pscustomobject]@{
      Rect        = $r
      Cover       = $cover
      Duration    = $dur
      Seconds     = (ConvertTo-Seconds $dur)
      Description = $desc
      Like        = $like
    })
  }
  return $cards.ToArray()
}

function Get-CardHit($cards, [int]$x, [int]$y) {
  $coverHit = $null
  $rectHit = $null
  foreach ($c in $cards) {
    if ($c.Cover.Contains($x, $y)) {
      if (-not $coverHit -or ($c.Rect.Width * $c.Rect.Height) -lt ($coverHit.Rect.Width * $coverHit.Rect.Height)) {
        $coverHit = $c
      }
    }
    elseif ($c.Rect.Contains($x, $y)) {
      if (-not $rectHit -or ($c.Rect.Width * $c.Rect.Height) -lt ($rectHit.Rect.Width * $rectHit.Rect.Height)) {
        $rectHit = $c
      }
    }
  }
  if ($coverHit) { return $coverHit }
  return $rectHit
}

function Find-Downloaded([int]$seconds) {
  if ($seconds -le 0) { return $null }
  $list = $script:filesByDuration[$seconds]
  if (-not $list -or $list.Count -eq 0) { return $null }
  return ($list | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Shorten([string]$s, [int]$n) {
  if (-not $s) { return '' }
  $s = $s -replace '[\r\n]+', ' '
  if ($s.Length -le $n) { return $s }
  return $s.Substring(0, $n) + '…'
}

function Start-Save {
  if ($script:saving) { Set-Notice "正在保存上一条，请稍候" 2; return }
  $pt = New-Object HudNative+POINT
  if ($PinX -ge 0 -and $PinY -ge 0) { $pt.X = $PinX; $pt.Y = $PinY }
  else { [void][HudNative]::GetCursorPos([ref]$pt) }

  Read-MediaFlows
  # 只支持“作者主页卡片”模式：视频播放窗口没有 page-profile，F8 不做任何猜测
  $hp = Get-WeChatHost
  if (-not $hp) {
    Write-HudLog "save-abort no-host (player window unsupported)"
    return
  }
  $script:cards = Get-Cards $hp.Hwnd
  $script:lastRefresh = Get-Date
  $card = Get-CardHit $script:cards $pt.X $pt.Y
  if (-not $card) {
    Write-HudLog ("save-abort no-card cards=$(@($script:cards).Count) cur=$($pt.X),$($pt.Y)")
    Set-Notice "先把鼠标停在卡片上" 3
    return
  }
  $cands = @(Get-MediaCandidates 3)
  if ($cands.Count -eq 0) {
    Write-HudLog ("save-abort no-media cur=$($pt.X),$($pt.Y) cards=$(@($script:cards).Count) flows=$((Get-Item -LiteralPath $FlowsFile -ErrorAction SilentlyContinue).Length)")
    Set-Notice "没有检测到正在播放，先悬停 1–2 秒" 3
    return
  }

  # 优先用这张卡片悬停时绑定的媒体，避免把预加载的下一条当成当前
  $bindKey = Get-CardKey $card
  if ($script:cardMedia.ContainsKey($bindKey)) {
    $b = $script:cardMedia[$bindKey]
    $activeAll = @(Get-MediaCandidates 10)
    if (@($activeAll | Where-Object { $_.M -eq $b.M }).Count -gt 0) {
      $cands = @([pscustomobject]@{ M = $b.M; Url = $b.Url; First = $b.Time; MaxEnd = [long]0; Count = 1 }) +
               @($cands | Where-Object { $_.M -ne $b.M })
      $cands = @($cands | Select-Object -First 3)
    }
  }
  $media = $cands[0]

  $script:saveKey = Get-CardKey $card
  $script:saveDesc = $card.Description
  $script:saveDur = $card.Duration
  $cardInfo = "dur=$($card.Duration)"
  $script:saveCandidates = $cands
  $script:saveCursor = 0
  $script:saveTotal = $cands.Count
  Write-HudLog ("save-start $cardInfo key=$($script:saveKey) candidates=" +
    (($cands | ForEach-Object { "$($_.M)@$($_.MaxEnd)" }) -join ','))
  Start-CandidateSave
}

function Start-CandidateSave {
  if ($script:saveCursor -ge @($script:saveCandidates).Count) {
    $script:saving = $false
    $script:saveProc = $null
    Set-Notice "保存失败，见 work\hud_save_err.txt" 6
    return
  }
  $m = $script:saveCandidates[$script:saveCursor]
  $script:saveMedia = $m
  Remove-Item -LiteralPath $script:saveOut, $script:saveErr -ErrorAction SilentlyContinue
  try {
    $script:saveProc = Start-Process -FilePath 'pwsh.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolScript,
      '-SaveUrl', $m.Url, '-SaveTag', $m.M, '-OutDir', $OutDir
    ) -RedirectStandardOutput $script:saveOut -RedirectStandardError $script:saveErr
    $script:saving = $true
    Set-Notice ("保存中… ($($script:saveCursor + 1)/$($script:saveTotal))") 300
    Write-HudLog ("save-try $($script:saveCursor + 1)/$($script:saveTotal) m=$($m.M) urlLen=$($m.Url.Length)")
  } catch {
    $script:saving = $false
    Write-HudLog ("save-start-error " + $_.Exception.Message)
    Set-Notice ("启动保存失败：" + $_.Exception.Message) 5
  }
}

function Poll-Save {
  if (-not $script:saving -or -not $script:saveProc) { return }
  if (-not $script:saveProc.HasExited) { return }
  $out = ''
  if (Test-Path -LiteralPath $script:saveOut) { $out = Get-Content -LiteralPath $script:saveOut -Raw }
  $saved = $null
  if ($out -match 'SAVED=(.+)') { $saved = $matches[1].Trim().TrimEnd([char]13, [char]10) }
  if ($saved) {
    if ($script:saveKey -like 'manual|*') { $script:saveKey = 'manual|' + $script:saveMedia.M }
    $entry = [pscustomobject]@{
      key         = $script:saveKey
      m           = $script:saveMedia.M
      file        = $saved
      time        = (Get-Date).ToString('o')
      duration    = $script:saveDur
      description = $script:saveDesc
    }
    $script:index[$script:saveKey] = $entry
    Save-Index
    Write-HudLog ("save-ok file=$saved m=$($script:saveMedia.M)")
    Set-Notice ("✓ 已保存 " + (Split-Path $saved -Leaf)) 6
    $script:saving = $false
    $script:saveProc = $null
    return
  }

  Write-HudLog ("save-fail try=$($script:saveCursor + 1)/$($script:saveTotal) m=$($script:saveMedia.M) exit=$($script:saveProc.ExitCode) outLen=$($out.Length)")
  if (($script:saveCursor + 1) -lt $script:saveTotal) {
    $script:saveCursor++
    Start-CandidateSave
    return
  }
  Set-Notice "保存失败，见 work\hud_save_err.txt" 6
  $script:saving = $false
  $script:saveProc = $null
}

function Get-SaveProgress {
  try {
    if (-not (Test-Path -LiteralPath $script:saveOut)) { return '' }
    $lines = @(Get-Content -LiteralPath $script:saveOut -Tail 5 -ErrorAction SilentlyContinue |
      Where-Object { $_ -match '\S' })
    if ($lines.Count -eq 0) { return '' }
    return (($lines[-1] -replace '^\[\d{2}:\d{2}:\d{2}\]\s*', '').Trim())
  } catch { return '' }
}

# ---------------- Diagnose ----------------
if ($Diagnose) {
  Refresh-Index
  $p = Get-WeChatHost
  if (-not $p) { Write-Host "没有找到微信视频号主页窗口" -ForegroundColor Red; exit 1 }
  "微信 pid=$($p.Pid) hwnd=$($p.Hwnd) title=$($p.Title)"
  "输出目录：$OutDir"
  "候选卡片窗口："
  foreach ($h in @($script:hostCands)) {
    "  hwnd=$($h.Hwnd) pid=$($h.Pid) rect=$($h.Rect) title=$($h.Title)"
  }
  $pt = New-Object HudNative+POINT
  [void][HudNative]::GetCursorPos([ref]$pt)
  "光标：$($pt.X),$($pt.Y)"
  $cards = Get-Cards $p.Hwnd
  "识别到卡片：$($cards.Count)"
  foreach ($c in $cards) {
    $hit = Find-Downloaded $c.Seconds
    $state = if ($hit) { "已下载 $($hit.Name)" } else { "未下载" }
    "{0},{1} {2}x{3} | {4} | {5} | {6} | {7}" -f `
      [int]$c.Cover.X, [int]$c.Cover.Y, [int]$c.Cover.Width, [int]$c.Cover.Height,
      $c.Duration, $state, (Shorten $c.Description 36), $c.Like
  }
  exit 0
}

# ---------------- HUD ----------------
Refresh-Index
Load-Index
# 只从启动之后新增的 flows 行里取“当前播放”，避免把历史 URL 当成正在播放
if (Test-Path -LiteralPath $FlowsFile) { $script:flowOffset = [long](Get-Item -LiteralPath $FlowsFile).Length }

$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'WidthAndHeight'
$win.MaxWidth = 460

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = New-Object System.Windows.CornerRadius(8)
$border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(236, 18, 18, 18))
$border.BorderThickness = New-Object System.Windows.Thickness(1)
$border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(80, 255, 255, 255))
$border.Padding = New-Object System.Windows.Thickness(12, 9, 12, 9)

$panel = New-Object System.Windows.Controls.StackPanel

$title = New-Object System.Windows.Controls.TextBlock
$title.FontSize = 12.5
$title.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$title.FontWeight = [System.Windows.FontWeights]::SemiBold
$title.Foreground = [System.Windows.Media.Brushes]::White
$title.TextTrimming = 'CharacterEllipsis'
$title.MaxWidth = 420

$status = New-Object System.Windows.Controls.TextBlock
$status.FontSize = 12
$status.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$status.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
$status.TextTrimming = 'CharacterEllipsis'
$status.MaxWidth = 420

$meta = New-Object System.Windows.Controls.TextBlock
$meta.FontSize = 11
$meta.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$meta.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 160, 160, 160))
$meta.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
$meta.TextTrimming = 'CharacterEllipsis'
$meta.MaxWidth = 420

[void]$panel.Children.Add($title)
[void]$panel.Children.Add($status)
[void]$panel.Children.Add($meta)
$border.Child = $panel
$win.Content = $border

$win.Show()
$win.Hide()

$helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
$script:hwnd = $helper.Handle
$ex = [HudNative]::GetWindowLong($script:hwnd, -20)
# WS_EX_TRANSPARENT 0x20 | WS_EX_TOOLWINDOW 0x80 | WS_EX_NOACTIVATE 0x8000000
[void][HudNative]::SetWindowLong($script:hwnd, -20, ($ex -bor 0x20 -bor 0x80 -bor 0x8000000))

# 覆盖率覆盖层：透明、置顶、点击穿透，只在已下载卡片的封面上画“✓ 已下载”
$script:dpiScale = 1.0
try {
  $dpi = [HudNative]::GetDpiForWindow($script:hwnd)
  if ($dpi -gt 0) { $script:dpiScale = $dpi / 96.0 }
} catch { }
$screenW = [HudNative]::GetSystemMetrics(0)
$screenH = [HudNative]::GetSystemMetrics(1)

$badgeWin = New-Object System.Windows.Window
$badgeWin.WindowStyle = 'None'
$badgeWin.AllowsTransparency = $true
$badgeWin.Background = [System.Windows.Media.Brushes]::Transparent
$badgeWin.Topmost = $true
$badgeWin.ShowInTaskbar = $false
$badgeWin.ShowActivated = $false
$badgeWin.ResizeMode = 'NoResize'
$badgeWin.Left = 0
$badgeWin.Top = 0
$badgeWin.Width = $screenW / $script:dpiScale
$badgeWin.Height = $screenH / $script:dpiScale
$badgeWin.IsHitTestVisible = $false

$badgeCanvas = New-Object System.Windows.Controls.Canvas
$badgeWin.Content = $badgeCanvas
$badgeWin.Show()
$badgeWin.Hide()

$badgeHelper = New-Object System.Windows.Interop.WindowInteropHelper($badgeWin)
$script:badgeHwnd = $badgeHelper.Handle
$bex = [HudNative]::GetWindowLong($script:badgeHwnd, -20)
[void][HudNative]::SetWindowLong($script:badgeHwnd, -20, ($bex -bor 0x20 -bor 0x80 -bor 0x8000000))
$script:badgeSig = ''

$script:cards = @()
$script:lastCard = $null
$script:lastCardTime = [datetime]::MinValue
$script:lastTipCard = $null
$script:lastTipUntil = [datetime]::MinValue
$script:lastTipX = 0
$script:lastTipY = 0
$script:lastRefresh = [datetime]::MinValue
$script:lastIndex = [datetime]::MinValue
$script:visible = $false
$script:StateFile = Join-Path $env:TEMP 'wx_hud_state.log'
$script:HudLog = Join-Path $PSScriptRoot 'work\hud.log'

function Write-HudLog([string]$msg) {
  try {
    Add-Content -LiteralPath $script:HudLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding utf8
  } catch { }
}

function Write-DebugState([string]$msg) {
  if ($DebugState) { Set-Content -LiteralPath $script:StateFile -Value $msg -Encoding utf8 }
}

$green = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 74, 222, 128))
$amber = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 251, 191, 36))
$grey = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 160, 160, 160))

function Set-HudPosition([int]$x, [int]$y) {
  $sw = [HudNative]::GetSystemMetrics(0)
  $sh = [HudNative]::GetSystemMetrics(1)
  $w = 440; $h = 110
  if ($x + $w + 20 -gt $sw) { $x = $x - $w - 18 } else { $x = $x + 18 }
  if ($y + $h + 20 -gt $sh) { $y = $y - $h - 18 } else { $y = $y + 18 }
  # SWP_NOSIZE 0x1 | SWP_NOACTIVATE 0x10；不带上 SWP_NOZORDER，确保抬到 topmost 带最上面
  [void][HudNative]::SetWindowPos($script:hwnd, [IntPtr]::new(-1), $x, $y, 0, 0, 0x1 -bor 0x10)
}

function Show-Hud {
  if (-not $script:visible) {
    $win.Show()
    $win.Topmost = $true
    $script:visible = $true
  }
}

function Hide-Hud {
  if ($script:visible) {
    $win.Hide()
    $script:visible = $false
  }
}

function Hide-Badges {
  try { if ($badgeWin.IsVisible) { $badgeWin.Hide() } } catch { }
}

function Update-Badges($cards) {
  try {
    $list = @()
    foreach ($c in $cards) {
      $e = Get-IndexedEntry $c $null
      if (-not $e) {
        $hit = Find-Downloaded $c.Seconds
        if ($hit) { $e = [pscustomobject]@{ file = $hit.FullName } }
      }
      if ($e) { $list += [pscustomobject]@{ Card = $c; File = $e.file } }
    }
    $sig = ($list | ForEach-Object {
        "{0}:{1}:{2}" -f [int]$_.Card.Cover.X, [int]$_.Card.Cover.Y, $_.Card.Duration
      }) -join ';'
    if ($sig -eq $script:badgeSig -and $badgeWin.IsVisible) {
      if ($script:badgeHwnd) {
        [void][HudNative]::SetWindowPos($script:badgeHwnd, [IntPtr]::new(-1), 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x10)
      }
      return
    }
    $script:badgeSig = $sig
    $badgeCanvas.Children.Clear()

    $greenBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(235, 22, 163, 74))
    $white = [System.Windows.Media.Brushes]::White
    $font = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    foreach ($b in $list) {
      $bd = New-Object System.Windows.Controls.Border
      $bd.Background = $greenBg
      $bd.CornerRadius = New-Object System.Windows.CornerRadius(4)
      $bd.Padding = New-Object System.Windows.Thickness(7, 3, 7, 3)
      $tb = New-Object System.Windows.Controls.TextBlock
      $tb.Text = "✓ 已下载"
      $tb.FontSize = 11
      $tb.FontFamily = $font
      $tb.Foreground = $white
      $bd.Child = $tb
      $left = ($b.Card.Cover.Right - 78) / $script:dpiScale
      $top = ($b.Card.Cover.Y + 6) / $script:dpiScale
      [System.Windows.Controls.Canvas]::SetLeft($bd, $left)
      [System.Windows.Controls.Canvas]::SetTop($bd, $top)
      [void]$badgeCanvas.Children.Add($bd)
    }
    if ($list.Count -gt 0) {
      if (-not $badgeWin.IsVisible) { $badgeWin.Show() }
      $badgeWin.Topmost = $true
      if ($script:badgeHwnd) {
        # 保持覆盖层在 topmost 带最上面；SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE
        [void][HudNative]::SetWindowPos($script:badgeHwnd, [IntPtr]::new(-1), 0, 0, 0, 0, 0x1 -bor 0x2 -bor 0x10)
      }
    } else {
      $badgeWin.Hide()
    }
  } catch { }
}

function Update-Hud {
  try {
    Read-MediaFlows
    Poll-Save

    # F8：低字节 bit0 表示“上次调用后按下过”，即使快速点按也不会漏
    $f8State = [HudNative]::GetAsyncKeyState(0x77)
    $f8 = (((($f8State -band 0x8000) -ne 0)) -or ((($f8State -band 1) -ne 0)))
    if ($f8 -and -not $script:f8Down) {
      $f8Cur = Get-BoundMedia
      if (-not $f8Cur) { $f8Cur = Get-CurrentMedia }
      $f8Id = if ($f8Cur) { $f8Cur.M } else { '' }
      Write-HudLog ("f8 cards=$(@($script:cards).Count) media=$f8Id")
      if (@($script:cards).Count -eq 0) {
        $hp = Get-WeChatHost
        if ($hp) { $script:cards = Get-Cards $hp.Hwnd }
      }
      Start-Save
    }
    $script:f8Down = $f8

    $fg = [HudNative]::GetForegroundWindow()
    $fgPid = [uint32]0
    [void][HudNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $wechatPids = @(Get-Process Weixin, WeChatAppEx -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $isWeChatFg = ($wechatPids -contains [int]$fgPid)
    $noticeActive = ($script:notice -and (Get-Date) -lt $script:noticeUntil)
    $progress = if ($script:saving) { Get-SaveProgress } else { '' }

    $p = Get-WeChatHost
    if (-not $p) { Hide-Hud; Hide-Badges; return }

    if (-not $ForceShow -and -not $isWeChatFg) {
      if ($noticeActive) {
        $cpt = New-Object HudNative+POINT
        if ($PinX -ge 0 -and $PinY -ge 0) { $cpt.X = $PinX; $cpt.Y = $PinY }
        else { [void][HudNative]::GetCursorPos([ref]$cpt) }
        $title.Text = "wx-hud"
        $status.Text = $script:notice
        $status.Foreground = if ($script:notice.StartsWith('✓')) { $green } else { $amber }
        $meta.Text = ""
        Show-Hud
        Set-HudPosition $cpt.X $cpt.Y
      } else {
        Hide-Hud
      }
      Hide-Badges
      Write-DebugState ("bg fg=$fg wechat=$($p.Hwnd) notice=$($script:notice)")
      return
    }
    if ([HudNative]::IsIconic($p.Hwnd)) { Hide-Hud; Hide-Badges; return }

    $now = Get-Date
    if (($now - $script:lastIndex).TotalSeconds -gt 5) { Refresh-Index; $script:lastIndex = $now }
    if (($now - $script:lastRefresh).TotalMilliseconds -gt 600) {
      $script:cards = Get-Cards $p.Hwnd
      $script:lastRefresh = $now
    }
    Update-Badges $script:cards

    $pt = New-Object HudNative+POINT
    if ($PinX -ge 0 -and $PinY -ge 0) {
      $pt.X = $PinX; $pt.Y = $PinY
    } else {
      [void][HudNative]::GetCursorPos([ref]$pt)
    }
    $card = Get-CardHit $script:cards $pt.X $pt.Y
    $hitCard = $card
    if ($hitCard) {
      $ckey = Get-CardKey $hitCard
      if ($ckey -ne $script:hoverKey) {
        $script:hoverKey = $ckey
        $script:hoverStart = Get-Date
      }
      $needBind = -not $script:cardMedia.ContainsKey($ckey)
      if (-not $needBind) {
        $needBind = ((Get-Date) - $script:cardMedia[$ckey].Time).TotalSeconds -gt 60
      }
      if ($needBind) {
        $hits = @(Get-MediaCandidates 5 |
          Where-Object { $_.First -ge $script:hoverStart.AddSeconds(-0.3) } |
          Sort-Object -Property First)
        if ($hits.Count -gt 0) {
          $script:cardMedia[$ckey] = [pscustomobject]@{
            M = $hits[0].M; Url = $hits[0].Url; Time = Get-Date
          }
          Write-HudLog ("bind card=$ckey m=$($hits[0].M)")
        }
      }
    }
    $noticeActive = ($script:notice -and (Get-Date) -lt $script:noticeUntil)
    if ($card) {
      $script:lastCard = $card
      $script:lastCardTime = Get-Date
      $script:lastTipCard = $card
      $script:lastTipX = $pt.X
      $script:lastTipY = $pt.Y
      $script:lastTipUntil = (Get-Date).AddSeconds([Math]::Max(1, $LingerSeconds))
    } elseif (-not $noticeActive -and $script:lastTipCard -and (Get-Date) -lt $script:lastTipUntil) {
      # 光标刚离开卡片/被播放器盖住时，让提示停留几秒
      $card = $script:lastTipCard
      $pt.X = $script:lastTipX
      $pt.Y = $script:lastTipY
    }

    if (-not $card) {
      if ($noticeActive) {
        $title.Text = "wx-hud"
        if ($script:saving) {
          $status.Text = "保存中…"
          $status.Foreground = $amber
          $meta.Text = if ($progress) { $progress } else { "下载密文…" }
        } else {
          $status.Text = $script:notice
          $status.Foreground = if ($script:notice.StartsWith('✓')) { $green } else { $amber }
          $meta.Text = ""
        }
        Show-Hud
        Set-HudPosition $pt.X $pt.Y
      } elseif ($ForceShow) {
        $title.Text = "HUD 测试"
        $status.Text = "cards=$($script:cards.Count) cur=$($pt.X),$($pt.Y)"
        $status.Foreground = $grey
        $meta.Text = "未命中卡片"
        Show-Hud
        Set-HudPosition $pt.X $pt.Y
      } else {
        Hide-Hud
      }
      Write-DebugState ("nocard cards=$($script:cards.Count) cur=$($pt.X),$($pt.Y)")
      return
    }

    $media = Get-BoundMedia $card
    if (-not $media) { $media = Get-CurrentMedia }
    $indexed = Get-IndexedEntry $card $media
    $title.Text = if ($card.Description) { Shorten $card.Description 48 } else { "（无文案）" }

    if ($noticeActive) {
      if ($script:saving) {
        $status.Text = "保存中…"
        $status.Foreground = $amber
        $meta.Text = if ($progress) { $progress } else { "下载密文…" }
      } else {
        $status.Text = $script:notice
        $status.Foreground = if ($script:notice.StartsWith('✓')) { $green } else { $amber }
        $meta.Text = "时长 $($card.Duration) · 点赞 $($card.Like)"
      }
    } elseif ($indexed) {
      $status.Text = "✓ 已下载"
      $status.Foreground = $green
      $meta.Text = "时长 $($card.Duration) · $(Split-Path $indexed.file -Leaf)"
    } else {
      $hit = Find-Downloaded $card.Seconds
      if ($hit) {
        $status.Text = "✓ 已下载（按时长匹配）"
        $status.Foreground = $green
        $meta.Text = "时长 $($card.Duration) · $($hit.Name)"
      } else {
        $status.Text = "未下载"
        $status.Foreground = $amber
        $meta.Text = "时长 $($card.Duration) · 点赞 $($card.Like) · 悬停播放后按 F8 保存"
      }
    }

    Show-Hud
    Set-HudPosition $pt.X $pt.Y
    $wv = [HudNative]::IsWindowVisible($script:hwnd)
    Write-DebugState ("ok p=$($p.Pid) fg=$fg cards=$($script:cards.Count) cur=$($pt.X),$($pt.Y) card=$($card.Duration) media=$($media.M) vis=$($script:visible) win32=$wv")
  } catch {
    Write-DebugState ("ERR " + $_.Exception.Message)
    Write-HudLog ("ERR " + $_.Exception.Message)
  }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(100, $IntervalMs))
$timer.Add_Tick({ Update-Hud })
$timer.Start()

Write-Host "wx-hud 已启动：悬停卡片查看状态，F8 保存当前视频。Ctrl+C 退出。" -ForegroundColor Cyan
Write-HudLog ("start pid=$PID out=$OutDir")
Write-Host "输出目录：$OutDir" -ForegroundColor DarkGray
[System.Windows.Threading.Dispatcher]::Run()



