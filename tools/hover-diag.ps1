<#
  hover-diag.ps1 —— 从现有 hud.log / gui.log 还原 hover 行为

  不修改微信、不模拟鼠标，只做记录分析：
    1. 哪些 hover 没有进入界面，原因分类；
    2. hover 停留/点击延迟与首次下载成功率的关系；
    3. 第一次下载失败后，是否重试成功、间隔多久。

  用法：
    pwsh -File tools\hover-diag.ps1
    pwsh -File tools\hover-diag.ps1 -Out work\hover-diag.md
#>
param(
  [string]$HudLog = "",
  [string]$GuiLog = "",
  [string]$Out = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $HudLog) { $HudLog = Join-Path $root 'work\hud.log' }
if (-not $GuiLog) { $GuiLog = Join-Path $root 'work\gui.log' }
if (-not $Out) { $Out = Join-Path $root 'work\hover-diag.md' }

function Read-Log([string]$path, [string]$source) {
  $list = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
    if ($line -notmatch '^\[(\d{2}):(\d{2}):(\d{2})\]\s+(.*)$') { continue }
    $t = [datetime]::Today.AddHours([int]$matches[1]).AddMinutes([int]$matches[2]).AddSeconds([int]$matches[3])
    [void]$list.Add([pscustomobject]@{ Time = $t; Source = $source; Msg = $matches[4] })
  }
  return @($list)
}

$hud = @(Read-Log $HudLog 'hud')
$gui = @(Read-Log $GuiLog 'gui')
$attempts = New-Object System.Collections.ArrayList
$cur = $null
$currentMode = 'unknown'

function Close-Attempt($a) {
  if (-not $a) { return }
  if ($a.Bound) { $a.Duration = [Math]::Round(($a.BindTime - $a.Start).TotalSeconds, 1) }
  elseif ($a.LastAge -gt 0) { $a.Duration = [Math]::Round([double]$a.LastAge, 1) }
  else { $a.Duration = 0 }
  [void]$attempts.Add($a)
}

foreach ($e in $hud) {
  $m = $e.Msg
  if ($m -match '^mode=(\w+)') { $currentMode = $matches[1]; continue }
  if ($m -match '^hover-start key=(.*?) fallback=') {
    Close-Attempt $cur
    $cur = [pscustomobject]@{
      Start = $e.Time; Key = $matches[1]; LastAge = 0; Bound = $false
      BindTime = $null; Id = ''; Error = ''; Dwell = $false; Duration = 0
      Library = $false; DownloadStart = $null; FirstOutcome = ''
      EventualDone = $false; FirstFail = $false
      Candidates = -1; CandidateList = ''; Mode = $currentMode
    }
    continue
  }
  if (-not $cur) { continue }
  if ($m -match '^hover-dwell key=(.*?) age=([\d.]+)') {
    if ($matches[1] -eq $cur.Key) { $cur.Dwell = $true; $cur.LastAge = [double]$matches[2] }
    continue
  }
  if ($m -match '^hover-cands\s*(.*)$') {
    $cur.CandidateList = $matches[1].Trim()
    $cur.Candidates = if ($cur.CandidateList) { @($cur.CandidateList -split ',').Count } else { 0 }
    continue
  }
  if ($m -match '^bind card=(.*?) m=(\S+)') {
    if ($matches[1] -eq $cur.Key) {
      $cur.Bound = $true; $cur.BindTime = $e.Time; $cur.Id = $matches[2]
    }
    continue
  }
  if ($m -match '^ERRSTACK') { continue }
  if ($m -match '^ERR\s+(.*)$' -and -not $cur.Error) { $cur.Error = $matches[1]; continue }
}
Close-Attempt $cur

# GUI 事件按时间/ID 建索引
$downloadStart = @{}
$downloadEnd = @{}
$librarySeen = @{}
$allById = @{}
foreach ($e in $gui) {
  $m = $e.Msg
  if ($m -match '^download-start id=(\S+) auto=(\w+)') {
    $id = $matches[1]
    if (-not $downloadStart.ContainsKey($id)) { $downloadStart[$id] = New-Object System.Collections.ArrayList }
    [void]$downloadStart[$id].Add($e)
    if (-not $allById.ContainsKey($id)) { $allById[$id] = New-Object System.Collections.ArrayList }
    [void]$allById[$id].Add([pscustomobject]@{ Time = $e.Time; Kind = 'start' })
  } elseif ($m -match '^download-(fail|done) id=(\S+)(?:\s+auto=\w+)?(?:\s+reason=(.*))?') {
    $kind = $matches[1]; $id = $matches[2]
    $reason = if ($matches.Count -gt 3) { [string]$matches[3] } else { '' }
    if (-not $downloadEnd.ContainsKey($id)) { $downloadEnd[$id] = New-Object System.Collections.ArrayList }
    [void]$downloadEnd[$id].Add([pscustomobject]@{ Time = $e.Time; Kind = $kind; Reason = $reason })
    if (-not $allById.ContainsKey($id)) { $allById[$id] = New-Object System.Collections.ArrayList }
    [void]$allById[$id].Add([pscustomobject]@{ Time = $e.Time; Kind = $kind; Reason = $reason })
  } elseif ($m -match '^library-new id=(\S+)') {
    $id = $matches[1]
    if (-not $librarySeen.ContainsKey($id)) { $librarySeen[$id] = $e.Time }
  }
}

# 关联：每个 hover 尝试之后的首次下载/入库
foreach ($a in $attempts) {
  $a.Library = $false
  $a.DownloadStart = $null
  $a.FirstOutcome = ''
  $a.EventualDone = $false
  $a.FirstFail = $false
  if ($a.Bound -and $a.Id) {
    if ($librarySeen.ContainsKey($a.Id) -and $librarySeen[$a.Id] -ge $a.Start) { $a.Library = $true }
    $starts = @($downloadStart[$a.Id] | Where-Object { $_ -and $_.Time -ge $a.Start } | Sort-Object Time)
    if ($starts.Count -gt 0) {
      $a.DownloadStart = $starts[0].Time
      $ends = @($downloadEnd[$a.Id] | Where-Object { $_ -and $_.Time -ge $a.DownloadStart } | Sort-Object Time)
      if ($ends.Count -gt 0) {
        $a.FirstOutcome = $ends[0].Kind
        if ($a.FirstOutcome -eq 'fail') { $a.FirstFail = $true }
      }
      $a.EventualDone = [bool](@($downloadEnd[$a.Id] | Where-Object { $_ -and $_.Time -ge $a.DownloadStart -and $_.Kind -eq 'done' }).Count -gt 0)
    }
  }
}

# 1) 未进入界面的原因
$unbound = @()
foreach ($a in $attempts) {
  if (-not $a.Bound) {
    if ($a.Error) { $r = 'HUD 抛异常' }
    elseif (-not $a.Dwell) { $r = '未达到 1 秒停留' }
    elseif ($a.Candidates -eq 0) { $r = '有停留，0 个媒体候选' }
    else { $r = '有候选但未绑定' }
    $unbound += [pscustomobject]@{ Time = $a.Start; Duration = $a.Duration; Reason = $r; Key = $a.Key; Mode = $a.Mode }
  } elseif (-not $a.Library) {
    $unbound += [pscustomobject]@{ Time = $a.Start; Duration = $a.Duration; Reason = '绑定成功但未入库'; Key = $a.Key; Mode = $a.Mode }
  }
}
$reasonRows = @($unbound | Group-Object { "$($_.Reason) [mode=$($_.Mode)]" } | Sort-Object Count -Descending |
  ForEach-Object { [pscustomobject]@{ 原因 = $_.Name; 次数 = $_.Count } })

# 2) 停留/点击延迟 vs 首次成功
$tested = @($attempts | Where-Object { $_.DownloadStart })
$bins = @(
  @{ Name = '0-1s'; Min = 0; Max = 1 },
  @{ Name = '1-2s'; Min = 1; Max = 2 },
  @{ Name = '2-3s'; Min = 2; Max = 3 },
  @{ Name = '3-5s'; Min = 3; Max = 5 },
  @{ Name = '5s+'; Min = 5; Max = 999999 }
)
$corr = @()
foreach ($b in $bins) {
  $items = @($tested | Where-Object {
    $d = ($_.DownloadStart - $_.Start).TotalSeconds
    $d -ge $b.Min -and $d -lt $b.Max
  })
  $firstOk = @($items | Where-Object { $_.FirstOutcome -eq 'done' }).Count
  $eventualOk = @($items | Where-Object { $_.EventualDone }).Count
  $corr += [pscustomobject]@{
    点击时已停留 = $b.Name
    次数 = $items.Count
    首次成功 = $firstOk
    首次失败 = @($items | Where-Object { $_.FirstFail }).Count
    最终成功 = $eventualOk
  }
}

# 3) 第一次失败后的恢复
$recovery = @()
foreach ($id in @($allById.Keys)) {
  $events = @($allById[$id] | Sort-Object Time)
  for ($i = 0; $i -lt $events.Count; $i++) {
    if ($events[$i].Kind -ne 'fail') { continue }
    $failAt = $events[$i].Time
    $failReason = [string]$events[$i].Reason
    $nextStart = @($events | Where-Object { $_.Time -gt $failAt -and $_.Kind -eq 'start' } | Select-Object -First 1)
    if ($nextStart.Count -eq 0) {
      $recovery += [pscustomobject]@{ ID = $id; 失败时间 = $failAt; 失败原因 = $failReason; 是否重试 = '否'; 结果 = '未恢复'; 间隔 = '' }
      continue
    }
    $nextEnd = @($events | Where-Object { $_.Time -gt $nextStart[0].Time -and $_.Kind -in @('done','fail') } | Select-Object -First 1)
    $result = if ($nextEnd.Count -gt 0) { $nextEnd[0].Kind } else { 'pending' }
    $recovery += [pscustomobject]@{
      ID = $id; 失败时间 = $failAt; 失败原因 = $failReason; 是否重试 = '是'
      结果 = $result
      间隔 = ('{0:N0}s' -f ($nextStart[0].Time - $failAt).TotalSeconds)
    }
  }
}

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('# Hover 诊断报告')
[void]$lines.Add('')
[void]$lines.Add("生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$lines.Add("日志：$HudLog / $GuiLog")
[void]$lines.Add('')
[void]$lines.Add('## 1. 未进入界面的原因')
[void]$lines.Add('')
if ($reasonRows.Count -eq 0) { [void]$lines.Add('没有未入库的记录。') }
else {
  [void]$lines.Add('| 原因 | 次数 |')
  [void]$lines.Add('|---|---|')
  foreach ($r in $reasonRows) { [void]$lines.Add("| $($r.原因) | $($r.次数) |") }
}
[void]$lines.Add('')
[void]$lines.Add('## 2. 点击时已停留时长 vs 下载结果')
[void]$lines.Add('')
[void]$lines.Add('| 点击时已停留 | 次数 | 首次成功 | 首次失败 | 最终成功 |')
[void]$lines.Add('|---|---|---|---|---|')
foreach ($r in $corr) { [void]$lines.Add("| $($r.点击时已停留) | $($r.次数) | $($r.首次成功) | $($r.首次失败) | $($r.最终成功) |") }
[void]$lines.Add('')
[void]$lines.Add('## 3. 首次失败后的恢复')
[void]$lines.Add('')
if ($recovery.Count -eq 0) { [void]$lines.Add('没有下载失败记录。') }
else {
  [void]$lines.Add('| ID | 失败时间 | 失败原因 | 是否重试 | 结果 | 间隔 |')
  [void]$lines.Add('|---|---|---|---|---|---|')
  foreach ($r in $recovery) { [void]$lines.Add("| $($r.ID) | $($r.失败时间.ToString('HH:mm:ss')) | $($r.失败原因) | $($r.是否重试) | $($r.结果) | $($r.间隔) |") }
}
[void]$lines.Add('')
[void]$lines.Add('## 4. 明细')
[void]$lines.Add('')
[void]$lines.Add('| 开始 | 模式 | 停留 | 候选数 | 绑定 ID | 入库 | 点击延迟 | 首次结果 | 最终成功 | 未入库原因 |')
[void]$lines.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($a in $attempts) {
  $delay = if ($a.DownloadStart) { '{0:N1}s' -f ($a.DownloadStart - $a.Start).TotalSeconds } else { '' }
  $reason = ''
  if (-not $a.Bound) { $reason = if ($a.Error) { '异常' } elseif (-not $a.Dwell) { '未满1秒' } elseif ($a.Candidates -eq 0) { '无候选' } else { '有候选未绑定' } }
  elseif (-not $a.Library) { $reason = '绑定未入库' }
  [void]$lines.Add("| $($a.Start.ToString('HH:mm:ss')) | $($a.Mode) | $($a.Duration)s | $($a.Candidates) | $($a.Id) | $($a.Library) | $delay | $($a.FirstOutcome) | $($a.EventualDone) | $reason |")
}
[void]$lines.Add('')

$dir = Split-Path -Parent $Out
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Set-Content -LiteralPath $Out -Value ($lines -join "`r`n") -Encoding utf8
Write-Host "报告：$Out"
Write-Host "hover 尝试：$($attempts.Count)，未入库：$($unbound.Count)，已点击下载：$($tested.Count)"
$reasonRows | Format-Table -AutoSize
$corr | Format-Table -AutoSize
$recovery | Format-Table -AutoSize
