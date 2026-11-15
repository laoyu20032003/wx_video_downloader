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
using System.Windows.Media;
public class WxVideoRow {
  public string Id { get; set; }
  public string Title { get; set; }
  public string Duration { get; set; }
  public string SizeText { get; set; }
  public string Resolution { get; set; }
  public string StatusText { get; set; }
  public Brush StatusBrush { get; set; }
  public string ActionText { get; set; }
  public string File { get; set; }
  public string Url { get; set; }
  public ImageSource CoverImage { get; set; }
  public string Updated { get; set; }
  public bool Pending { get; set; }
  public DateTime PendingAt { get; set; }
}
'@
  Add-Type -ReferencedAssemblies @(
    [System.Windows.Media.ImageSource].Assembly.Location,
    [System.Windows.Media.Brush].Assembly.Location,
    [System.Windows.FrameworkElement].Assembly.Location
  ) -TypeDefinition $rowTypeSource
}

function Format-Size([long]$bytes) {
  if ($bytes -le 0) { return '—' }
  if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
  if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
  return ('{0:N0} KB' -f ($bytes / 1KB))
}

function Get-VideoInfo([string]$file) {
  try {
    $json = & ffprobe -v error -select_streams v:0 -show_entries stream=width,height `
      -show_entries format=size -of json $file 2>$null | Out-String
    $j = $json | ConvertFrom-Json
    $s = @($j.streams)[0]
    return [pscustomobject]@{ width = [int]$s.width; height = [int]$s.height; size = [long]$j.format.size }
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
  $bmp = New-Object System.Drawing.Bitmap(192, 108)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromArgb(45, 45, 48))
  $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14)
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 120, 120))
  $g.DrawString('视频号', $font, $brush, 55, 40)
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
$script:ListenerProc = $null
$script:ListenerOwned = $false
$script:ListenerState = 'idle'
$script:ProxyApplied = $false
$script:HudPidFile = Join-Path $Work 'hud.pid'
$script:ProxySnapshot = Join-Path $Work 'proxy_snapshot.json'
$script:GuiLog = Join-Path $Work 'gui.log'
$script:PendingFile = Join-Path $Work 'pending.json'
$script:PendingIds = @{}
$script:LibraryStamp = [DateTime]::MinValue

function Write-GuiLog([string]$msg) {
  try { Add-Content -LiteralPath $script:GuiLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding utf8 } catch { }
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

function New-Row($entry, [string]$fallbackTitle) {
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

  $status = if ($exists) { 'downloaded' } elseif ($entry.status) { [string]$entry.status } else { 'needs-replay' }
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
  $title = if ($entry.title) { [string]$entry.title } else { $fallbackTitle }

  $row = New-Object WxVideoRow
  $row.Id = [string]$entry.id
  $row.Title = $title
  $row.Duration = if ($entry.duration) { [string]$entry.duration } else { '—' }
  $row.SizeText = Format-Size $size
  $row.Resolution = if ($w -gt 0 -and $h -gt 0) { "${w}x${h}" } else { '—' }
  $row.StatusText = $statusText
  $row.StatusBrush = $brush
  $row.ActionText = if ($exists) { '打开' } else { '下载' }
  $row.File = if ($exists) { $file } else { '' }
  $row.Url = [string]$entry.url
  $row.CoverImage = $cover
  $row.Updated = [string]$entry.updated
  $row.Pending = $false
  if (-not $exists -and $script:PendingIds.ContainsKey($row.Id)) {
    $row.Pending = $true
    $row.PendingAt = $script:PendingIds[$row.Id]
    $row.StatusText = '待重播'
    $row.StatusBrush = $amber
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
        $row = New-Row $e '（无标题）'
        $rows.Add($row)
        $seenIds[[string]$e.id] = $true
        if ($row.File) { $seenFiles[$row.File.ToLower()] = $true }
      }
    } catch { }
  }

  if (Test-Path -LiteralPath $IndexFile) {
    try {
      $idx = Get-Content -LiteralPath $IndexFile -Raw | ConvertFrom-Json
      foreach ($e in @($idx.entries | Sort-Object time -Descending)) {
        if (-not $e.file -or -not (Test-Path -LiteralPath $e.file)) { continue }
        if ($seenFiles.ContainsKey($e.file.ToLower())) { continue }
        $fake = [pscustomobject]@{
          id = [string]$e.m; title = '（历史记录，无标题）'; duration = [string]$e.duration
          file = [string]$e.file; status = 'downloaded'; updated = [string]$e.time
          cover = ''; url = ''; size = 0; width = 0; height = 0
        }
        $rows.Add((New-Row $fake '（历史记录，无标题）'))
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
    $id = [string]$e.id
    if ($byId.ContainsKey($id)) {
      $row = $byId[$id]
      if ($row.Pending -or $row.StatusText -eq '下载中…') { continue }
      $fresh = New-Row $e '（无标题）'
      $row.Title = $fresh.Title
      $row.Duration = $fresh.Duration
      $row.SizeText = $fresh.SizeText
      $row.Resolution = $fresh.Resolution
      $row.Url = $fresh.Url
      $row.CoverImage = $fresh.CoverImage
      if ($fresh.File -or -not $row.File) {
        $row.File = $fresh.File
        $row.StatusText = $fresh.StatusText
        $row.StatusBrush = $fresh.StatusBrush
        $row.ActionText = $fresh.ActionText
      }
      $changed = $true
    } else {
      $row = New-Row $e '（无标题）'
      $rows.Insert(0, $row)
      $byId[$id] = $row
      $changed = $true
    }
  }
  if ($changed) { Update-Count }
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
    $e | Add-Member -NotePropertyName title -NotePropertyValue $row.Title -Force
    $e | Add-Member -NotePropertyName duration -NotePropertyValue $row.Duration -Force
    $e | Add-Member -NotePropertyName file -NotePropertyValue $row.File -Force
    $e | Add-Member -NotePropertyName status -NotePropertyValue 'downloaded' -Force
    $e | Add-Member -NotePropertyName updated -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $entries[$row.Id] = $e
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
      time = (Get-Date).ToString('o'); duration = $row.Duration; description = $row.Title
    }
    $dir = Split-Path -Parent $IndexFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [pscustomobject]@{ entries = $filtered } | ConvertTo-Json -Depth 6 |
      Set-Content -LiteralPath $IndexFile -Encoding utf8
  } catch { }
}

function Invoke-RowAction($row) {
  if ($row.File -and (Test-Path -LiteralPath $row.File)) {
    Start-Process explorer.exe -ArgumentList ('/select,"' + $row.File + '"')
    return
  }
  if (-not $row.Url) {
    Set-RowPending $row $true
    [System.Windows.MessageBox]::Show("这条还没有可用的下载地址，已加入待重播。`n`n请回到作者主页悬停这张卡片 2～3 秒；HUD 捕捉到新地址后，视频库会自动继续下载。", '视频号视频库') | Out-Null
    return
  }
  $tag = ($row.Id -replace '[^0-9A-Za-z_-]', '')
  if (-not $tag) { $tag = 'gui' }
  $out = Join-Path $Work ("gui_save_$tag.out")
  $err = Join-Path $Work ("gui_save_$tag.err")
  Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
  try {
    $proc = Start-Process -FilePath 'pwsh.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ToolScript,
      '-SaveUrl', $row.Url, '-SaveTag', $tag, '-OutDir', $OutDir
    ) -RedirectStandardOutput $out -RedirectStandardError $err
    Set-RowPending $row $false
    $row.StatusText = '下载中…'
    $row.StatusBrush = $blue
    $row.ActionText = '下载中'
    $script:Jobs[$proc.Id] = [pscustomobject]@{ Row = $row; Out = $out; Err = $err; Proc = $proc }
  } catch {
    [System.Windows.MessageBox]::Show("启动下载失败：$($_.Exception.Message)", '视频号视频库') | Out-Null
  }
}

# ---------------- WPF ----------------
$window = New-Object System.Windows.Window
$window.Title = '视频号视频库'
$window.Width = 1180
$window.Height = 760
$window.MinWidth = 900
$window.MinHeight = 480
$window.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 30, 30, 30))
$window.WindowStartupLocation = 'CenterScreen'

$root = New-Object System.Windows.Controls.Grid
$rd0 = New-Object System.Windows.Controls.RowDefinition; $rd0.Height = [System.Windows.GridLength]::Auto
$rd1 = New-Object System.Windows.Controls.RowDefinition; $rd1.Height = [System.Windows.GridLength]::Auto
$rd2 = New-Object System.Windows.Controls.RowDefinition
$rd2.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
[void]$root.RowDefinitions.Add($rd0)
[void]$root.RowDefinitions.Add($rd1)
[void]$root.RowDefinitions.Add($rd2)

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

$refreshBtn = New-Object System.Windows.Controls.Button
$refreshBtn.Content = '刷新'
$refreshBtn.Margin = New-Object System.Windows.Thickness(18, 0, 0, 0)
$refreshBtn.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
$refreshBtn.Add_Click({ Load-Rows; Update-Count })
$top.Children.Add($refreshBtn) | Out-Null

$openBtn = New-Object System.Windows.Controls.Button
$openBtn.Content = '打开输出目录'
$openBtn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
$openBtn.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
$openBtn.Add_Click({ if (Test-Path -LiteralPath $OutDir) { Start-Process explorer.exe $OutDir } })
$top.Children.Add($openBtn) | Out-Null

$ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
$headerXaml = @"
<Grid $ns Background="#252526" Height="34">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="118"/>
    <ColumnDefinition Width="470"/>
    <ColumnDefinition Width="70"/>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="110"/>
    <ColumnDefinition Width="90"/>
    <ColumnDefinition Width="100"/>
  </Grid.ColumnDefinitions>
  <TextBlock Grid.Column="0" Text="封面" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0"/>
  <TextBlock Grid.Column="1" Text="标题" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center" Margin="8,0,0,0"/>
  <TextBlock Grid.Column="2" Text="时长" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="3" Text="大小" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="4" Text="分辨率" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="5" Text="状态" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
  <TextBlock Grid.Column="6" Text="操作" Foreground="#C8C8C8" FontWeight="SemiBold" FontSize="12" VerticalAlignment="Center"/>
</Grid>
"@
$header = [System.Windows.Markup.XamlReader]::Parse($headerXaml)

$rowXaml = @"
<DataTemplate $ns>
  <Grid Height="66" Margin="0,1">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="118"/>
      <ColumnDefinition Width="470"/>
      <ColumnDefinition Width="70"/>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="110"/>
      <ColumnDefinition Width="90"/>
      <ColumnDefinition Width="100"/>
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Width="100" Height="58" Background="#37373A" CornerRadius="4" ClipToBounds="True" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="8,0,0,0">
      <Image Source="{Binding CoverImage}" Width="96" Height="54" Stretch="UniformToFill" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <TextBlock Grid.Column="1" Text="{Binding Title}" Foreground="#E8E8E8" VerticalAlignment="Center" Margin="8,0" TextTrimming="CharacterEllipsis" ToolTip="{Binding Title}"/>
    <TextBlock Grid.Column="2" Text="{Binding Duration}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="3" Text="{Binding SizeText}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="4" Text="{Binding Resolution}" Foreground="#D0D0D0" VerticalAlignment="Center"/>
    <TextBlock Grid.Column="5" Text="{Binding StatusText}" Foreground="{Binding StatusBrush}" VerticalAlignment="Center"/>
    <Button Grid.Column="6" Content="{Binding ActionText}" Tag="{Binding}" Padding="10,3" Margin="6,0" Background="#3A3A3D" Foreground="White" BorderBrush="#555555" Height="28" VerticalAlignment="Center" HorizontalAlignment="Left"/>
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
$window.Content = $root

function Update-Count {
  $done = @($rows | Where-Object { $_.StatusText -eq '已下载' }).Count
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
Load-Pending
Load-Rows
Start-Listener
Update-Count

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)

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
    Invoke-RowAction $row
  }
}

$timer.Add_Tick({
  Update-ListenerStatus
  Update-Count
  Sync-Library
  Check-Pending
  foreach ($id in @($script:Jobs.Keys)) {
    $job = $script:Jobs[$id]
    if (-not $job.Proc.HasExited) { continue }
    $text = if (Test-Path -LiteralPath $job.Out) { Get-Content -LiteralPath $job.Out -Raw } else { '' }
    if ($text -match 'SAVED=(.+)') {
      $saved = $matches[1].Trim().TrimEnd([char]13, [char]10)
      $job.Row.File = $saved
      $job.Row.StatusText = '已下载'
      $job.Row.StatusBrush = $green
      $job.Row.ActionText = '打开'
      $job.Row.SizeText = Format-Size ([long](Get-Item -LiteralPath $saved).Length)
      $info = Get-VideoInfo $saved
      if ($info -and $info.width -gt 0) { $job.Row.Resolution = "$($info.width)x$($info.height)" }
      Save-LibraryPatch $job.Row
      Save-IndexPatch $job.Row
      Set-RowPending $job.Row $false
      Update-Count
    } else {
      Set-RowPending $job.Row $true
      $job.Row.StatusText = '待重播'
      $job.Row.StatusBrush = $amber
      $job.Row.ActionText = '下载'
      [System.Windows.MessageBox]::Show("下载失败：签名地址可能已过期，或内存里没有明文头。`n`n已加入待重播。请在微信里重新播放这条视频（悬停卡片 2～3 秒），HUD 捕捉到新地址后视频库会自动继续下载。", '视频号视频库') | Out-Null
    }
    $script:Jobs.Remove($id)
  }
})
$timer.Start()

$window.Add_Closed({ $timer.Stop(); Stop-Listener })
$window.ShowDialog() | Out-Null
