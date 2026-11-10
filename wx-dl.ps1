<#
  wx-dl.ps1 —— 微信视频号（4.2 liteapp）一键下载/修复工具

  用法：
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1 -OutDir "D:\视频号" -SelfTest

  工作方式：
    1. 启动本地 mitmproxy（使用 setup.ps1 生成并已安装的根证书），透明转发、不改写页面；
    2. 把系统代理指向它（原先指向本机端口的代理会作为上游链式转发，翻墙不受影响）；
    3. 你在微信里播放视频，脚本自动发现视频地址；
    4. 下载密文 → 从 WeChatAppEx.exe 内存里取「解密后的 MP4 头」→ 拼接 → 全片校验 → 存盘；
    5. 退出或关闭窗口时自动还原系统代理（由 watcher.ps1 兜底）。

  注意：微信会缓存系统代理，启动本工具后需要把微信「完全退出再重开」一次。
#>
param(
  [string]$OutDir = "",
  [int]$Port = 8898,
  [string]$Upstream = "auto",
  [switch]$SelfTest,
  [switch]$KeepProxy
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Root = $PSScriptRoot
$Work = Join-Path $Root 'work'
$ConfDir = Join-Path $Root 'mitm'
$CertsDir = Join-Path $Root 'certs'
$Flows = Join-Path $Root 'flows.log'
$CapturePy = Join-Path $Root 'capture.py'
$MemScanCs = Join-Path $Root 'MemScan.cs'

if (-not $OutDir) {
  $OutDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '视频号'
}
New-Item -ItemType Directory -Force -Path $Work, $ConfDir, $OutDir | Out-Null

function Write-Step($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Cyan }

# mitmdump.exe 会再拉起一个 python 子进程，必须整棵树结束，否则端口会一直被占
function Stop-MitmTree([int]$mitmId) {
  if (-not $mitmId) { return }
  taskkill /PID $mitmId /T /F 2>$null | Out-Null
}

# ---------- 1. 找 mitmdump ----------
function Find-MitmDump {
  $cmd = Get-Command mitmdump -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\Scripts\mitmdump.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\Scripts\mitmdump.exe'),
    'D:\DeepSeek\AI漫剧数据库\.venv-mitm\Scripts\mitmdump.exe'
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  throw "找不到 mitmdump。请先运行 setup.ps1，或 pip install mitmproxy 后重试。"
}

# ---------- 2. 准备 mitmproxy 证书目录 ----------
function Initialize-ConfDir {
  $cert = Join-Path $CertsDir 'ca-cert.pem'
  $key = Join-Path $CertsDir 'ca-key.pem'
  if (-not (Test-Path $cert) -or -not (Test-Path $key)) {
    throw "缺少根证书：请先运行 setup.ps1 生成并安装证书。"
  }
  $pem = Join-Path $ConfDir 'mitmproxy-ca.pem'
  $need = $true
  if (Test-Path $pem) {
    $need = (Get-Item $pem).LastWriteTimeUtc -lt (Get-Item $cert).LastWriteTimeUtc
  }
  if ($need) {
    $k = (Get-Content $key -Raw).TrimEnd()
    $c = (Get-Content $cert -Raw).TrimEnd()
    Set-Content -Path $pem -Value ($k + "`n" + $c + "`n") -Encoding ascii
  }
}

# ---------- 3. 系统代理 ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinInetX {
  [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
"@
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
function Get-ProxySnapshot {
  $p = Get-ItemProperty $RegPath
  return [pscustomobject]@{ Enable = [int]$p.ProxyEnable; Server = [string]$p.ProxyServer; Override = [string]$p.ProxyOverride }
}
function Set-SystemProxy([string]$server) {
  Set-ItemProperty $RegPath -Name ProxyEnable -Value 1
  Set-ItemProperty $RegPath -Name ProxyServer -Value $server
  [WinInetX]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [WinInetX]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}
function Restore-SystemProxy($snap) {
  Set-ItemProperty $RegPath -Name ProxyEnable -Value $snap.Enable
  Set-ItemProperty $RegPath -Name ProxyServer -Value $snap.Server
  if ($snap.Override) { Set-ItemProperty $RegPath -Name ProxyOverride -Value $snap.Override }
  [WinInetX]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [WinInetX]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

# ---------- 4. 从内存取明文头并拼接 ----------
if (-not ('MemScan' -as [type])) { Add-Type -Path $MemScanCs }

function Invoke-Fix([string]$url, [string]$tag) {
  $cipher = Join-Path $Work "cipher_$tag.bin"
  $candidate = Join-Path $Work "cand_$tag.mp4"
  $prefix = Join-Path $Work "prefix_$tag.bin"

  Write-Step "下载密文 ..."
  $code = curl.exe -s -m 900 --noproxy '*' -o $cipher -w "%{http_code}" $url
  if ($code -ne '200') { Write-Host "  下载失败 HTTP=$code" -ForegroundColor Red; return $null }

  $enclen = 131072
  foreach ($line in (curl.exe -s -I -m 30 --noproxy '*' $url)) {
    if ($line -match 'X-enclen:\s*(\d+)') { $enclen = [int]$matches[1] }
  }
  $bytes = [System.IO.File]::ReadAllBytes($cipher)
  if ($bytes.Length -le $enclen) { Write-Host "  文件过短" -ForegroundColor Red; return $null }
  Write-Step ("密文 {0:N1} MB, 加密段 {1} 字节，扫描内存 ..." -f ($bytes.Length / 1MB), $enclen)

  $tail = $bytes[$enclen..($bytes.Length - 1)]
  $procs = Get-CimInstance Win32_Process -Filter "Name='WeChatAppEx.exe'" |
    Where-Object { $_.WorkingSetSize -gt 60MB } | Sort-Object WorkingSetSize -Descending
  if (-not $procs) { Write-Host "  没有 WeChatAppEx 进程，请先打开视频号" -ForegroundColor Red; return $null }

  $seen = @{}
  foreach ($p in $procs) {
    foreach ($a in [MemScan]::Scan([int]$p.ProcessId, 20)) {
      if ($a -lt 0) { continue }
      if (-not [MemScan]::Dump([int]$p.ProcessId, [long]$a, $enclen, $prefix)) { continue }
      $pref = [System.IO.File]::ReadAllBytes($prefix)
      $key = [BitConverter]::ToString($pref[0..63])
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = 1

      $comb = New-Object byte[] ($pref.Length + $tail.Length)
      [Array]::Copy($pref, 0, $comb, 0, $pref.Length)
      [Array]::Copy($tail, 0, $comb, $pref.Length, $tail.Length)
      [System.IO.File]::WriteAllBytes($candidate, $comb)

      $dur = (ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $candidate) -as [double]
      $errFile = Join-Path $Work 'err.txt'
      $null = ffmpeg -v error -t 3 -i $candidate -f null - 2> $errFile
      $err = (Get-Content $errFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
      if ($err -ne 0 -or $dur -le 1) { continue }

      Write-Step ("命中：pid={0} 地址=0x{1:X} 时长={2:N1}s，全片校验 ..." -f $p.ProcessId, [long]$a, $dur)
      $null = ffmpeg -v error -i $candidate -f null - 2> $errFile
      if (((Get-Content $errFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines) -ne 0) { continue }

      $info = ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $candidate
      $wh = ($info -split ',')
      $h = if ($wh.Count -ge 2) { [Math]::Min([int]$wh[0], [int]$wh[1]) } else { '?' }
      $name = "视频号_$(Get-Date -Format 'yyyyMMdd_HHmmss')_${h}p_$([math]::Round($dur,0))s.mp4"
      $out = Join-Path $OutDir $name
      Copy-Item $candidate $out -Force
      Write-Host "  已保存: $out" -ForegroundColor Green
      return $out
    }
  }
  Write-Host "  没找到匹配的明文头：请把这条视频重新播放几秒再来（内存里只留最近播放的）" -ForegroundColor Yellow
  return $null
}

# ---------- 5. 主流程 ----------
$mitm = Find-MitmDump
Initialize-ConfDir
$snap = Get-ProxySnapshot
if ($Upstream -eq 'auto') {
  if ($snap.Server -match '^(127\.0\.0\.1|localhost):\d+$') { $Upstream = $snap.Server } else { $Upstream = '' }
}

$pidFile = Join-Path $Work 'mitm.pid'
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
  $stale = $null
  if (Test-Path $pidFile) { $stale = [int](Get-Content $pidFile -Raw) }
  if ($stale -and (Get-Process -Id $stale -ErrorAction SilentlyContinue)) {
    Write-Step "清理上次残留的 mitmproxy (pid $stale) ..."
    Stop-MitmTree $stale
    Start-Sleep -Seconds 2
  }
  if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    throw "端口 $Port 已被占用，请换 -Port 或先结束占用进程。"
  }
}

$mitmArgs = @('-q', '-p', "$Port", '--set', "confdir=$ConfDir", '-s', $CapturePy)
if ($Upstream) { $mitmArgs += @('--mode', "upstream:http://$Upstream") }

Write-Step "启动 mitmproxy (端口 $Port, 上游 $(if($Upstream){$Upstream}else{'直连'})) ..."
$mitmProc = Start-Process -FilePath $mitm -ArgumentList $mitmArgs `
  -RedirectStandardOutput (Join-Path $Work 'mitm.out.log') `
  -RedirectStandardError (Join-Path $Work 'mitm.err.log') -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
if ($mitmProc.HasExited) { throw "mitmproxy 启动失败，见 $Work\mitm.err.log" }
Set-Content -Path $pidFile -Value $mitmProc.Id -Encoding ascii

# 先落盘代理快照，再起看门狗：即使直接关掉控制台窗口，也会自动还原代理
$snapFile = Join-Path $Work 'proxy_snapshot.json'
$snap | ConvertTo-Json | Set-Content -Path $snapFile -Encoding utf8
$watcher = Join-Path $Root 'watcher.ps1'
if (Test-Path $watcher) {
  Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcher,
    '-ParentPid', "$PID", '-Snapshot', $snapFile
  ) | Out-Null
}

Set-SystemProxy "127.0.0.1:$Port"
Remove-Item $Flows -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================ 已就绪 ================" -ForegroundColor Green
Write-Host " 输出目录 : $OutDir"
Write-Host " 代理端口 : 127.0.0.1:$Port"
Write-Host ""
Write-Host " 第一次使用请：完全退出微信 → 重新打开 → 进入视频号播放视频" -ForegroundColor Yellow
Write-Host " 之后每播放一条视频，会在十几秒内自动保存（同名视频只处理一次）"
Write-Host " 停止：按 Ctrl+C，或直接关闭这个窗口（会自动还原系统代理）" -ForegroundColor Yellow
Write-Host "========================================"
Write-Host ""

if ($SelfTest) {
  Write-Step "SelfTest：检查代理与进程 ..."
  if ($mitmProc.HasExited) { throw "mitmproxy 已退出" }
  Write-Host "  mitmproxy alive: $(-not $mitmProc.HasExited)"
  Write-Host "  proxy: $((Get-ItemProperty $RegPath).ProxyServer)"
  Restore-SystemProxy $snap
  Stop-MitmTree $mitmProc.Id
  Remove-Item $pidFile -ErrorAction SilentlyContinue
  Write-Step "SelfTest 完成，已还原代理：$($snap.Server)"
  return
}

$processed = @{}
$pos = 0
try {
  while ($true) {
    if (-not (Test-Path $Flows)) { Start-Sleep -Seconds 2; continue }
    $lines = @(Get-Content $Flows -ErrorAction SilentlyContinue)
    if ($lines.Count -le $pos) { Start-Sleep -Seconds 2; continue }

    for ($i = $pos; $i -lt $lines.Count; $i++) {
      $parts = $lines[$i] -split "`t"
      if ($parts.Count -lt 5) { continue }
      $url = $parts[4]
      if ($url -notmatch 'finder\.video\.qq\.com.*stodownload') { continue }
      if ($url -notmatch '[?&]m=([0-9a-fA-F]+)') { continue }
      $tag = $matches[1]
      if ($processed.ContainsKey($tag)) { continue }
      if ($url -notmatch 'token=' -or $url -notmatch 'sign=') { continue }

      $processed[$tag] = 1
      Write-Host ""
      Write-Step "发现视频 m=$($tag.Substring(0,[Math]::Min(8,$tag.Length)))"
      try { $null = Invoke-Fix $url $tag } catch { Write-Host "  处理失败: $($_.Exception.Message)" -ForegroundColor Red }
    }
    $pos = $lines.Count
    Start-Sleep -Seconds 2
  }
}
finally {
  Write-Host ""
  Write-Step "退出，还原系统代理 ..."
  if (-not $KeepProxy) { Restore-SystemProxy $snap }
  if ($mitmProc -and -not $mitmProc.HasExited) { Stop-MitmTree $mitmProc.Id }
  Remove-Item $pidFile -ErrorAction SilentlyContinue
  Write-Step "已还原：$($snap.Server)"
}
