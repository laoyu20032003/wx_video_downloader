<#
  setup.ps1 —— 环境检查 + 根证书生成/安装

  做的事：
    1. 检查 PowerShell / ffmpeg / ffprobe / mitmdump 是否可用；
    2. 生成属于本机的一套根证书（certs\ca-cert.pem / ca-key.pem），只生成一次；
    3. 把根证书装进「当前用户 → 受信任的根证书颁发机构」（不需要管理员）；
    4. 提示下一步。

  用法：
      powershell -ExecutionPolicy Bypass -File setup.ps1
      powershell -ExecutionPolicy Bypass -File setup.ps1 -NoInstall   # 只生成证书，不安装（排查用）
      powershell -ExecutionPolicy Bypass -File setup.ps1 -Force       # 重新生成证书
#>
param(
  [switch]$NoInstall,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Root = $PSScriptRoot
$CertsDir = Join-Path $Root 'certs'
New-Item -ItemType Directory -Force -Path $CertsDir | Out-Null

function Write-Step($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host ("  [OK] " + $msg) -ForegroundColor Green }
function Write-Bad($msg) { Write-Host ("  [!!] " + $msg) -ForegroundColor Red }

function Wrap-Pem([string]$label, [byte[]]$bytes) {
  $b64 = [Convert]::ToBase64String($bytes)
  $lines = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $b64.Length; $i += 64) {
    $lines.Add($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)))
  }
  return "-----BEGIN $label-----`n" + ($lines -join "`n") + "`n-----END $label-----`n"
}

# ---- DER 编码：Windows PowerShell 5.1 / .NET Framework 没有 ExportPkcs8PrivateKey，手工拼 PKCS#1 ----
function Get-DerLength([int]$len) {
  if ($len -lt 0x80) { return ,([byte[]]@([byte]$len)) }
  $tmp = New-Object System.Collections.Generic.List[byte]
  $n = $len
  while ($n -gt 0) { $tmp.Insert(0, [byte]($n -band 0xFF)); $n = $n -shr 8 }
  $res = New-Object System.Collections.Generic.List[byte]
  $res.Add([byte](0x80 -bor $tmp.Count))
  $res.AddRange($tmp)
  return ,$res.ToArray()
}

function Get-DerInteger([byte[]]$be) {
  $i = 0
  while ($i -lt $be.Length - 1 -and $be[$i] -eq 0) { $i++ }
  $v = New-Object System.Collections.Generic.List[byte]
  if (($be[$i] -band 0x80) -ne 0) { $v.Add(0) }
  for ($k = $i; $k -lt $be.Length; $k++) { $v.Add($be[$k]) }
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add(0x02)
  $out.AddRange((Get-DerLength $v.Count))
  $out.AddRange($v)
  return ,$out.ToArray()
}

function Get-Pkcs1Der($rsa) {
  $p = $rsa.ExportParameters($true)
  $body = New-Object System.Collections.Generic.List[byte]
  $body.AddRange([byte[]]@(0x02, 0x01, 0x00))   # version = 0
  $body.AddRange((Get-DerInteger $p.Modulus))
  $body.AddRange((Get-DerInteger $p.Exponent))
  $body.AddRange((Get-DerInteger $p.D))
  $body.AddRange((Get-DerInteger $p.P))
  $body.AddRange((Get-DerInteger $p.Q))
  $body.AddRange((Get-DerInteger $p.DP))
  $body.AddRange((Get-DerInteger $p.DQ))
  $body.AddRange((Get-DerInteger $p.InverseQ))
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add(0x30)
  $out.AddRange((Get-DerLength $body.Count))
  $out.AddRange($body)
  return ,$out.ToArray()
}

function Get-PrivateKeyPem($rsa) {
  # PowerShell 7 / .NET Core 有 PKCS#8 导出，直接用
  if ($rsa.PSObject.Methods['ExportPkcs8PrivateKey']) {
    return Wrap-Pem 'PRIVATE KEY' $rsa.ExportPkcs8PrivateKey()
  }
  # Windows PowerShell 5.1 / .NET Framework：手工编码 PKCS#1
  return Wrap-Pem 'RSA PRIVATE KEY' (Get-Pkcs1Der $rsa)
}

Write-Host ""
Write-Host "========== wx_video_downloader 环境检查 ==========" -ForegroundColor Cyan

# 1) PowerShell
Write-Step "PowerShell"
Write-Ok "版本 $($PSVersionTable.PSVersion)  ($($PSVersionTable.PSEdition))"

# 2) 外部依赖
Write-Step "外部依赖"
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if ($ffmpeg) { Write-Ok "ffmpeg  $($ffmpeg.Source)" } else { Write-Bad "找不到 ffmpeg（需要加入 PATH）" }
if ($ffprobe) { Write-Ok "ffprobe $($ffprobe.Source)" } else { Write-Bad "找不到 ffprobe（需要加入 PATH）" }
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) { Write-Ok "curl    $($curl.Source)" } else { Write-Bad "找不到 curl.exe（Windows 10+ 自带）" }

$mitm = Get-Command mitmdump -ErrorAction SilentlyContinue
if (-not $mitm) {
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\Scripts\mitmdump.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\Scripts\mitmdump.exe'),
    'D:\DeepSeek\AI漫剧数据库\.venv-mitm\Scripts\mitmdump.exe'
  )
  foreach ($c in $cands) { if (Test-Path $c) { $mitm = Get-Item $c; break } }
}
if ($mitm) { Write-Ok "mitmdump $($mitm.Source)" } else { Write-Bad "找不到 mitmdump（pip install mitmproxy）" }

# 3) 证书
Write-Step "根证书"
$certFile = Join-Path $CertsDir 'ca-cert.pem'
$keyFile = Join-Path $CertsDir 'ca-key.pem'
$needGen = $Force -or -not (Test-Path $certFile) -or -not (Test-Path $keyFile)

if ($needGen) {
  Write-Host "  生成新的根证书（RSA 3072, 10 年）..."
  $rsa = [System.Security.Cryptography.RSA]::Create(3072)
  $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    "CN=wx-dl Root CA, O=wx-dl",
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

  $req.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
  $ku = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::CrlSign -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature
  $req.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($ku, $true))
  $req.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]::new($req.PublicKey, $false))

  $cert = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddYears(10))

  Set-Content -Path $certFile -Value (Wrap-Pem 'CERTIFICATE' $cert.RawData) -Encoding ascii
  Set-Content -Path $keyFile -Value (Get-PrivateKeyPem $rsa) -Encoding ascii
  Write-Ok "已生成 $certFile"
  Write-Ok "已生成 $keyFile"
}

$leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certFile)
Write-Ok "证书主题：$($leaf.Subject)"
Write-Ok "有效期至：$($leaf.NotAfter)"

if ($NoInstall) {
  Write-Host "  [--] 已跳过安装（-NoInstall）" -ForegroundColor Yellow
}
else {
  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  $exists = $false
  foreach ($c in $store.Certificates) {
    if ($c.Thumbprint -eq $leaf.Thumbprint) { $exists = $true; break }
  }
  if ($exists) {
    Write-Ok "根证书已在「当前用户\受信任的根证书颁发机构」中"
  }
  else {
    $store.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($leaf.RawData))
    Write-Ok "已安装到「当前用户\受信任的根证书颁发机构」"
  }
  $store.Close()
}

Write-Host ""
Write-Host "下一步：" -ForegroundColor Cyan
Write-Host "  1) 双击 wx-dl.cmd（或 powershell -File wx-dl.ps1）"
Write-Host "  2) 完全退出微信再打开一次"
Write-Host "  3) 进视频号播放视频，文件会自动保存到 我的文档\视频号"
Write-Host ""
