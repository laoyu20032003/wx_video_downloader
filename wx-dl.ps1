<#
  wx-dl.ps1 —— 微信视频号（4.2 liteapp）一键下载/修复工具

  用法：
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1 -OutDir "D:\视频号" -SelfTest
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1 -Upstream ""            # 强制直连
      powershell -ExecutionPolicy Bypass -File wx-dl.ps1 -Upstream 127.0.0.1:10808

  工作方式：
    1. 启动本地 mitmproxy（使用 setup.ps1 生成并已安装的根证书），透明转发、不改写页面；
    2. 把系统代理指向它。原代理是本机端口、且**端口确实有人监听**时才做链式上游，否则直连；
       早期版本无条件相信注册表里的 ProxyServer，系统代理关闭后那个残留端口就是死的，
       于是所有请求都变成 502 Bad Gateway；
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
# 原生命令非零退出不要变成异常：ffprobe/ffmpeg 对「这不是这条视频的头」必然报错，
# 那是候选级别的失败，不该冒到外层把整条视频判死（之前只成功过一个，就是这个原因）。
# PS 7.3+ 才有这个开关，5.1 上赋值无害。
$PSNativeCommandUseErrorActionPreference = $false
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

# 控制台输出同时落一份到 work\run.log。出问题时只看控制台不够；而且本工具会改系统代理，
# mitm 一挂整机断网，远程协助也随之中断，只能事后翻这份日志看出当时试了哪些候选。
# 不用 Start-Transcript：实测它生成的文件一直是 0 字节（进程一关就什么都没留下），自己写最稳。
$LogFile = Join-Path $Work 'run.log'
function Add-Log([string]$line) {
  try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8) } catch {}
}
function Write-Step($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line -ForegroundColor Cyan
  Add-Log $line
}
function Write-Warn($msg) {
  Write-Host $msg -ForegroundColor Yellow
  Add-Log ("        " + $msg)
}

# 解析外部命令：先信 PATH，再试常见固定位置（无包管理器的机器上 PATH 常常没配好）
function Resolve-Tool([string]$name, [string[]]$extra) {
  $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c -and $c.Source) { return $c.Source }
  foreach ($e in $extra) { if ($e -and (Test-Path -LiteralPath $e)) { return $e } }
  return $null
}

# 从一行 flows.log 里取出「这条视频的身份 + 下载地址」；不是视频就返回 $null
function Get-FlowVideo([string]$line) {
  $parts = $line -split "`t"
  if ($parts.Count -lt 5) { return $null }
  $url = $parts[4].Trim()
  if ($url -notmatch 'finder\.video\.qq\.com.*stodownload') { return $null }
  if ($url -notmatch 'token=' -or $url -notmatch 'sign=') { return $null }

  # 身份优先 m= 参数（实测只有「你点开的那条」带它）；没有就退到 encfilekey，
  # 同一条视频的所有分片请求共用同一个 encfilekey。早期版本没有 m= 就整条丢掉，
  # 于是播放第二条之后的视频毫无反应（一次运行里 1050 行这么被丢掉的）
  $tag = $null
  $alt = $null
  if ($url -match '[?&]m=([0-9a-fA-F]{8,})') { $tag = $matches[1] }
  elseif ($url -match '[?&]encfilekey=([^&]+)') { $tag = 'ek' + (Get-Md5Hex $matches[1]).Substring(0, 30) }
  else { return $null }
  # 带 m= 的地址通常也带 encfilekey：同一条视频会在两套身份下各出现一次，
  # 记下第二个身份，处理完一并标记，免得同一条片子下两遍
  if ($url -match '[?&]encfilekey=([^&]+)') { $alt = 'ek' + (Get-Md5Hex $matches[1]).Substring(0, 30) }
  if ($alt -eq $tag) { $alt = $null }
  return [pscustomobject]@{ Tag = $tag; Alt = $alt; Url = $url }
}

function Get-Md5Hex([string]$s) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try { return ([BitConverter]::ToString($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)))).Replace('-', '').ToLower() }
  finally { $md5.Dispose() }
}

$Ffmpeg = Resolve-Tool 'ffmpeg'  @((Join-Path $env:USERPROFILE 'ffmpeg\bin\ffmpeg.exe'))
$Ffprobe = Resolve-Tool 'ffprobe' @((Join-Path $env:USERPROFILE 'ffmpeg\bin\ffprobe.exe'))
$Curl   = Resolve-Tool 'curl.exe' @((Join-Path $env:SystemRoot 'System32\curl.exe'))
if (-not $Ffmpeg -or -not $Ffprobe) {
  throw "找不到 ffmpeg / ffprobe：请把它们加入 PATH，或放到 $env:USERPROFILE\ffmpeg\bin\。"
}
if (-not $Curl) { throw "找不到 curl.exe（Windows 10/11 自带，应位于 System32）。" }

# 检测一个 host:port 是否真的能连上（用于判断“上游还活着吗”）
function Test-TcpPort([string]$endpoint, [int]$timeoutMs = 800) {
  if ($endpoint -notmatch '^(?<h>\S+):(?<p>\d+)$') { return $false }
  $host_ = $matches['h']
  $port_ = [int]$matches['p']
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($host_, $port_, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
    $client.EndConnect($iar)
    return $client.Connected
  }
  catch { return $false }
  finally { if ($client) { try { $client.Close() } catch {} } }
}

# 决定上游：宁可直接，也不要链到一个死端口（那会让微信整页 502）
function Resolve-Upstream([string]$requested, [int]$port, $snap) {
  if ($requested -eq 'auto') {
    if ([int]$snap.Enable -ne 1) {
      return [pscustomobject]@{ Server = ''; Note = '系统代理当前未启用，直连' }
    }
    if ($snap.Server -notmatch '^(127\.0\.0\.1|localhost):(\d+)$') {
      return [pscustomobject]@{ Server = ''; Note = "原代理不是本机端口（$($snap.Server)），直连" }
    }
    $origPort = [int]$matches[2]
    if ($origPort -eq $port) {
      return [pscustomobject]@{ Server = ''; Note = "原代理端口与本工具同端口（$port），放弃链式上游以免自环" }
    }
    if (-not (Test-TcpPort $snap.Server)) {
      return [pscustomobject]@{ Server = ''; Note = "原代理 $($snap.Server) 没有在监听，已改为直连（链过去就是 Bad Gateway）" }
    }
    return [pscustomobject]@{ Server = $snap.Server; Note = "链式上游 $($snap.Server)" }
  }

  if (-not $requested) { return [pscustomobject]@{ Server = ''; Note = '按参数指定直连' } }

  $normalized = $requested -replace '^http(s)?://', ''
  if (-not (Test-TcpPort $normalized)) {
    return [pscustomobject]@{ Server = ''; Note = "指定的上游 $normalized 连不上，已回退直连" }
  }
  return [pscustomobject]@{ Server = $normalized; Note = "上游 $normalized" }
}

# mitmdump.exe 会再拉起一个 python 子进程，必须整棵树结束，否则端口会一直被杀不掉
function Stop-MitmTree([int]$mitmId) {
  if (-not $mitmId) { return }
  taskkill /PID $mitmId /T /F 2>$null | Out-Null
}

# ---------- 1. 找 mitmdump ----------
function Find-MitmDump {
  $cmd = Get-Command mitmdump -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $cands = @()
  foreach ($v in '313', '312', '311') {
    $cands += (Join-Path $env:LOCALAPPDATA "Programs\Python\Python$v\Scripts\mitmdump.exe")
  }
  $cands += 
  $cands += (Join-Path $env:USERPROFILE '.local\bin\mitmdump.exe')
  foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
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

# 判断「这份明文头是不是这条视频的」：
# 微信同时会在内存里留好几条视频的解密头（实测三条不同视频拿到同一份头），
# 拿别人的头去拼，ffprobe 会报 broken header / contradictionary STSC and STCO。
# 头里 mdat 声明的总长度是这条视频自己的属性：对上时和密文长度差 0，
# 拿错时相差几 MB 到几百 MB。这个判断只读内存头 + 密文里的明文尾部（偏移 >= 加密段
# 的位置本来就是明文），不拼接、不落盘，几十毫秒。
function Read-BE32([byte[]]$b, [int]$i) {
  return ([long]$b[$i] -shl 24) -bor ([long]$b[$i + 1] -shl 16) -bor ([long]$b[$i + 2] -shl 8) -bor [long]$b[$i + 3]
}

function Read-PlainAt([string]$cipher, [long]$off, [int]$n) {
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($cipher, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $fs.Position = $off
    $buf = New-Object byte[] $n
    $got = 0
    while ($got -lt $n) {
      $r = $fs.Read($buf, $got, $n - $got)
      if ($r -le 0) { break }
      $got += $r
    }
    if ($got -lt $n) { return $null }
    return $buf
  }
  catch { return $null }
  finally { if ($fs) { $fs.Dispose() } }
}

# 按「内存头 + 密文明文尾」的虚拟文件视图取字节；偏移落在加密段内只能从内存头取
function Get-BytesAt([byte[]]$header, [string]$cipher, [long]$encLen, [long]$pos, [int]$n) {
  if ($pos + $n -le $header.Length) {
    $out = New-Object byte[] $n
    [Array]::Copy($header, [int]$pos, $out, 0, $n)
    return $out
  }
  if ($pos -ge $encLen) { return (Read-PlainAt $cipher $pos $n) }
  return $null
}

function Test-Mp4Layout {
  param([byte[]]$Header, [string]$Cipher, [long]$EncLen)
  $size = (Get-Item -LiteralPath $Cipher).Length
  $pos = [long]0
  $declaredEnd = [long]0
  $firstType = ''
  $moovSeen = $false
  $guard = 0
  while ($pos -lt $size -and $guard -lt 64) {
    $guard++
    $hb = Get-BytesAt $Header $Cipher $EncLen $pos 8
    if (-not $hb) { break }
    $sz = Read-BE32 $hb 0
    $ty = [System.Text.Encoding]::ASCII.GetString($hb, 4, 4)
    if ($sz -eq 1) {
      $hb16 = Get-BytesAt $Header $Cipher $EncLen $pos 16
      if (-not $hb16) { break }
      $sz = ([long](Read-BE32 $hb16 8)) * 4294967296L + (Read-BE32 $hb16 12)
    }
    elseif ($sz -eq 0) { $sz = $size - $pos }
    if ($pos -eq 0) { $firstType = $ty }
    if ($ty -eq 'moov') {
      $moovSeen = $true
      # moov 自己比整个文件还大，只可能是别人的头（实测 0.5MB 的密文配上了 452 秒视频的头，
      # 声明总长只差 44KB，光看容差会放过它）
      if ($pos + $sz -gt $size) {
        return [pscustomobject]@{ Ok = $false; Reason = ("moov 声明 {0:N0} 字节，比整个文件（{1:N0}）还大" -f $sz, $size) }
      }
    }
    if ($sz -le 0) { break }
    $declaredEnd = $pos + $sz
    $pos += $sz
    # mdat 就是媒体数据本身，读完它就到头了；再往后是填充或垃圾，
    # 继续走会把声明长度算成一个荒唐的数（实测能"读"出 3.9GB）
    if ($ty -eq 'mdat') { break }
  }

  if ($firstType -ne 'ftyp') { return [pscustomobject]@{ Ok = $false; Reason = "头不是以 ftyp 开头（读到 '$firstType'）" } }
  if (-not $moovSeen) { return [pscustomobject]@{ Ok = $false; Reason = '头里没有 moov' } }
  if ($declaredEnd -le 0) { return [pscustomobject]@{ Ok = $false; Reason = 'box 结构读不出来' } }
  $diff = $declaredEnd - $size
  $tol = [Math]::Max([long]65536, [long]($size * 0.005))
  if ([Math]::Abs($diff) -gt $tol) {
    return [pscustomobject]@{ Ok = $false; Reason = ("头声明总长 {0:N0}，密文 {1:N0}，差 {2:N0}（这是别的视频的头）" -f $declaredEnd, $size, $diff) }
  }
  return [pscustomobject]@{ Ok = $true; Reason = ''; Declared = $declaredEnd }
}

# null muxer 会对 B 帧的 DTS 顺序发牢骚（实测一条 452 秒的片子只因为它被判成"坏文件"），
# 那不是解码失败；只有真正的读数据/解码错误才算
$script:BenignDecodeMsg = 'non monotonically increasing dts|Application provided invalid'
function Get-RealDecodeErrors([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
  return @($lines | Where-Object { $_ -and ($_ -notmatch $script:BenignDecodeMsg) }).Count
}

function Invoke-Fix([string]$url, [string]$tag) {
  $cipher = Join-Path $Work "cipher_$tag.bin"
  $candidate = Join-Path $Work "cand_$tag.mp4"
  $prefix = Join-Path $Work "prefix_$tag.bin"
  $errFile = Join-Path $Work 'err.txt'

  Write-Step "下载密文 ..."
  $code = & $Curl -s -m 900 --noproxy '*' -o $cipher -w "%{http_code}" $url
  $curlExit = $LASTEXITCODE
  $code = "$code".Trim()
  if ($curlExit -ne 0 -and $code -eq '200') {
    # 拿到 200 不代表收全了：连接中途断掉 curl 会回 18，留下一个半截文件，
    # 拿去拼头必然对不上，直接重试更省事
    $got = if (Test-Path -LiteralPath $cipher) { (Get-Item -LiteralPath $cipher).Length } else { 0 }
    Write-Host "  下载中断：curl exit=$curlExit，只收到 $got 字节" -ForegroundColor Red
    return $null
  }
  if ($code -ne '200') {
    $hint = ''
    if ($code -eq '000') { $hint = "（curl 没能完成请求，exit=$curlExit，多为地址非法或网络异常）" }
    elseif ($code -eq '403' -or $code -eq '401') { $hint = '（地址已过期，请在微信里重新播放这条视频）' }
    Write-Host "  下载失败 HTTP=$code$hint" -ForegroundColor Red
    return $null
  }

  $enclen = 131072
  foreach ($line in (& $Curl -s -I -m 30 --noproxy '*' $url)) {
    if ($line -match 'X-enclen:\s*(\d+)') { $enclen = [int]$matches[1] }
  }
  # 带 Range 的请求会把 X-enclen 回成「本次范围长度」（实测 bytes=0-1 就回 2），
  # 这种值拿来当偏移会把密文切错位置，宁可回退默认值
  if ($enclen -lt 1024 -or $enclen -gt 4194304) { $enclen = 131072 }

  $len = (Get-Item -LiteralPath $cipher).Length
  if ($len -le $enclen) { Write-Host "  文件过短（$len 字节）" -ForegroundColor Red; return $null }
  Write-Step ("密文 {0:N1} MB, 加密段 {1} 字节，扫描内存 ..." -f ($len / 1MB), $enclen)

  $procs = Get-CimInstance Win32_Process -Filter "Name='WeChatAppEx.exe'" |
    Where-Object { $_.WorkingSetSize -gt 60MB } | Sort-Object WorkingSetSize -Descending
  if (-not $procs) { Write-Host "  没有 WeChatAppEx 进程，请先打开视频号" -ForegroundColor Red; return $null }

  $seen = @{}
  $candCount = 0
  $gatePass = 0
  foreach ($p in $procs) {
    foreach ($a in [MemScan]::Scan([int]$p.ProcessId, 20)) {
      if ($a -lt 0) { continue }
      if (-not [MemScan]::Dump([int]$p.ProcessId, [long]$a, $enclen, $prefix)) { continue }
      $pref = [System.IO.File]::ReadAllBytes($prefix)
      if ($pref.Length -lt 4096) { continue }

      # 去重键用整段头的哈希：ftyp（前 64 字节）在所有视频里都一样，
      # 只比前 64 字节会把别的视频的头当成同一条，于是「旧头套新片」
      $key = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash($pref))
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = 1
      $candCount++

      # 结构闸门：先判断这份头是不是这条视频的，再决定要不要拼 46MB
      $lay = Test-Mp4Layout -Header $pref -Cipher $cipher -EncLen $enclen
      if (-not $lay.Ok) {
        Write-Warn ("  跳过候选 pid={0} 0x{1:X}：{2}" -f $p.ProcessId, [long]$a, $lay.Reason)
        continue
      }
      $gatePass++

      # 拼接：内存头 + 密文尾部。尾部用文件流按偏移读，不把整段密文驻留内存。
      $fsOut = $null
      $src = $null
      try {
        $fsOut = [System.IO.File]::Create($candidate)
        $fsOut.Write($pref, 0, $pref.Length)
        $src = [System.IO.File]::OpenRead($cipher)
        $src.Position = [long]$enclen
        $buf = New-Object byte[] (1048576)
        while ($true) {
          $n = $src.Read($buf, 0, $buf.Length)
          if ($n -le 0) { break }
          $fsOut.Write($buf, 0, $n)
        }
      }
      catch {
        Write-Warn "  拼接失败: $($_.Exception.Message)"
        continue
      }
      finally {
        if ($src) { $src.Dispose() }
        if ($fsOut) { $fsOut.Dispose() }
      }

      # 下面每一步都可能因为「这个头不是这条视频的」而报错，必须就地吃掉：
      # 一条错头把整个候选循环踢出去，就退化成「只试第一个候选」
      $dur = 0
      try {
        $durRaw = & $Ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $candidate 2> $errFile
        $dur = "$durRaw".Trim() -as [double]
      }
      catch { $dur = 0 }
      if (-not $dur -or $dur -le 1) { continue }

      $probeOk = $true
      try {
        & $Ffmpeg -v error -i $candidate -t 3 -f null - 2> $errFile
        if ($LASTEXITCODE -ne 0) { $probeOk = $false }
        elseif ((Get-RealDecodeErrors $errFile) -gt 0) { $probeOk = $false }
      }
      catch { $probeOk = $false }
      if (-not $probeOk) { continue }

      Write-Step ("命中：pid={0} 地址=0x{1:X} 时长={2:N1}s，全片校验 ..." -f $p.ProcessId, [long]$a, $dur)
      $fullOk = $true
      try {
        & $Ffmpeg -v error -i $candidate -f null - 2> $errFile
        if ($LASTEXITCODE -ne 0) { $fullOk = $false }
        elseif ((Get-RealDecodeErrors $errFile) -gt 0) { $fullOk = $false }
      }
      catch { $fullOk = $false }
      if (-not $fullOk) { continue }

      $info = & $Ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $candidate
      $wh = ("$info" -split ',')
      $h = if ($wh.Count -ge 2) { [Math]::Min([int]$wh[0], [int]$wh[1]) } else { '?' }
      $name = "视频号_$(Get-Date -Format 'yyyyMMdd_HHmmss')_${h}p_$([math]::Round($dur,0))s.mp4"
      $outPath = Join-Path $OutDir $name
      Copy-Item -LiteralPath $candidate -Destination $outPath -Force
      Write-Host "  已保存: $outPath" -ForegroundColor Green
      return $outPath
    }
  }

  if ($candCount -eq 0) {
    Write-Host "  内存里没有候选明文头：请把这条视频重新播放几秒再来（内存里只留最近播放的）" -ForegroundColor Yellow
  }
  elseif ($gatePass -eq 0) {
    Write-Host ("  {0} 个候选头都和这份密文对不上（都是别的视频的头），这条视频的头还没解码进内存：稍后重试或重播" -f $candCount) -ForegroundColor Yellow
  }
  else {
    Write-Host ("  {0} 个候选头结构匹配，但都没通过解码校验：请在微信里重播这条视频再试" -f $gatePass) -ForegroundColor Yellow
  }
  return $null
}

# ---------- 5. 启动 mitmproxy（失败可换模式重来） ----------
function Start-Mitm([string]$upstreamServer) {
  $mitmArgs = @('-q', '-p', "$Port", '--set', "confdir=$ConfDir", '-s', $CapturePy)
  if ($upstreamServer) { $mitmArgs += @('--mode', "upstream:http://$upstreamServer") }
  $proc = Start-Process -FilePath $mitm -ArgumentList $mitmArgs `
    -RedirectStandardOutput (Join-Path $Work 'mitm.out.log') `
    -RedirectStandardError (Join-Path $Work 'mitm.err.log') -PassThru -WindowStyle Hidden
  # 轮询端口，不要靠固定 sleep（mitmdump 冷启动要 2~3 秒，先探针会误判成网络坏）
  for ($i = 0; $i -lt 48; $i++) {
    Start-Sleep -Milliseconds 250
    if ($proc.HasExited) { return $null }
    if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) { return $proc }
  }
  if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) { return $proc }
  Stop-MitmTree $proc.Id
  return $null
}

# 真的从代理走一发请求，确认链路通（而不是用户打开微信才发现 502）
# 用明文 http 探针，避免把证书问题混进“上游挂了”的判断
function Test-ProxyPath([int]$proxyPort) {
  $code = & $Curl -s -o NUL -w "%{http_code}" --max-time 12 -x "127.0.0.1:$proxyPort" 'http://www.baidu.com/'
  return "$code".Trim()
}

# 根证书是否真的在「当前用户\受信任的根证书颁发机构」里（按指纹比对）
# 注意：不要用 curl 的 https 探针来判断——Windows 的 Schannel 会对 mitm 签发的证书
# 做撤销检查，离线时直接报 CRYPT_E_REVOCATION_OFFLINE，那是探针的假阳性。
function Test-CertInstalled {
  $store = $null
  try {
    $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $CertsDir 'ca-cert.pem')
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store 'Root', 'CurrentUser'
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    foreach ($c in $store.Certificates) {
      if ($c.Thumbprint -eq $leaf.Thumbprint) { return $true }
    }
    return $false
  }
  catch { return $false }
  finally { if ($store) { $store.Close() } }
}

# ---------- 6. 增量读 flows.log ----------
$script:flowOffset = [long]0
$script:flowTail = ''
function Read-NewFlows {
  if (-not (Test-Path -LiteralPath $Flows)) { return @() }
  $fs = $null
  $chunk = ''
  try {
    $fs = [System.IO.File]::Open($Flows, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($fs.Length -lt $script:flowOffset) { $script:flowOffset = [long]0; $script:flowTail = '' }
    if ($fs.Length -eq $script:flowOffset) { return @() }
    $fs.Position = $script:flowOffset
    $size = [int]($fs.Length - $script:flowOffset)
    $buf = New-Object byte[] $size
    $read = 0
    while ($read -lt $size) {
      $n = $fs.Read($buf, $read, $size - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    $script:flowOffset = $fs.Position       # 读成功才推进偏移，避免漏行
    $chunk = $script:flowTail + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  }
  catch {
    # python 正在追加、或文件刚被重建（句柄瞬时不可用）：本轮跳过，下一轮再读
    return @()
  }
  finally {
    if ($fs) { $fs.Dispose() }
  }

  $idx = $chunk.LastIndexOf("`n")
  if ($idx -lt 0) {
    $script:flowTail = $chunk      # 只有半行，等下一次补全
    return @()
  }
  $script:flowTail = $chunk.Substring($idx + 1)
  return ($chunk.Substring(0, $idx) -split "`n")
}

# ---------- 7. 主流程 ----------
$mitm = Find-MitmDump
Initialize-ConfDir
$snap = Get-ProxySnapshot

$up = Resolve-Upstream $Upstream $Port $snap
Write-Step "上游判定：$($up.Note)"

$pidFile = Join-Path $Work 'mitm.pid'
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
  $stale = $null
  if (Test-Path -LiteralPath $pidFile) { $stale = [int](Get-Content -LiteralPath $pidFile -Raw) }
  if ($stale -and (Get-Process -Id $stale -ErrorAction SilentlyContinue)) {
    Write-Step "清理上次残留的 mitmproxy (pid $stale) ..."
    Stop-MitmTree $stale
    Start-Sleep -Seconds 2
  }
  if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    throw "端口 $Port 已被占用，请换 -Port 或先结束占用进程。"
  }
}

Write-Step "启动 mitmproxy (端口 $Port, 上游 $(if($up.Server){$up.Server}else{'直连'})) ..."
$mitmProc = Start-Mitm $up.Server
if (-not $mitmProc) { throw "mitmproxy 启动失败，见 $Work\mitm.err.log" }

# 链路自检：带上游时若仍然 502，说明上游不可用，就地改成直连重来
$probe = ''
if ($up.Server) {
  $probe = Test-ProxyPath $Port
  if ($probe -eq '502' -or $probe -eq '000') {
    Write-Warn "  上游链路自检失败 (HTTP $probe)，改为直连重启 ..."
    Stop-MitmTree $mitmProc.Id
    Start-Sleep -Seconds 2
    $mitmProc = Start-Mitm $null
    if (-not $mitmProc) { throw "mitmproxy 直连重启失败，见 $Work\mitm.err.log" }
    $up = [pscustomobject]@{ Server = ''; Note = "上游不可用(HTTP $probe)，已自动改为直连" }
    $probe = Test-ProxyPath $Port
  }
  if ($probe -eq '502') {
    Write-Warn "  链路仍是 502，请检查网络出口；本工具不会改写内容，只做转发。"
  }
}

# 证书自检：不是用 https 探针，而是直接确认根证书进了「当前用户\受信任的根证书」
$certOk = Test-CertInstalled
if (-not $certOk) {
  Write-Warn "  根证书不在「当前用户\受信任的根证书颁发机构」：请重跑 setup.ps1，否则微信会报证书错误。"
}

Set-Content -Path $pidFile -Value $mitmProc.Id -Encoding ascii

# 先落盘代理快照，再起看门狗：即使直接关掉控制台窗口，也会自动还原代理
$snapFile = Join-Path $Work 'proxy_snapshot.json'
$snap | ConvertTo-Json | Set-Content -LiteralPath $snapFile -Encoding utf8
$watcher = Join-Path $Root 'watcher.ps1'
if (Test-Path -LiteralPath $watcher) {
  $hostExe = (Get-Process -Id $PID).Path
  if (-not $hostExe) { $hostExe = 'powershell' }
  Start-Process -FilePath $hostExe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcher,
    '-ParentPid', "$PID", '-Snapshot', $snapFile
  ) | Out-Null
}

Set-SystemProxy "127.0.0.1:$Port"
Remove-Item -LiteralPath $Flows -ErrorAction SilentlyContinue
$script:flowOffset = [long]0
$script:flowTail = ''

Write-Host ""
Write-Host "================ 已就绪 ================" -ForegroundColor Green
Write-Host " 输出目录 : $OutDir"
Write-Host " 代理端口 : 127.0.0.1:$Port"
Write-Host " 网络出口 : $(if($up.Server){"经上游 $($up.Server)"}else{'直连'})"
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
  Write-Host "  upstream: $(if($up.Server){$up.Server}else{'direct'})  http=$probe  cert=$certOk"
  Restore-SystemProxy $snap
  Stop-MitmTree $mitmProc.Id
  Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
  Write-Step "SelfTest 完成，已还原代理：$($snap.Server)"
  return
}

# 待处理队列：tag -> { Url, Attempts, NextTry }；失败会重试，不会一次失败就永久放弃
$jobs = @{}
$processed = @{}
$hits = @{}          # 这条视频被请求过几次：区分「正在播放」和「信息流预加载」
$maxAttempts = 3

try {
  while ($true) {
    # 1) 先消化待处理队列（一轮只干一件，避免同时扫内存）
    $now = Get-Date
    $dueTag = $null
    foreach ($tag in @($jobs.Keys)) {
      if ($jobs[$tag].NextTry -le $now) { $dueTag = $tag; break }
    }
    if ($dueTag) {
      $job = $jobs[$dueTag]
      Write-Host ""
      Write-Step ("处理 {0}（第 {1}/{2} 次）" -f ([string]$dueTag).Substring(0, [Math]::Min(10, ([string]$dueTag).Length)), ($job.Attempts + 1), $maxAttempts)
      $ok = $null
      try { $ok = Invoke-Fix $job.Url $dueTag }
      catch { Write-Host "  处理失败: $($_.Exception.Message)" -ForegroundColor Red }

      if ($ok) {
        $jobs.Remove($dueTag)
        $processed[$dueTag] = 1
        if ($job.Alt) { $processed[$job.Alt] = 1 }
      }
      else {
        $job.Attempts++
        if ($job.Attempts -ge $maxAttempts) {
          Write-Warn "  已重试 $maxAttempts 次仍失败，放弃这一条（重播该视频会重新触发）"
          $jobs.Remove($dueTag)
          $processed[$dueTag] = 1
          if ($job.Alt) { $processed[$job.Alt] = 1 }
        }
        else {
          $job.NextTry = (Get-Date).AddSeconds(20)
          Write-Warn "  20 秒后重试（下载失败，或明文头还没进内存）"
        }
      }
      continue
    }

    # 2) 再读日志里的新视频地址
    $lines = Read-NewFlows
    foreach ($line in $lines) {
      if (-not $line) { continue }
      # 日志是 python 以文本模式写的，Windows 下换行为 CRLF；增量读拿到的是原始字节，
      # 行尾会带 \r，必须去掉，否则拼出来的 URL 非法，curl 直接返回 000
      $line = $line.TrimEnd([char]13)
      $fv = Get-FlowVideo $line
      if (-not $fv) { continue }
      $url = $fv.Url
      $tag = $fv.Tag
      $alt = $fv.Alt
      if ($processed.ContainsKey($tag) -or $jobs.ContainsKey($tag)) { continue }
      if ($alt -and ($processed.ContainsKey($alt) -or $jobs.ContainsKey($alt))) { continue }

      if ($tag.StartsWith('ek')) {
        # 信息流会顺手预加载一堆封面和「下一条」，它们各自只请求一两次；
        # 真正在播的那条会连续发几十上百个分片请求。凑够 3 次才当视频处理
        $hits[$tag] = 1 + [int]$hits[$tag]
        if ($hits[$tag] -lt 3) { continue }
      }

      $jobs[$tag] = [pscustomobject]@{ Url = $url; Attempts = 0; NextTry = Get-Date; Alt = $alt }
    }

    Start-Sleep -Seconds 2
  }
}
finally {
  Write-Host ""
  Write-Step "退出，还原系统代理 ..."
  if (-not $KeepProxy) { Restore-SystemProxy $snap }
  if ($mitmProc -and -not $mitmProc.HasExited) { Stop-MitmTree $mitmProc.Id }
  Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
  Write-Step "已还原：$($snap.Server)"
}
