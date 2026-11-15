param(
  [string]$LibraryFile = "",
  [string]$IndexFile = "",
  [string]$OutDir = "",
  [string]$ToolScript = "",
  [int]$Port = 8898,
  [switch]$NoStartListener
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $LibraryFile) { $LibraryFile = Join-Path $PSScriptRoot 'work\library.json' }
if (-not $IndexFile) { $IndexFile = Join-Path $PSScriptRoot 'work\hud_index.json' }
if (-not $OutDir) { $OutDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '视频号' }
if (-not $ToolScript) { $ToolScript = Join-Path $PSScriptRoot 'wx-dl.ps1' }
$Work = Join-Path $PSScriptRoot 'work'
$FlowsFile = Join-Path $PSScriptRoot 'flows.log'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  Write-Host "需要 STA：请用 wx-gui.vbs 启动，或 pwsh -Sta -File wx-gui.ps1" -ForegroundColor Yellow
  exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

if (-not ('WxVideoRow' -as [type])) {
  $rowTypeSource = @'
using System;
using System.ComponentModel;
using System.Windows.Media;
public class WxVideoRow : INotifyPropertyChanged {
  private string _id, _shortId, _fileName, _duration, _sizeText, _resolution, _statusText, _actionText, _file, _url, _updated, _source, _coverPath, _coverMethod;
  private Brush _statusBrush;
  private ImageSource _coverImage;
  private bool _pending, _canAct;
  private DateTime _pendingAt;

  public string Id { get { return _id; } set { if (_id != value) { _id = value; Raise("Id"); } } }
  public string ShortId { get { return _shortId; } set { if (_shortId != value) { _shortId = value; Raise("ShortId"); } } }
  public string FileName { get { return _fileName; } set { if (_fileName != value) { _fileName = value; Raise("FileName"); } } }
  public string Duration { get { return _duration; } set { if (_duration != value) { _duration = value; Raise("Duration"); } } }
  public string SizeText { get { return _sizeText; } set { if (_sizeText != value) { _sizeText = value; Raise("SizeText"); } } }
  public string Resolution { get { return _resolution; } set { if (_resolution != value) { _resolution = value; Raise("Resolution"); } } }
  public string StatusText { get { return _statusText; } set { if (_statusText != value) { _statusText = value; Raise("StatusText"); } } }
  public Brush StatusBrush { get { return _statusBrush; } set { if (_statusBrush != value) { _statusBrush = value; Raise("StatusBrush"); } } }
  public string ActionText { get { return _actionText; } set { if (_actionText != value) { _actionText = value; Raise("ActionText"); } } }
  public string File { get { return _file; } set { if (_file != value) { _file = value; Raise("File"); } } }
  public string Url { get { return _url; } set { if (_url != value) { _url = value; Raise("Url"); } } }
  public ImageSource CoverImage { get { return _coverImage; } set { if (_coverImage != value) { _coverImage = value; Raise("CoverImage"); } } }
  public string Updated { get { return _updated; } set { if (_updated != value) { _updated = value; Raise("Updated"); } } }
  public string Source { get { return _source; } set { if (_source != value) { _source = value; Raise("Source"); } } }
  public string CoverPath { get { return _coverPath; } set { if (_coverPath != value) { _coverPath = value; Raise("CoverPath"); } } }
  public string CoverMethod { get { return _coverMethod; } set { if (_coverMethod != value) { _coverMethod = value; Raise("CoverMethod"); } } }
  public bool Pending { get { return _pending; } set { if (_pending != value) { _pending = value; Raise("Pending"); } } }
  public DateTime PendingAt { get { return _pendingAt; } set { _pendingAt = value; Raise("PendingAt"); } }
  public bool CanAct { get { return _canAct; } set { if (_canAct != value) { _canAct = value; Raise("CanAct"); } } }

  public event PropertyChangedEventHandler PropertyChanged;
  private void Raise(string name) {
    var h = PropertyChanged;
    if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
  }
}
'@
  Add-Type -ReferencedAssemblies @(
    [System.ComponentModel.INotifyPropertyChanged].Assembly.Location,
    [System.Windows.Media.ImageSource].Assembly.Location,
    [System.Windows.Media.Brush].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location,
    [System.Windows.FrameworkElement].Assembly.Location
  ) -TypeDefinition $rowTypeSource -ErrorAction Stop
  if (-not ('WxVideoRow' -as [type])) { throw 'WxVideoRow type load failed' }
}

if (-not ('WxShellThumb' -as [type])) {
  try {
  $thumbRefs = @([System.Drawing.Bitmap].Assembly.Location)
  $gdiPlus = Join-Path (Split-Path ([System.Drawing.Image].Assembly.Location)) 'System.Private.Windows.GdiPlus.dll'
  if (Test-Path -LiteralPath $gdiPlus) { $thumbRefs += $gdiPlus }
  $winCore = Join-Path (Split-Path ([System.Drawing.Image].Assembly.Location)) 'System.Private.Windows.Core.dll'
  if (Test-Path -LiteralPath $winCore) { $thumbRefs += $winCore }
  Add-Type -ReferencedAssemblies $thumbRefs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class WxShellThumb {
  [StructLayout(LayoutKind.Sequential)]
  struct SIZE { public int cx; public int cy; }
  [Flags]
  enum SIIGBF : uint {
    RESIZETOFIT = 0, BIGGERSIZEOK = 1, MEMORYONLY = 2, ICONONLY = 4,
    THUMBNAILONLY = 8, INCACHEONLY = 16, CROPTOSQUARE = 32,
    WIDETHUMBNAILS = 64, ICONBACKGROUND = 128, SCALEUP = 256
  }
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItemImageFactory {
    [PreserveSig] int GetImage(SIZE size, SIIGBF flags, out IntPtr phbm);
  }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid,
    [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);
  [DllImport("gdi32.dll")]
  static extern bool DeleteObject(IntPtr hObject);

  public static bool Save(string file, string outPath, int cx, int cy) {
    IntPtr h = IntPtr.Zero;
    try {
      Guid iid = typeof(IShellItemImageFactory).GUID;
      IShellItemImageFactory f;
      SHCreateItemFromParsingName(file, IntPtr.Zero, ref iid, out f);
      int hr = f.GetImage(new SIZE { cx = cx, cy = cy }, SIIGBF.THUMBNAILONLY | SIIGBF.BIGGERSIZEOK, out h);
      if (hr < 0 || h == IntPtr.Zero) { return false; }
      using (var bmp = Image.FromHbitmap(h)) {
        bmp.Save(outPath, ImageFormat.Jpeg);
      }
      return true;
    } catch { return false; }
    finally { if (h != IntPtr.Zero) { DeleteObject(h); } }
  }
}
'@ -ErrorAction Stop
  } catch {
    try { Set-Content -LiteralPath (Join-Path $Work 'shellthumb.err') -Value $_.Exception.Message -Encoding utf8 } catch { }
  }
}

function Format-Size([long]$bytes) {
  if ($bytes -le 0) { return '—' }
  if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
  if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
  return ('{0:N0} KB' -f ($bytes / 1KB))
}

function Convert-DurationText([string]$s) {
  if (-not $s) { return 0 }
  $s = $s.Trim()
  if ($s -match '^(\d{1,2}):(\d{2})$') { return ([int]$matches[1] * 60 + [int]$matches[2]) }
  if ($s -match '^(\d{1,2}):(\d{2}):(\d{2})$') {
    return ([int]$matches[1] * 3600 + [int]$matches[2] * 60 + [int]$matches[3])
  }
  return 0
}

function Format-DurationSeconds([int]$sec) {
  if ($sec -le 0) { return '—' }
  if ($sec -ge 3600) { return ('{0}:{1:D2}:{2:D2}' -f [int]($sec / 3600), [int](($sec % 3600) / 60), ($sec % 60)) }
  return ('{0}:{1:D2}' -f [int]($sec / 60), ($sec % 60))
}

function Get-VideoCover([string]$file, [string]$id) {
  $script:LastCoverMethod = ''
  try {
    $dir = Join-Path $Work 'covers'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safe = ($id -replace '[^0-9A-Za-z_-]', '')
    $path = Join-Path $dir ($safe + '.jpg')

    # 1) 文件内嵌封面
    try {
      $probe = & ffprobe -v error -select_streams v -show_entries stream=index:stream_disposition=attached_pic -of json $file 2>$null | Out-String | ConvertFrom-Json
      $attached = @($probe.streams | Where-Object { $_.disposition.attached_pic -eq 1 } | Select-Object -First 1)
      if ($attached.Count -gt 0) {
        & ffmpeg -y -v error -i $file -map ("0:" + [string]$attached[0].index) -frames:v 1 -vf 'scale=320:-2' $path 2>$null
        if (Test-Path -LiteralPath $path) {
          $script:LastCoverMethod = 'embedded'
          Write-GuiLog "cover-embedded id=$id"
          return $path
        }
      }
    } catch { }

    # 2) 精确首帧（从 0 开始解码），微信/资源管理器通常就是这个
    & ffmpeg -y -v error -i $file -frames:v 1 -vf 'scale=320:-2' $path 2>$null
    if (Test-Path -LiteralPath $path) {
      $script:LastCoverMethod = 'frame0'
      Write-GuiLog "cover-frame0 id=$id"
      return $path
    }

    # 3) Windows Shell 缩略图兜底
    if ('WxShellThumb' -as [type]) {
      try {
        if ([WxShellThumb]::Save($file, $path, 320, 320) -and (Test-Path -LiteralPath $path)) {
          $script:LastCoverMethod = 'shell'
          Write-GuiLog "cover-shell id=$id"
          return $path
        }
      } catch { }
    }
  } catch { }
  return $null
}

function Get-VideoInfo([string]$file) {
  try {
    $json = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height `
      -show_entries format=size,duration -of json $file 2>$null | Out-String
    $j = $json | ConvertFrom-Json
    $s = @($j.streams)[0]
    return [pscustomobject]@{ width = [int]$s.width; height = [int]$s.height; size = [long]$j.format.size; duration = [double]$j.format.duration }
  } catch { return $null }
}

function Load-Bitmap([string]$path) {
  try {
    $src = $path -replace '\\', '/'
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'
    $bmp.UriSource = [Uri]::new($src)
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
  } catch { return $null }
}

# 占位封面
$coverDir = Join-Path $Work 'covers'
New-Item -ItemType Directory -Force -Path $coverDir | Out-Null
$placeholderPath = Join-Path $coverDir '_placeholder.png'
if (-not (Test-Path -LiteralPath $placeholderPath)) {
  $bmp = New-Object System.Drawing.Bitmap(180, 320)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromArgb(45, 45, 48))
  $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16)
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 120, 120))
  $g.DrawString('视频号', $font, $brush, 48, 145)
  $bmp.Save($placeholderPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
$script:Placeholder = Load-Bitmap $placeholderPath

$green = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 74, 222, 128))
$amber = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 251, 191, 36))
$red = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 248, 113, 113))
$blue = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 96, 165, 250))
$grey = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 160, 160, 160))
$white = [System.Windows.Media.Brushes]::White

$rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:Jobs = @{}
$script:AutoAttempted = @{}
$script:CoverQueue = New-Object System.Collections.Queue
$script:CoverQueued = @{}
$script:ListenerProc = $null
$script:ListenerOwned = $false
$script:ListenerState = 'idle'
$script:ProxyApplied = $false
$script:HudPidFile = Join-Path $Work 'hud.pid'
$script:ProxySnapshot = Join-Path $Work 'proxy_snapshot.json'
$script:GuiLog = Join-Path $Work 'gui.log'
$script:UiLogLines = New-Object System.Collections.Generic.List[string]
$script:PendingFile = Join-Path $Work 'pending.json'
$script:PendingIds = @{}
$script:LibraryStamp = [DateTime]::MinValue
$script:CacheEpochFile = Join-Path $Work 'cache_epoch.txt'
$script:CacheEpoch = [DateTime]::MinValue

function Write-GuiLog([string]$msg) {
  try { Add-Content -LiteralPath $script:GuiLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding utf8 } catch { }
  if (Get-Command Add-UiLog -ErrorAction SilentlyContinue) { Add-UiLog $msg }
}

function Load-CacheEpoch {
  $script:CacheEpoch = [DateTime]::MinValue
  if (-not (Test-Path -LiteralPath $script:CacheEpochFile)) { return }
  try {
    $s = (Get-Content -LiteralPath $script:CacheEpochFile -Raw).Trim()
    if ($s) { $script:CacheEpoch = [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
  } catch { }
}

function Set-CacheEpoch {
  $now = [DateTime]::UtcNow
  try { Set-Content -LiteralPath $script:CacheEpochFile -Value $now.ToString('o') -Encoding utf8 } catch { }
  $script:CacheEpoch = $now
}

function Test-AfterEpoch([string]$iso) {
  if ($script:CacheEpoch -le [DateTime]::MinValue) { return $true }
  if (-not $iso) { return $false }
  try {
    $t = [DateTime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
    return ($t -ge $script:CacheEpoch)
  } catch { return $false }
}

function Load-Pending {
  $script:PendingIds = @{}
  if (-not (Test-Path -LiteralPath $script:PendingFile)) { return }
  try {
    $j = Get-Content -LiteralPath $script:PendingFile -Raw | ConvertFrom-Json
    foreach ($e in @($j.entries)) {
      if (-not $e.id) { continue }
      $at = [DateTime]::MinValue
      if ($e.at) { try { $at = [DateTime]::Parse([string]$e.at, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
      $script:PendingIds[[string]$e.id] = $at
    }
  } catch { }
}

function Save-Pending {
  try {
    $entries = @()
    foreach ($r in $rows) {
      if ($r.Pending) {
        $entries += [pscustomobject]@{ id = $r.Id; at = $r.PendingAt.ToString('o') }
      }
    }
    $tmp = $script:PendingFile + '.tmp'
    [pscustomobject]@{ entries = $entries } | ConvertTo-Json -Depth 4 |
      Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:PendingFile -Force
  } catch { }
}

function Set-RowPending($row, [bool]$on) {
  $row.Pending = $on
  if ($on) {
    $row.PendingAt = Get-Date
    $script:PendingIds[$row.Id] = $row.PendingAt
    if (-not $row.File) {
      $row.StatusText = '待重播'
      $row.StatusBrush = $amber
      $row.ActionText = '下载'
    }
  } else {
    $script:PendingIds.Remove($row.Id)
  }
  Save-Pending
}

function Test-ListenerPort {
  [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Start-Listener {
  if ($NoStartListener) {
    $script:ListenerState = 'disabled'
    return
  }
  if (Test-ListenerPort) {
    $script:ListenerOwned = $false
    $script:ListenerState = 'external'
    Write-GuiLog "attach existing listener on $Port"
    return
  }
  try {
    $hostExe = (Get-Process -Id $PID).Path
    if (-not $hostExe) { $hostExe = 'pwsh' }
    $out = Join-Path $Work 'gui_listener.out'
    $err = Join-Path $Work 'gui_listener.err'
    Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    $script:ListenerProc = Start-Process -FilePath $hostExe -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolScript,
      '-NoAuto', '-Hud', '-OutDir', $OutDir, '-Port', "$Port"
    ) -RedirectStandardOutput $out -RedirectStandardError $err
    $script:ListenerOwned = $true
    $script:ListenerState = 'starting'
    Write-GuiLog "listener started pid=$($script:ListenerProc.Id)"
  } catch {
    $script:ListenerState = 'failed'
    Write-GuiLog ("listener start failed: " + $_.Exception.Message)
  }
}

function Stop-Listener {
  if (-not $script:ListenerOwned) { return }
  try {
    if ($script:ListenerProc -and -not $script:ListenerProc.HasExited) {
      Stop-Process -Id $script:ListenerProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $script:HudPidFile) {
      $hp = [int](Get-Content -LiteralPath $script:HudPidFile -Raw)
      if ($hp) { Stop-Process -Id $hp -Force -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $script:HudPidFile -ErrorAction SilentlyContinue
    }
    Write-GuiLog "listener stopped"
  } catch { }
}

function Set-ListenerProxy {
  try {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $reg -Name ProxyEnable -Value 1
    Set-ItemProperty $reg -Name ProxyServer -Value ("127.0.0.1:" + $Port)
    if (-not ('WinInetGuiX' -as [type])) {
      Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinInetGuiX {
  [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);
}
'@
    }
    [WinInetGuiX]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WinInetGuiX]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    $script:ProxyApplied = $true
    Write-GuiLog ("proxy set to 127.0.0.1:$Port")
  } catch {
    Write-GuiLog ("proxy set failed: " + $_.Exception.Message)
  }
}

function Update-ListenerStatus {
  if ($script:ListenerState -eq 'disabled') { return }
  if ($script:ListenerOwned -and $script:ListenerProc -and $script:ListenerProc.HasExited) {
    $script:ListenerState = 'failed'
    return
  }
  if (Test-ListenerPort) {
    $script:ListenerState = if ($script:ListenerOwned) { 'running' } else { 'external' }
    if ($script:ListenerOwned -and -not $script:ProxyApplied) { Set-ListenerProxy }
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = [string](Get-ItemProperty $reg -ErrorAction SilentlyContinue).ProxyServer
    if ($script:ListenerOwned -and $current -ne ("127.0.0.1:" + $Port)) {
      $script:ListenerState = 'proxy-mismatch'
    }
  } elseif ($script:ListenerOwned) {
    $script:ListenerState = 'starting'
  } else {
    $script:ListenerState = 'stopped'
  }
}

function New-Row($entry) {
  $file = [string]$entry.file
  $exists = $file -and (Test-Path -LiteralPath $file)
  $size = [long]0
  $w = 0; $h = 0
  if ($exists) {
    $fi = Get-Item -LiteralPath $file
    $size = [long]$fi.Length
    if ($entry.width -and $entry.height) {
      $w = [int]$entry.width; $h = [int]$entry.height
    } else {
      $info = Get-VideoInfo $file
      if ($info) { $w = $info.width; $h = $info.height; if ($info.size -gt 0) { $size = $info.size } }
    }
  } else {
    if ($entry.size) { $size = [long]$entry.size }
    if ($entry.width -and $entry.height) { $w = [int]$entry.width; $h = [int]$entry.height }
  }

  $status = if ($exists) { 'downloaded' } elseif ($entry.status -eq 'downloaded') { 'available' } elseif ($entry.status) { [string]$entry.status } else { 'needs-replay' }
  $statusText = switch ($status) {
    'downloaded' { '已下载' }
    'downloading' { '下载中…' }
    'available' { '可下载' }
    'played' { '已播放' }
    'needs-replay' { '需重播' }
    default { '需重播' }
  }
  $brush = switch ($status) {
    'downloaded' { $green }
    'downloading' { $blue }
    'available' { $amber }
    'played' { $grey }
    default { $red }
  }

  $cover = if ($entry.cover -and (Test-Path -LiteralPath $entry.cover)) { Load-Bitmap $entry.cover } else { $script:Placeholder }

  $row = New-Object WxVideoRow
  $row.Id = [string]$entry.id
  $row.ShortId = $row.Id.Substring(0, [Math]::Min(8, $row.Id.Length))
  $row.FileName = if ($exists) { Split-Path -Leaf $file } else { '—' }
  $row.Duration = if ($entry.duration) { [string]$entry.duration } else { '—' }
  $row.SizeText = Format-Size $size
  $row.Resolution = if ($w -gt 0 -and $h -gt 0) { "${w}x${h}" } else { '—' }
  $row.StatusText = $statusText
  $row.StatusBrush = $brush
  $row.ActionText = if ($exists) { '打开' } else { '下载' }
  $row.CanAct = $true
  $row.File = if ($exists) { $file } else { '' }
  $row.Url = [string]$entry.url
  $row.CoverImage = $cover
  $row.CoverPath = [string]$entry.cover
  $row.CoverMethod = [string]$entry.coverMethod
  $row.Source = [string]$entry.source
  $row.Updated = [string]$entry.updated
  $row.Pending = $false
  if (-not $exists -and $script:PendingIds.ContainsKey($row.Id)) {
    $row.Pending = $true
    $row.PendingAt = $script:PendingIds[$row.Id]
    $row.StatusText = '待重播'
    $row.StatusBrush = $amber
  }
  if ($row.Source -eq 'player' -and -not $exists) {
    $row.CanAct = $false
    $row.ActionText = '自动'
    if (-not $row.Pending -and $row.StatusText -eq '可下载') {
      $row.StatusText = '等待自动下载'
      $row.StatusBrush = $blue
    }
  }
  return $row
}

function Load-Rows {
  $rows.Clear()
  $seenFiles = @{}
  $seenIds = @{}

  if (Test-Path -LiteralPath $LibraryFile) {
    try {
      $lib = Get-Content -LiteralPath $LibraryFile -Raw | ConvertFrom-Json
      foreach ($e in @($lib.entries | Sort-Object -Property updated -Descending)) {
        if (-not $e.id) { continue }
        if (-not (Test-AfterEpoch ([string]$e.updated))) { continue }
        $row = New-Row $e
        $rows.Add($row)
        $seenIds[[string]$e.id] = $true
        if ($row.File) { $seenFiles[$row.File.ToLower()] = $true }
      }
    } catch {
      Write-GuiLog ("load-rows-error: " + $_.Exception.Message)
    }
  }

  if (Test-Path -LiteralPath $IndexFile) {
    try {
      $idx = Get-Content -LiteralPath $IndexFile -Raw | ConvertFrom-Json
      foreach ($e in @($idx.entries | Sort-Object time -Descending)) {
        if (-not $e.file -or -not (Test-Path -LiteralPath $e.file)) { continue }
        if (-not (Test-AfterEpoch ([string]$e.time))) { continue }
        if ($seenFiles.ContainsKey($e.file.ToLower())) { continue }
        $fake = [pscustomobject]@{
          id = [string]$e.m; duration = [string]$e.duration
          file = [string]$e.file; status = 'downloaded'; updated = [string]$e.time
          cover = ''; url = ''; size = 0; width = 0; height = 0
        }
        $rows.Add((New-Row $fake))
        $seenFiles[$e.file.ToLower()] = $true
      }
    } catch { }
  }
  try {
    $script:LibraryStamp = if (Test-Path -LiteralPath $LibraryFile) {
      (Get-Item -LiteralPath $LibraryFile).LastWriteTimeUtc
    } else { [DateTime]::MinValue }
  } catch { }
}

function Sync-Library {
  if (-not (Test-Path -LiteralPath $LibraryFile)) { return }
  try { $stamp = (Get-Item -LiteralPath $LibraryFile).LastWriteTimeUtc } catch { return }
  if ($stamp -eq $script:LibraryStamp) { return }
  $script:LibraryStamp = $stamp
  try { $lib = Get-Content -LiteralPath $LibraryFile -Raw | ConvertFrom-Json } catch { return }

  $byId = @{}
  foreach ($r in $rows) { if ($r.Id) { $byId[$r.Id] = $r } }
  $changed = $false
  foreach ($e in @($lib.entries)) {
    if (-not $e.id) { continue }
    if (-not (Test-AfterEpoch ([string]$e.updated))) { continue }
    $id = [string]$e.id
    if ($byId.ContainsKey($id)) {
      $row = $byId[$id]
      if ($row.Pending -or $row.StatusText -eq '下载中…') { continue }
      $fresh = New-Row $e
      $row.FileName = $fresh.FileName
      $row.Duration = $fresh.Duration
      $row.SizeText = $fresh.SizeText
      $row.Resolution = $fresh.Resolution
      $row.Url = $fresh.Url
      if ($fresh.CoverPath -and (Test-Path -LiteralPath $fresh.CoverPath)) {
        $row.CoverImage = $fresh.CoverImage
        $row.CoverPath = $fresh.CoverPath
      }
      $row.CoverMethod = $fresh.CoverMethod
      $row.Source = $fresh.Source
      if ($fresh.File -or -not $row.File) {
        $row.File = $fresh.File
        $row.StatusText = $fresh.StatusText
        $row.StatusBrush = $fresh.StatusBrush
        $row.ActionText = $fresh.ActionText
      }
      if ($row.Source -eq 'player' -and -not $row.File) {
        $row.CanAct = $false
        $row.ActionText = '自动'
        if ($row.StatusText -eq '可下载') { $row.StatusText = '等待自动下载'; $row.StatusBrush = $blue }
      } else {
        $row.CanAct = $true
      }
      $changed = $true
    } else {
      $row = New-Row $e
      $rows.Insert(0, $row)
      $byId[$id] = $row
      $changed = $true
      Queue-CoverRefresh $row
      Write-GuiLog ("library-new id=$id")
    }
  }
  if ($changed) { Update-Count }
}

function Queue-CoverRefresh($row) {
  if (-not $row -or -not $row.File) { return }
  if ($row.Source -ne 'player') { return }
  if ($row.CoverMethod -in @('embedded', 'frame0', 'shell')) { return }
  if ($script:CoverQueued.ContainsKey($row.Id)) { return }
  $script:CoverQueued[$row.Id] = $true
  $script:CoverQueue.Enqueue($row)
}

function Process-CoverQueue {
  if ($script:CoverQueue.Count -eq 0) { return }
  $row = $script:CoverQueue.Dequeue()
  if (-not $row -or -not $row.File -or -not (Test-Path -LiteralPath $row.File)) { return }
  if ($row.CoverMethod -in @('embedded', 'frame0', 'shell')) { return }
  $cover = Get-VideoCover $row.File $row.Id
  if ($cover) {
    $row.CoverPath = $cover
    $row.CoverMethod = [string]$script:LastCoverMethod
    $img = Load-Bitmap $cover
    if ($img) { $row.CoverImage = $img }
    Save-LibraryPatch $row
    Write-GuiLog ("cover-refresh id=$($row.Id) method=$($row.CoverMethod)")
  }
}

function Save-LibraryPatch($row) {
  # 把 GUI 下载结果合并回 library.json（尽量保留 HUD 写入的元数据）
  try {
    $dir = Split-Path -Parent $LibraryFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $entries = @{}
    if (Test-Path -LiteralPath $LibraryFile) {
      $j = Get-Content -LiteralPath $LibraryFile -Raw | ConvertFrom-Json
      foreach ($e in @($j.entries)) { if ($e.id) { $entries[[string]$e.id] = $e } }
    }
    $e = if ($entries.ContainsKey($row.Id)) { $entries[$row.Id] } else { [pscustomobject]@{} }
    $e | Add-Member -NotePropertyName id -NotePropertyValue $row.Id -Force
    if ($row.Duration -and $row.Duration -ne '—') {
      $e | Add-Member -NotePropertyName duration -NotePropertyValue $row.Duration -Force
    }
    $e | Add-Member -NotePropertyName file -NotePropertyValue $row.File -Force
    $e | Add-Member -NotePropertyName status -NotePropertyValue 'downloaded' -Force
    if ($row.CoverPath) { $e | Add-Member -NotePropertyName cover -NotePropertyValue $row.CoverPath -Force }
    if ($row.CoverMethod) { $e | Add-Member -NotePropertyName coverMethod -NotePropertyValue $row.CoverMethod -Force }
    if ($row.Source) { $e | Add-Member -NotePropertyName source -NotePropertyValue $row.Source -Force }
    $e | Add-Member -NotePropertyName updated -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $entries[$row.Id] = $e

    # 第二次读取磁盘，合并 HUD 在这期间新增/更新的其他条目
    if (Test-Path -LiteralPath $LibraryFile) {
      try {
        $latest = Get-Content -LiteralPath $LibraryFile -Raw | ConvertFrom-Json
        foreach ($le in @($latest.entries)) {
          if (-not $le.id -or [string]$le.id -eq $row.Id) { continue }
          $lid = [string]$le.id
          if (-not $entries.ContainsKey($lid)) { $entries[$lid] = $le; continue }
          $lu = [DateTime]::MinValue; $ou = [DateTime]::MinValue
          if ($le.updated) { try { $lu = [DateTime]::Parse([string]$le.updated, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
          if ($entries[$lid].updated) { try { $ou = [DateTime]::Parse([string]$entries[$lid].updated, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
          if ($lu -gt $ou) { $entries[$lid] = $le }
        }
      } catch { }
    }
    $tmp = $LibraryFile + '.tmp'
    [pscustomobject]@{ updated = (Get-Date).ToString('o'); entries = @($entries.Values) } |
      ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $LibraryFile -Force
  } catch { }
}

function Save-IndexPatch($row) {
  # 让 HUD 的“已下载”徽标也能看到 GUI 触发的下载
  try {
    $entries = @()
    if (Test-Path -LiteralPath $IndexFile) {
      $j = Get-Content -LiteralPath $IndexFile -Raw | ConvertFrom-Json
      $entries = @($j.entries)
    }
    $filtered = @($entries | Where-Object { $_.m -ne $row.Id })
    $filtered += [pscustomobject]@{
      key = 'gui|' + $row.Id; m = $row.Id; file = $row.File
      time = (Get-Date).ToString('o'); duration = $row.Duration
    }
    $dir = Split-Path -Parent $IndexFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [pscustomobject]@{ entries = $filtered } | ConvertTo-Json -Depth 6 |
      Set-Content -LiteralPath $IndexFile -Encoding utf8
  } catch { }
}

function Invoke-RowAction($row, [switch]$Auto) {
  if ($row.File -and (Test-Path -LiteralPath $row.File)) {
    Start-Process explorer.exe -ArgumentList ('/select,"' + $row.File + '"')
    return
  }
  if (-not $row.Url) {
    Set-RowPending $row $true
    if ($Auto) {
      $row.CanAct = $false
      $row.StatusText = '等待地址'
      $row.StatusBrush = $amber
      $row.ActionText = '自动'
    } else {
      $row.CanAct = $true
      [System.Windows.MessageBox]::Show("这条还没有可用的下载地址，已加入待重播。`n`n请回到作者主页悬停这张卡片 2～3 秒；HUD 捕捉到新地址后，视频库会自动继续下载。", '视频号视频库') | Out-Null
    }
    return
  }
  $tag = ($row.Id -replace '[^0-9A-Za-z_-]', '')
  if (-not $tag) { $tag = 'gui' }
  $out = Join-Path $Work ("gui_save_$tag.out")
  $err = Join-Path $Work ("gui_save_$tag.err")
  Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
  $row.StatusText = '匹配中…'
  $row.StatusBrush = $blue
  $row.ActionText = '…'
  $row.CanAct = $false
  Write-GuiLog ("download-start id=$($row.Id) auto=$([bool]$Auto)")
  $expectedSec = Convert-DurationText $row.Duration
  $dlArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolScript,
    '-SaveUrl', $row.Url, '-SaveTag', $tag, '-OutDir', $OutDir
  )
  if ($expectedSec -gt 0) { $dlArgs += @('-ExpectedDuration', [string]$expectedSec) }
  try {
    $proc = Start-Process -FilePath 'pwsh.exe' -WindowStyle Hidden -PassThru -ArgumentList $dlArgs -RedirectStandardOutput $out -RedirectStandardError $err
    Set-RowPending $row $false
    $script:Jobs[$proc.Id] = [pscustomobject]@{ Row = $row; Out = $out; Err = $err; Proc = $proc; Phase = '匹配中…'; Auto = [bool]$Auto }
  } catch {
    $row.CanAct = if ($Auto) { $false } else { $true }
    $row.StatusText = '下载失败'
    $row.StatusBrush = $red
    $row.ActionText = if ($Auto) { '自动' } else { '重试' }
    if (-not $Auto) {
      [System.Windows.MessageBox]::Show("启动下载失败：$($_.Exception.Message)", '视频号视频库') | Out-Null
    }
  }
}

# ---------------- WPF ----------------
$window = New-Object System.Windows.Window
$window.Title = '视频号视频库'
$window.Width = 1180
$window.Height = 820
$window.MinWidth = 900
$window.MinHeight = 480
$window.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 30, 30, 30))
$window.WindowStartupLocation = 'CenterScreen'

$root = New-Object System.Windows.Controls.Grid
$rd0 = New-Object System.Windows.Controls.RowDefinition; $rd0.Height = [System.Windows.GridLength]::Auto
$rd1 = New-Object System.Windows.Controls.RowDefinition; $rd1.Height = [System.Windows.GridLength]::Auto
$rd2 = New-Object System.Windows.Controls.RowDefinition
$rd2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
$rd3 = New-Object System.Windows.Controls.RowDefinition; $rd3.Height = [System.Windows.GridLength]::Auto
[void]$root.RowDefinitions.Add($rd0)
[void]$root.RowDefinitions.Add($rd1)
[void]$root.RowDefinitions.Add($rd2)
[void]$root.RowDefinitions.Add($rd3)

$top = New-Object System.Windows.Controls.StackPanel
$top.Orientation = 'Horizontal'
$top.Margin = New-Object System.Windows.Thickness(16, 12, 16, 8)

$titleBlock = New-Object System.Windows.Controls.TextBlock
$titleBlock.Text = '视频号视频库'
$titleBlock.FontSize = 18
$titleBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
$titleBlock.Foreground = $white
$titleBlock.VerticalAlignment = 'Center'
$titleBlock.Margin = New-Object System.Windows.Thickness(0, 0, 18, 0)
$top.Children.Add($titleBlock) | Out-Null

$countBlock = New-Object System.Windows.Controls.TextBlock
$countBlock.Foreground = $grey
$countBlock.VerticalAlignment = 'Center'
$countBlock.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
$top.Children.Add($countBlock) | Out-Null

$listenBlock = New-Object System.Windows.Controls.TextBlock
$listenBlock.Foreground = $grey
$listenBlock.VerticalAlignment = 'Center'
$listenBlock.Margin = New-Object System.Windows.Thickness(18, 3, 0, 0)
$top.Children.Add($listenBlock) | Out-Null

$openBtn = New-Object System.Windows.Controls.Button
$openBtn.Content = '打开输出目录'
$openBtn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
$openBtn.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
$openBtn.Add_Click({ if (Test-Path -LiteralPath $OutDir) { Start-Process explorer.exe $OutDir } })
$top.Children.Add($openBtn) | Out-Null

$clearBtn = New-Object System.Windows.Controls.Button
$clearBtn.Content = '清除缓存'
$clearBtn.ToolTip = '清空列表/封面/索引/待重播，不删除输出目录里的视频'
$clearBtn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
$clearBtn.Padding = New-Object System.Windows.Thickness(10, 4, 10, 4)
$clearBtn.Add_Click({ Clear-Cache })
$top.Children.Add($clearBtn) | Out-Null


$ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$headerXaml = @"
<Grid $ns Background="#252526" Height="34">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="408"/>
    <ColumnDefinition Width="70"/>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="110"/>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="100"/>
  </Grid.ColumnDefinitions>
  <TextBlock Grid.Column="0" Text="封面" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0"/>
  <TextBlock Grid.Column="1" Text="ID" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="2" Text="文件名" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0"/>
  <TextBlock Grid.Column="3" Text="时长" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="4" Text="大小" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="5" Text="分辨率" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="6" Text="状态" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="7" Text="操作" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
</Grid>
"@
$header = [System.Windows.Markup.XamlReader]::Parse($headerXaml)

$rowXaml = @"
<DataTemplate $ns>
  <Grid Height="124" Margin="0,1">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="408"/>
      <ColumnDefinition Width="70"/>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="110"/>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="100"/>
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Width="68" Height="118" Background="#37373A" CornerRadius="4" ClipToBounds="True" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="8,0,0,0">
      <Image Source="{Binding CoverImage}" Width="64" Height="114" Stretch="UniformToFill" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <TextBlock Grid.Column="1" Text="{Binding ShortId}" Foreground="#8A8A8A" FontFamily="Consolas" FontSize="11" VerticalAlignment="Center" ToolTip="{Binding Id}"/>
    <TextBlock Grid.Column="2" Text="{Binding FileName}" Foreground="#E8E8E8" VerticalAlignment="Center" Margin="8,0" TextTrimming="CharacterEllipsis" ToolTip="{Binding FileName}"/>
    <TextBlock Grid.Column="3" Text="{Binding Duration}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="4" Text="{Binding SizeText}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="5" Text="{Binding Resolution}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="6" Text="{Binding StatusText}" Foreground="{Binding StatusBrush}" VerticalAlignment="Center"/>
    <Button Grid.Column="7" Content="{Binding ActionText}" Tag="{Binding}" Padding="10,3" Margin="6,0" Background="#3A3A3D" Foreground="White" BorderBrush="#555555" Height="28" VerticalAlignment="Center" HorizontalAlignment="Left" IsEnabled="{Binding CanAct}">
      <Button.Style>
        <Style TargetType="Button">
          <Setter Property="Visibility" Value="Visible"/>
          <Style.Triggers>
            <DataTrigger Binding="{Binding CanAct}" Value="False">
              <Setter Property="Visibility" Value="Collapsed"/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </Button.Style>
    </Button>
  </Grid>
</DataTemplate>
"@
$rowTemplate = [System.Windows.Markup.XamlReader]::Parse($rowXaml)

$list = New-Object System.Windows.Controls.ListBox
$list.Margin = New-Object System.Windows.Thickness(12, 0, 12, 12)
$list.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 37, 37, 38))
$list.Foreground = $white
$list.BorderThickness = New-Object System.Windows.Thickness(0)
$list.ItemTemplate = $rowTemplate
$list.ItemsSource = $rows
$list.HorizontalContentAlignment = 'Stretch'
[System.Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Disabled)
[System.Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Auto)

$itemStyle = New-Object System.Windows.Style([System.Windows.Controls.ListBoxItem])
$itemStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BackgroundProperty, [System.Windows.Media.Brushes]::Transparent))) | Out-Null
$itemStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::ForegroundProperty, $white))) | Out-Null
$itemStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::PaddingProperty, (New-Object System.Windows.Thickness(0))))) | Out-Null
$itemStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::HorizontalContentAlignmentProperty, [System.Windows.HorizontalAlignment]::Stretch))) | Out-Null
$itemStyle.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.Control]::BorderThicknessProperty, (New-Object System.Windows.Thickness(0))))) | Out-Null
$list.ItemContainerStyle = $itemStyle

$list.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
  param($s, $e)
  $src = $e.OriginalSource
  if ($src -and $src.DataContext) { Invoke-RowAction $src.DataContext }
})

[System.Windows.Controls.Grid]::SetRow($top, 0)
[void]$root.Children.Add($top)
[System.Windows.Controls.Grid]::SetRow($header, 1)
[void]$root.Children.Add($header)
[System.Windows.Controls.Grid]::SetRow($list, 2)
[void]$root.Children.Add($list)

$detailsBox = New-Object System.Windows.Controls.TextBox
$detailsBox.IsReadOnly = $true
$detailsBox.AcceptsReturn = $true
$detailsBox.TextWrapping = 'NoWrap'
$detailsBox.FontFamily = 'Consolas'
$detailsBox.FontSize = 12
$detailsBox.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 24, 24, 26))
$detailsBox.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 210, 210, 210))
$detailsBox.BorderThickness = New-Object System.Windows.Thickness(0)
$detailsBox.Padding = New-Object System.Windows.Thickness(8)
$detailsBox.VerticalScrollBarVisibility = 'Auto'
$detailsBox.HorizontalScrollBarVisibility = 'Auto'

$logBox = New-Object System.Windows.Controls.TextBox
$logBox.IsReadOnly = $true
$logBox.AcceptsReturn = $true
$logBox.TextWrapping = 'NoWrap'
$logBox.FontFamily = 'Consolas'
$logBox.FontSize = 11
$logBox.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 24, 24, 26))
$logBox.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 180, 200, 180))
$logBox.BorderThickness = New-Object System.Windows.Thickness(0)
$logBox.Padding = New-Object System.Windows.Thickness(8)
$logBox.VerticalScrollBarVisibility = 'Auto'
$logBox.HorizontalScrollBarVisibility = 'Auto'

$tabs = New-Object System.Windows.Controls.TabControl
$tabs.Height = 158
$tabs.Margin = New-Object System.Windows.Thickness(12, 0, 12, 8)
$tabs.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 37, 37, 38))
$tabs.Foreground = $white
$tabDetails = New-Object System.Windows.Controls.TabItem
$tabDetails.Header = '详情 / 可复制'
$tabDetails.Content = $detailsBox
$tabLog = New-Object System.Windows.Controls.TabItem
$tabLog.Header = '日志'
$tabLog.Content = $logBox
[void]$tabs.Items.Add($tabDetails)
[void]$tabs.Items.Add($tabLog)
[System.Windows.Controls.Grid]::SetRow($tabs, 3)
[void]$root.Children.Add($tabs)

function Add-UiLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  [void]$script:UiLogLines.Add($line)
  while ($script:UiLogLines.Count -gt 500) { $script:UiLogLines.RemoveAt(0) }
  if ($logBox) {
    $logBox.Text = ($script:UiLogLines -join "`r`n")
    $logBox.ScrollToEnd()
  }
}

function Show-RowDetails($row) {
  if (-not $row) { $detailsBox.Text = ''; return }
  $detailsBox.Text = @(
    "ID:          $($row.Id)"
    "文件名:      $($row.FileName)"
    "时长:        $($row.Duration)"
    "大小:        $($row.SizeText)"
    "分辨率:      $($row.Resolution)"
    "状态:        $($row.StatusText)"
    "来源:        $($row.Source)"
    "待重播:      $($row.Pending)"
    "文件:        $(if ($row.File) { $row.File } else { '—' })"
    "URL:         $(if ($row.Url) { $row.Url } else { '—' })"
    "封面文件:    $(if ($row.CoverPath) { $row.CoverPath } else { '—' })"
    "更新时间:    $($row.Updated)"
  ) -join "`r`n"
}

function Clear-Cache {
  $busy = $script:Jobs.Count -gt 0
  $msg = "清空列表、封面、明文头缓存、下载索引和待重播记录？`n`n不会删除输出目录里的视频。"
  if ($busy) { $msg += "`n`n当前有下载/校验任务，清除会先强制停止它们。" }
  $answer = [System.Windows.MessageBox]::Show($msg, '清除缓存', 'YesNo', 'Warning')
  if ($answer -ne 'Yes') { return }

  # 用户确认后停止所有下载任务，并清空任务表
  foreach ($job in @($script:Jobs.Values)) {
    try { Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
  $script:Jobs = @{}

  # 先通知 HUD 清空它内存里的 Library/Index，再删文件
  $flag = Join-Path $Work 'clear.flag'
  try { Set-Content -LiteralPath $flag -Value (Get-Date).ToString('o') -Encoding utf8 } catch { }
  $deadline = (Get-Date).AddSeconds(3)
  while ((Test-Path -LiteralPath $flag) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
  }
  Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue

  Set-CacheEpoch
  $rows.Clear()
  $script:PendingIds = @{}
  $script:AutoAttempted = @{}
  $script:LibraryStamp = [DateTime]::MinValue
  $script:UiLogLines.Clear()
  $detailsBox.Text = ''
  $logBox.Text = ''

  $files = @(
    $LibraryFile,
    $script:PendingFile,
    (Join-Path $Work 'player.json'),
    (Join-Path $Work 'player_history.jsonl'),
    $IndexFile,
    (Join-Path $Work 'gui.log'),
    (Join-Path $Work 'hud.log'),
    (Join-Path $Work 'run.log'),
    (Join-Path $Work 'hdr_dump.tmp'),
    (Join-Path $Work 'err.txt')
  )
  foreach ($f in $files) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  try { [System.IO.File]::WriteAllText($FlowsFile, '') } catch { }
  Get-ChildItem -LiteralPath (Join-Path $Work 'covers') -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath (Join-Path $Work 'headers') -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($pat in 'cipher_*', 'cand_*', 'prefix_*', 'gui_save_*', '*.tmp') {
    Get-ChildItem -LiteralPath $Work -Filter $pat -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }

  Update-Count
  Write-GuiLog 'cache-cleared (output videos preserved)'
}

$list.Add_SelectionChanged({
  Show-RowDetails $list.SelectedItem
})

$window.Content = $root

function Update-Count {
  $done = @($rows | Where-Object { $_.StatusText -in @('已下载', '下载完成') }).Count
  $countBlock.Text = "共 $($rows.Count) 条 · 已下载 $done"
  switch ($script:ListenerState) {
    'starting' { $listenBlock.Text = '监听：启动中…'; $listenBlock.Foreground = $amber }
    'running' { $listenBlock.Text = '监听：运行中'; $listenBlock.Foreground = $green }
    'external' { $listenBlock.Text = '监听：复用已有'; $listenBlock.Foreground = $green }
    'proxy-mismatch' { $listenBlock.Text = '监听：代理被改回'; $listenBlock.Foreground = $amber }
    'failed' { $listenBlock.Text = '监听：启动失败'; $listenBlock.Foreground = $red }
    'stopped' { $listenBlock.Text = '监听：未启动'; $listenBlock.Foreground = $red }
    'disabled' { $listenBlock.Text = '监听：已禁用'; $listenBlock.Foreground = $grey }
    default { $listenBlock.Text = '监听：…'; $listenBlock.Foreground = $grey }
  }
}
Load-CacheEpoch
Load-Pending
Load-Rows
foreach ($r in @($rows)) { Queue-CoverRefresh $r }
Write-GuiLog "gui-start library=$LibraryFile"
if ('WxShellThumb' -as [type]) { Write-GuiLog 'shell-thumb-ready' } else { Write-GuiLog 'shell-thumb-unavailable' }
Start-Listener
Update-Count

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)

function Start-AutoDownload {
  if ($script:Jobs.Count -gt 0) { return }
  $r = @($rows | Where-Object {
      $_.Source -eq 'player' -and -not $_.File -and $_.Url -and -not $_.Pending -and
      -not $script:AutoAttempted.ContainsKey($_.Id) -and
      $_.StatusText -notin @('匹配中…', '下载中…', '校验中…', '下载完成', '已下载', '下载失败', '打开')
    } | Select-Object -First 1)
  if ($r.Count -gt 0) {
    $script:AutoAttempted[$r[0].Id] = $true
    Invoke-RowAction $r[0] -Auto
  }
}

function Check-Pending {
  $pendingRows = @($rows | Where-Object { $_.Pending })
  if ($pendingRows.Count -eq 0) { return }
  if (-not (Test-Path -LiteralPath $LibraryFile)) { return }
  try {
    $lib = Get-Content -LiteralPath $LibraryFile -Raw | ConvertFrom-Json
  } catch { return }
  $map = @{}
  foreach ($e in @($lib.entries)) { if ($e.id) { $map[[string]$e.id] = $e } }

  foreach ($row in $pendingRows) {
    if ($script:Jobs.Count -gt 0) { break }
    if (-not $map.ContainsKey($row.Id)) { continue }
    $e = $map[$row.Id]
    if ($e.file -and (Test-Path -LiteralPath $e.file)) {
      $row.File = [string]$e.file
      $row.StatusText = '已下载'
      $row.StatusBrush = $green
      $row.ActionText = '打开'
      Set-RowPending $row $false
      continue
    }
    if (-not $e.url) { continue }
    $updated = [DateTime]::MinValue
    if ($e.updated) {
      try { $updated = [DateTime]::Parse([string]$e.updated, [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    if ($updated -le $row.PendingAt) { continue }
    $row.Url = [string]$e.url
    $row.StatusText = '下载中…'
    $row.StatusBrush = $blue
    $row.ActionText = '下载中'
    Set-RowPending $row $false
    Invoke-RowAction $row -Auto:($row.Source -eq 'player')
  }
}

$timer.Add_Tick({
  Update-ListenerStatus
  Update-Count
  Sync-Library
  Process-CoverQueue
  Start-AutoDownload
  Check-Pending
  foreach ($id in @($script:Jobs.Keys)) {
    $job = $script:Jobs[$id]
    $text = if (Test-Path -LiteralPath $job.Out) { Get-Content -LiteralPath $job.Out -Tail 40 -ErrorAction SilentlyContinue | Out-String } else { '' }

    if (-not $job.Proc.HasExited) {
      $phase = '匹配中…'
      if ($text -match '全片校验|命中') { $phase = '校验中…' }
      elseif ($text -match '下载密文') { $phase = '下载中…' }
      elseif ($text -match '尝试缓存|扫描内存') { $phase = '匹配中…' }
      $job.Row.CanAct = $false
      if ($job.Row.StatusText -ne $phase) {
        $job.Row.StatusText = $phase
        $job.Row.StatusBrush = $blue
        $job.Row.ActionText = '…'
        $job.Phase = $phase
        Write-GuiLog "download-phase id=$($job.Row.Id) $phase"
      }
      continue
    }

    $job.Row.CanAct = $true
    if ($text -match 'SAVED=(.+)') {
      $saved = $matches[1].Trim().TrimEnd([char]13, [char]10)
      $info = Get-VideoInfo $saved
      $expected = Convert-DurationText $job.Row.Duration
      $actual = if ($info) { [int][Math]::Round($info.duration) } else { 0 }
      if ($expected -gt 0 -and $actual -gt 0 -and [Math]::Abs($expected - $actual) -gt 2) {
        Write-GuiLog ("download-duration-warning id=$($job.Row.Id) expected=${expected}s actual=${actual}s file=$saved")
      }
      if ($actual -gt 0) { $job.Row.Duration = Format-DurationSeconds $actual }
      $job.Row.File = $saved
      $job.Row.FileName = Split-Path -Leaf $saved
      $job.Row.StatusText = '下载完成'
      $job.Row.StatusBrush = $green
      $job.Row.ActionText = '打开'
      $job.Row.SizeText = Format-Size ([long](Get-Item -LiteralPath $saved).Length)
      if ($info -and $info.width -gt 0) { $job.Row.Resolution = "$($info.width)x$($info.height)" }
      $cover = if (-not $job.Row.CoverPath -or $job.Row.Source -eq 'player') {
        Get-VideoCover $saved $job.Row.Id
      } else { $null }
      if ($cover) {
        $job.Row.CoverPath = $cover
        $job.Row.CoverMethod = [string]$script:LastCoverMethod
        $img = Load-Bitmap $cover
        if ($img) { $job.Row.CoverImage = $img }
      }
      Save-LibraryPatch $job.Row
      Save-IndexPatch $job.Row
      Set-RowPending $job.Row $false
      Write-GuiLog ("download-done id=$($job.Row.Id) file=$saved")
      Update-Count
    } else {
      Set-RowPending $job.Row $true
      $job.Row.StatusText = if ($job.Auto) { '等待重播' } else { '待重播' }
      $job.Row.StatusBrush = $amber
      if ($job.Auto) {
        $job.Row.CanAct = $false
        $job.Row.ActionText = '自动'
      } else {
        $job.Row.CanAct = $true
        $job.Row.ActionText = '下载'
      }
      $lastLine = @($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
      $reason = if ($lastLine.Count -gt 0) { ([string]$lastLine[0]).Trim() } else { '' }
      if (-not $reason) {
        try { $reason = (Get-Content -LiteralPath $job.Err -Tail 1 -ErrorAction SilentlyContinue | Out-String).Trim() } catch { }
      }
      if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) }
      Write-GuiLog ("download-fail id=$($job.Row.Id) auto=$($job.Auto) reason=$reason")
      if (-not $job.Auto) {
        [System.Windows.MessageBox]::Show("下载失败：签名地址可能已过期，或内存里没有明文头。`n`n已加入待重播。请在微信里重新播放这条视频（悬停卡片 2～3 秒），HUD 捕捉到新地址后视频库会自动继续下载。", '视频号视频库') | Out-Null
      }
    }
    $script:Jobs.Remove($id)
  }
})
$timer.Start()

$window.Add_Closed({ $timer.Stop(); Stop-Listener })
$window.ShowDialog() | Out-Null
