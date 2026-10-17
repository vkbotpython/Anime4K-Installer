<#
.SYNOPSIS
  mpv.net + Anime4K — современный однофайловый установщик (WPF, чистый PowerShell).
.DESCRIPTION
  - Ставит mpv.net СИСТЕМНО через setup (mpv.net-vX-setup-x64.exe, Inno Setup, /ALLUSERS).
    Проверяет установлен ли уже (реестр uninstall + %ProgramFiles%\mpv.net\mpvnet.exe),
    версию latest берет из GitHub API, fallback — v7.1.2.0.
  - Ставит зависимость .NET WindowsDesktop Runtime 10.0.13 x64 (тихо, /quiet).
  - Создает %APPDATA%\mpv.net и распаковывает туда пресет Anime4K v4.0.1
    (Low-end / High-end). Приоритет/порядок шейдеров НЕ правится вручную —
    берется как есть из mpv.conf внутри архива. Перезапись молча (-Force).
  - UI: WPF dark + Mica через DWM (Windows 11; тёмный заголовок, полупрозрачные
    поверхности; при недоступности backdrop — сплошной тёмный фон), два языка
    (RU/EN, кнопка в шапке), Quick Usage в главном окне,
    кнопка подробной инструкции открывает стилизованный гайд на текущем языке.
.PARAMETER Silent
  Тихая установка без UI: -Silent -Preset Low|High
.PARAMETER Preset
  Пресет для Silent-режима. По умолчанию High.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -STA -File .\Install-Anime4K.ps1
  powershell -ExecutionPolicy Bypass -STA -File .\Install-Anime4K.ps1 -Silent -Preset Low
#>
param(
  [switch]$Silent,
  [ValidateSet('Low','High')][string]$Preset = 'High'
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- Config ---
$Script:Cfg = @{
  MpvPinnedVersion = 'v7.1.2.0'
  MpvPinnedUrl     = 'https://github.com/mpvnet-player/mpv.net/releases/download/v7.1.2.0/mpv.net-v7.1.2.0-setup-x64.exe'
  MpvApiLatest     = 'https://api.github.com/repos/mpvnet-player/mpv.net/releases/latest'
  DotnetUrl        = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.13/windowsdesktop-runtime-10.0.13-win-x64.exe'
  DotnetVersion    = '10.0.13'
  DotnetRegPath    = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App'
  AnimeTag         = 'v4.0.1'
  AnimeLowUrl      = 'https://github.com/Tama47/Anime4K/releases/download/v4.0.1/GLSL_Windows_Low-end.zip'
  AnimeHighUrl     = 'https://github.com/Tama47/Anime4K/releases/download/v4.0.1/GLSL_Windows_High-end.zip'
  # «О программе»: соцсети автора и донат — как в README проекта
  SocialYouTube    = 'https://www.youtube.com/@avencores/'
  SocialTelegram   = 'https://t.me/avencoresyt'
  SocialVk         = 'https://vk.ru/avencoresreuploads'
  SocialDzen       = 'https://dzen.ru/avencores'
  DonateSber       = '2202 2050 1464 4675'
  ConfigDir        = (Join-Path $env:APPDATA 'mpv.net')
  LogFile          = (Join-Path $env:TEMP 'Anime4K-Install.log')
}
$Script:Lang = 'RU'
# UI-хендлы объявляем заранее: в -Silent их нет, а StrictMode бросает на необъявленных переменных
$Script:TxtLog = $null
$Script:LogBrushes = @{}
$Script:Bar = $null
$Script:LblStatus = $null
$Script:LblPreset = $null
$Script:DotPreset = $null
$Script:GuideWindow = $null
$Script:AboutWindow = $null

# Кисти строк лога кэшируем: цвета берём из палитры окна, при отсутствии — фолбэк
function Get-LogBrush {
  param([string]$Key, [string]$Fallback)
  if ($Script:LogBrushes[$Key]) { return $Script:LogBrushes[$Key] }
  $b = $null
  try { $b = $Script:Window.FindResource($Key) } catch {}
  if ($b -isnot [Windows.Media.Brush]) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Fallback))
  }
  $Script:LogBrushes[$Key] = $b
  return $b
}

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $ts = Get-Date -Format 'HH:mm:ss'
  $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
  try { Add-Content -Path $Script:Cfg.LogFile -Value $line -Encoding UTF8 } catch {}
  if ($Script:TxtLog) {
    try {
      $Script:TxtLog.Dispatcher.Invoke([action]{
        # Цветные фрагменты вместо плоской строки: время — тусклое, уровень — по важности
        $tsBrush  = Get-LogBrush 'B_LogTs'   '#7C8494'
        $msgBrush = Get-LogBrush 'B_LogText' '#D6D6D6'
        switch ($Level) {
          'OK'    { $lvlBrush = Get-LogBrush 'B_Success'  '#6CCB5F' }
          'WARN'  { $lvlBrush = Get-LogBrush 'B_LogWarn'  '#FCE100' }
          'ERROR' { $lvlBrush = Get-LogBrush 'B_LogError' '#FF99A4' }
          default { $lvlBrush = Get-LogBrush 'B_LogInfo'  '#60CDFF' }
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object Windows.Thickness 0
        $p.LineHeight = 18
        $rTs = New-Object System.Windows.Documents.Run -ArgumentList ('[{0}] ' -f $ts)
        $rTs.Foreground = $tsBrush
        $rLv = New-Object System.Windows.Documents.Run -ArgumentList ('[{0}] ' -f $Level)
        $rLv.Foreground = $lvlBrush
        $rLv.FontWeight = [Windows.FontWeights]::SemiBold
        $rMsg = New-Object System.Windows.Documents.Run -ArgumentList ([string]$Message)
        $rMsg.Foreground = $msgBrush
        $p.Inlines.Add($rTs)
        $p.Inlines.Add($rLv)
        $p.Inlines.Add($rMsg)
        $Script:TxtLog.Document.Blocks.Add($p)
        $Script:TxtLog.ScrollToEnd()
      })
    } catch {}
  }
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------- Detection: mpv.net ---
function Get-MpvNetStatus {
  # Возвращает @{ Installed=$bool; Version=$str; Exe=$path }
  $res = @{ Installed = $false; Version = ''; Exe = '' }
  $cands = @(
    (Join-Path $env:ProgramFiles 'mpv.net\mpvnet.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'mpv.net\mpvnet.exe'),
    (Join-Path $env:LocalAppData 'mpv.net\mpvnet.exe')
  )
  foreach ($p in $cands) {
    if ($p -and (Test-Path $p)) { $res.Exe = $p; $res.Installed = $true; break }
  }
  $cmd = Get-Command mpvnet.exe -ErrorAction SilentlyContinue
  if (-not $res.Installed -and $cmd) { $res.Exe = $cmd.Source; $res.Installed = $true }
  # Реестр uninstall (системная установка через Inno Setup, ALLUSERS)
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    try {
      $apps = Get-ItemProperty $k -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'mpv.net*' }
      foreach ($a in $apps) {
        $res.Installed = $true
        if ($a.DisplayVersion) { $res.Version = $a.DisplayVersion }
        if (-not $res.Exe -and $a.InstallLocation) {
          $e = Join-Path $a.InstallLocation 'mpvnet.exe'
          if (Test-Path $e) { $res.Exe = $e }
        }
      }
    } catch {}
  }
  if ($res.Installed -and -not $res.Version -and $res.Exe -and (Test-Path $res.Exe)) {
    try { $res.Version = (Get-Item $res.Exe).VersionInfo.FileVersion } catch {}
  }
  return $res
}

function Get-LatestMpvSetupUrl {
  # Пытаемся взять latest через GitHub API (ассет *setup-x64.exe), иначе pinned 7.1.2.0
  try {
    $rel = Invoke-RestMethod -Uri $Script:Cfg.MpvApiLatest `
      -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -TimeoutSec 20
    $asset = $rel.assets | Where-Object { $_.name -like '*setup-x64.exe' } | Select-Object -First 1
    if ($asset -and $asset.browser_download_url) {
      return @{ Url = $asset.browser_download_url; Tag = $rel.tag_name; Name = $asset.name }
    }
  } catch { Write-Log "GitHub API недоступен, fallback на pinned: $_" 'WARN' }
  return @{
    Url  = $Script:Cfg.MpvPinnedUrl
    Tag  = $Script:Cfg.MpvPinnedVersion
    Name = 'mpv.net-v7.1.2.0-setup-x64.exe'
  }
}

# ------------------------------------------------- Detection: .NET ---
function Get-DotnetStatus {
  $res = @{ Installed = $false; Detail = '' }
  $want = $Script:Cfg.DotnetVersion
  # 1) dotnet --list-runtimes
  try {
    $out = & dotnet --list-runtimes 2>$null
    $line = $out | Where-Object { $_ -like "*Microsoft.WindowsDesktop.App $want*" } | Select-Object -First 1
    if ($line) { $res.Installed = $true; $res.Detail = $line.Trim(); return $res }
  } catch {}
  # 2) папка shared fx
  try {
    $dir = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.WindowsDesktop.App\$want*"
    $hit = Get-Item $dir -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $res.Installed = $true; $res.Detail = $hit.FullName; return $res }
  } catch {}
  # 3) реестр dotnet: имена значений — установленные версии, их данные — пути к рантайму
  try {
    $r = Get-ItemProperty $Script:Cfg.DotnetRegPath -ErrorAction SilentlyContinue
    if ($r) {
      $hit = $r.PSObject.Properties.Name | Where-Object { $_ -like "$want*" } | Select-Object -First 1
      if ($hit) { $res.Installed = $true; $res.Detail = "Microsoft.WindowsDesktop.App $hit (registry)"; return $res }
    }
  } catch {}
  return $res
}

# ------------------------------------------------- Detection: Anime4K preset ---
function Get-AnimePresetStatus {
  # Какой GLSL-пресет Anime4K уже развёрнут в %APPDATA%\mpv.net.
  # Оба архива Tama47 v4.0.1 содержат один и тот же набор .glsl — отличия в
  # mpv.conf/input.conf: Low помечен «lower-end GPU / (Fast)» и использует
  # _S-варианты шейдеров, High — «higher-end GPU / (HQ)» и _VL-варианты.
  # Возвращает @{ State = 'None'|'Low'|'High'|'Unknown'; Files = <кол-во .glsl> }
  $res = @{ State = 'None'; Files = 0 }
  $conf = Join-Path $Script:Cfg.ConfigDir 'mpv.conf'
  $shDir = Join-Path $Script:Cfg.ConfigDir 'shaders'
  try { $res.Files = @(Get-ChildItem $shDir -Filter '*.glsl' -File -ErrorAction SilentlyContinue).Count } catch { $res.Files = 0 }
  if (-not (Test-Path $conf)) {
    # конфига нет: шейдеры без конфига — частичная (неопознанная) установка
    if ($res.Files -gt 0) { $res.State = 'Unknown' }
    return $res
  }
  $blob = ''
  foreach ($f in @($conf, (Join-Path $Script:Cfg.ConfigDir 'input.conf'))) {
    if (Test-Path $f) { try { $blob += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } catch {} }
  }
  if ($blob -match 'higher-end GPU' -or $blob -match 'Mode A \(HQ\)' -or $blob -match '_VL\.glsl') {
    $res.State = 'High'
  } elseif ($blob -match 'lower-end GPU' -or $blob -match 'Mode A \(Fast\)' -or $blob -match '_S\.glsl') {
    $res.State = 'Low'
  } elseif ($blob -match 'Anime4K_') {
    $res.State = 'Unknown'   # шейдеры есть, но цепочки не из шаблонов Low/High
  }
  return $res
}

function Get-PresetStateText {
  # Человекочитаемое описание состояния — общее для UI и логов
  param([Parameter(Mandatory)][hashtable]$Pst)
  switch ($Pst.State) {
    'Low'     { return (T PstLow) }
    'High'    { return (T PstHigh) }
    'Unknown' { return (T PstUnknown) }
    default   { return (T PstNone) }
  }
}

# ------------------------------------------------- Download (с прогрессом, UI жив) ---
function Invoke-DownloadFile {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Dest,
    $Bar = $null,       # System.Windows.Controls.ProgressBar
    $StatusLabel = $null,
    # Сегмент общего прогресса: 0..100% этой загрузки проецируются в [BarMin..BarMax],
    # чтобы полоса не откатывалась назад при переходе к следующему этапу
    [int]$BarMin = 0,
    [int]$BarMax = 100
  )
  $dir = Split-Path $Dest -Parent
  if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
  if (Test-Path $Dest) { Remove-Item $Dest -Force }
  Write-Log "Скачивание: $Url -> $Dest"
  $req = [Net.HttpWebRequest]::Create($Url)
  $req.UserAgent = 'Anime4K-Installer'
  $req.AllowAutoRedirect = $true
  $req.Timeout = 60000
  $resp = $req.GetResponse()
  try {
    $total = $resp.ContentLength
    $src = $resp.GetResponseStream()
    $fs = [IO.File]::Create($Dest)
    try {
      $buf = New-Object byte[] 65536
      [long]$got = 0
      $last = -1
      while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n)
        $got += $n
        if ($total -gt 0 -and $Bar) {
          $pct = [int](($got * 100) / $total)
          if ($pct -ne $last) {
            $last = $pct
            $barVal = $BarMin + [int](($pct * ($BarMax - $BarMin)) / 100)
            $Bar.Dispatcher.Invoke([action]{ $Bar.Value = $barVal })
            if ($StatusLabel) {
              $mb = '{0:N1} / {1:N1} MB ({2}%)' -f ($got/1MB), ($total/1MB), $pct
              $prefix = $(T DlProgress)
              $StatusLabel.Dispatcher.Invoke([action]{ $StatusLabel.Text = "$prefix $mb" })
            }
          }
        }
        # даём WPF отрисоваться и обработать ввод
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
          [action]{}, [Windows.Threading.DispatcherPriority]::Background)
      }
    } finally { $fs.Close(); $src.Close() }
  } finally { $resp.Close() }
  Write-Log "Скачано: $Dest"
}

function Invoke-ProcessWait {
  param([Parameter(Mandatory)][Diagnostics.Process]$Proc, [int]$TimeoutSec = 600)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $Proc.HasExited) {
    if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
      try { $Proc.Kill() } catch {}
      throw "Процесс превысил таймаут ${TimeoutSec}с: $($Proc.StartInfo.FileName)"
    }
    Start-Sleep -Milliseconds 200
    try {
      [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [action]{}, [Windows.Threading.DispatcherPriority]::Background)
    } catch {}
  }
  return $Proc.ExitCode
}

function Invoke-ProcessWaitSilent {
  # вариант для Silent-режима (без Dispatcher)
  param([Parameter(Mandatory)][Diagnostics.Process]$Proc, [int]$TimeoutSec = 600)
  if (-not $Proc.WaitForExit($TimeoutSec * 1000)) {
    try { $Proc.Kill() } catch {}
    throw 'Процесс превысил таймаут.'
  }
  return $Proc.ExitCode
}

# ------------------------------------------------- Install steps ---
function Install-MpvNetSetup {
  param([string]$SetupExe, [bool]$UseDispatcher = $true)
  Write-Log "Установка mpv.net системно: $SetupExe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS"
  # Inno Setup: системная установка = /ALLUSERS, требует админа
  $args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS'
  $p = [Diagnostics.Process]::Start($SetupExe, $args)
  if ($UseDispatcher) { $code = Invoke-ProcessWait $p } else { $code = Invoke-ProcessWaitSilent $p }
  Write-Log "mpv.net setup exit code: $code"
  if ($code -ne 0) { throw "Установщик mpv.net вернул код $code" }
}

function Install-DotnetRuntime {
  param([string]$InstallerExe, [bool]$UseDispatcher = $true)
  Write-Log "Установка .NET Runtime: $InstallerExe /install /quiet /norestart"
  $p = [Diagnostics.Process]::Start($InstallerExe, '/install /quiet /norestart')
  if ($UseDispatcher) { $code = Invoke-ProcessWait $p } else { $code = Invoke-ProcessWaitSilent $p }
  Write-Log "dotnet runtime exit code: $code"
  # dotnet installer: 0 = ok, 3010 = ok, нужен ребут (подавляем /norestart, считаем успехом)
  if ($code -notin @(0, 3010)) { throw "Установщик .NET вернул код $code" }
}

function Install-AnimePreset {
  param(
    [ValidateSet('Low','High')][string]$Which,
    [int]$BarMin = 0,
    [int]$BarMax = 100
  )
  $dest = $Script:Cfg.ConfigDir
  if (-not (Test-Path $dest)) { New-Item $dest -ItemType Directory -Force | Out-Null }
  # shaders подпапка (архивы Tama47 уже содержат shaders/, но гарантируем наличие)
  $shDir = Join-Path $dest 'shaders'
  if (-not (Test-Path $shDir)) { New-Item $shDir -ItemType Directory -Force | Out-Null }

  $url = if ($Which -eq 'Low') { $Script:Cfg.AnimeLowUrl } else { $Script:Cfg.AnimeHighUrl }
  $zip = Join-Path $env:TEMP ("Anime4K_" + $Which + ".zip")
  if ($Script:Bar -and $Script:LblStatus) {
    Invoke-DownloadFile -Url $url -Dest $zip -Bar $Script:Bar -StatusLabel $Script:LblStatus -BarMin $BarMin -BarMax $BarMax
  } else {
    # silent: без UI
    Write-Log "Скачивание пресета ${Which}: $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -UseBasicParsing
  }

  $tmp = Join-Path $env:TEMP ("Anime4K_x_" + [Guid]::NewGuid().ToString('N'))
  New-Item $tmp -ItemType Directory -Force | Out-Null
  try {
    Write-Log "Распаковка $zip -> $tmp (перезапись молча)"
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    # macOS-метаданные из архивов Tama47 mpv не нужны — вычищаем (__MACOSX, ._*, .DS_Store)
    $macDir = Join-Path $tmp '__MACOSX'
    if (Test-Path $macDir) { Remove-Item $macDir -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $tmp -Force -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '._*' -or $_.Name -eq '.DS_Store' } |
      Remove-Item -Force -ErrorAction SilentlyContinue
    # Архивы могут лежать либо плоско (mpv.conf в корне),
    # либо в одной вложенной папке — ищем реальный корень по mpv.conf
    $source = $tmp
    if (-not (Test-Path (Join-Path $tmp 'mpv.conf'))) {
      $sub = Get-ChildItem $tmp -Directory | ForEach-Object {
        if (Test-Path (Join-Path $_.FullName 'mpv.conf')) { $_.FullName }
      } | Select-Object -First 1
      if ($sub) { $source = $sub }
    }
    Write-Log "Источник конфигов: $source"
    Write-Log "Копирование в $dest с перезаписью (порядок шейдеров — как в mpv.conf из архива)"
    Copy-Item (Join-Path $source '*') -Destination $dest -Recurse -Force
  } finally {
    try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $zip -Force -ErrorAction SilentlyContinue } catch {}
  }
  Write-Log "Пресет $Which установлен в $dest"
}

# ------------------------------------------------- XAML: главное окно ---
$Script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="mpv.net + Anime4K — Установщик" Height="900" Width="1100"
        MinHeight="820" MinWidth="900" WindowStartupLocation="CenterScreen"
        Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="14">
  <Window.Resources>
    <!-- Токены: только Brush (Color->Brush через StaticResource падает).
         Фон — Transparent, поверхности с альфой (AARRGGBB): сквозь них видна Mica
         на Windows 11. Если backdrop недоступен, Enable-FluentChrome вернёт сплошной
         #202020, и полупрозрачные поверхности смешаются с ним как раньше. -->
    <SolidColorBrush x:Key="B_Card" Color="#A62B2B2B"/>
    <SolidColorBrush x:Key="B_CardHover" Color="#C0323232"/>
    <SolidColorBrush x:Key="B_Subtle" Color="#A62D2D2D"/>
    <SolidColorBrush x:Key="B_Pressed" Color="#E0262626"/>
    <SolidColorBrush x:Key="B_Log" Color="#D9101010"/>
    <SolidColorBrush x:Key="B_LogText" Color="#D6D6D6"/>
    <SolidColorBrush x:Key="B_Border" Color="#59333333"/>
    <SolidColorBrush x:Key="B_BorderStrong" Color="#73454545"/>
    <SolidColorBrush x:Key="B_Accent" Color="#60CDFF"/>
    <SolidColorBrush x:Key="B_AccentHover" Color="#70D3FF"/>
    <SolidColorBrush x:Key="B_AccentPressed" Color="#40B0E0"/>
    <SolidColorBrush x:Key="B_OnAccent" Color="#000000"/>
    <SolidColorBrush x:Key="B_TextPrimary" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="B_TextSec" Color="#C7C7C7"/>
    <SolidColorBrush x:Key="B_Success" Color="#6CCB5F"/>
    <SolidColorBrush x:Key="B_Warning" Color="#FCE100"/>
    <SolidColorBrush x:Key="B_Error" Color="#FF99A4"/>
    <SolidColorBrush x:Key="B_SuccessBg" Color="#1A3320"/>
    <SolidColorBrush x:Key="B_WarningBg" Color="#3A3000"/>
    <SolidColorBrush x:Key="B_ErrorBg" Color="#3A1D20"/>
    <!-- Консоль логов: фон и цвета уровней (строки красит Write-Log) -->
    <SolidColorBrush x:Key="B_Console" Color="#E60E0E12"/>
    <SolidColorBrush x:Key="B_LogTs" Color="#7C8494"/>
    <SolidColorBrush x:Key="B_LogInfo" Color="#60CDFF"/>
    <SolidColorBrush x:Key="B_LogWarn" Color="#FCE100"/>
    <SolidColorBrush x:Key="B_LogError" Color="#FF99A4"/>
    <FontFamily x:Key="F_Mono">Cascadia Code, Consolas</FontFamily>
    <FontFamily x:Key="F_Icons">Segoe MDL2 Assets</FontFamily>
    <!-- Focus-ring: только рамка (AdornedElementPlaceholder здесь лишний) -->
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="-3" RadiusX="5" RadiusY="5" StrokeThickness="2"
                       Stroke="{StaticResource B_Accent}" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Карточка: без Margin в стиле, ритм задают explicit Margin у инстансов -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource B_Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource B_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource B_BorderStrong}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource B_TextSec}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="17"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource B_TextPrimary}"/>
      <Setter Property="Margin" Value="0,8,0,8"/>
    </Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="CornerRadius" Value="4"/>
      <Setter Property="Padding" Value="8,3"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style x:Key="Kbd" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource B_Log}"/>
      <Setter Property="BorderBrush" Value="{StaticResource B_BorderStrong}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="4"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <!-- Два шаблона: secondary и primary (общий hover не должен перебивать accent) -->
    <ControlTemplate x:Key="TplButton" TargetType="Button">
      <Border x:Name="b" Background="{TemplateBinding Background}"
              BorderBrush="{TemplateBinding BorderBrush}"
              BorderThickness="{TemplateBinding BorderThickness}"
              CornerRadius="4" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="b" Property="Background" Value="{StaticResource B_CardHover}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="b" Property="Background" Value="{StaticResource B_Pressed}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter TargetName="b" Property="Opacity" Value="0.45"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <ControlTemplate x:Key="TplPrimary" TargetType="Button">
      <Border x:Name="b" Background="{TemplateBinding Background}"
              CornerRadius="4" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="b" Property="Background" Value="{StaticResource B_AccentHover}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="b" Property="Background" Value="{StaticResource B_AccentPressed}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter TargetName="b" Property="Opacity" Value="0.45"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="Button">
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Background" Value="{StaticResource B_Subtle}"/>
      <Setter Property="Foreground" Value="{StaticResource B_TextPrimary}"/>
      <Setter Property="BorderBrush" Value="{StaticResource B_BorderStrong}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template" Value="{StaticResource TplButton}"/>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Template" Value="{StaticResource TplPrimary}"/>
      <Setter Property="Background" Value="{StaticResource B_Accent}"/>
      <Setter Property="Foreground" Value="{StaticResource B_OnAccent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="MinHeight" Value="44"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
    </Style>
    <!-- Прогресс: PART_Track=фон, PART_Indicator=заливка; indeterminate=мягкий pulse -->
    <Style x:Key="FluentProgress" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="{StaticResource B_Border}"/>
      <Setter Property="Foreground" Value="{StaticResource B_Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True">
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                      CornerRadius="4" HorizontalAlignment="Left"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="HorizontalAlignment" Value="Stretch"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                      <DoubleAnimation Storyboard.TargetName="PART_Indicator"
                                       Storyboard.TargetProperty="Opacity"
                                       From="0.35" To="0.9" Duration="0:0:0.6"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="PART_Indicator"
                                       Storyboard.TargetProperty="Opacity"
                                       To="1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Окно логов: карточка с кастомной шапкой (иконка терминала + анимированный
         шеврон) и тёмной консолью внутри. Строки красит Write-Log через RichTextBox. -->
    <Style x:Key="LogExpander" TargetType="Expander">
      <Setter Property="Foreground" Value="{StaticResource B_TextSec}"/>
      <Setter Property="Margin" Value="0,10,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <Border Background="{StaticResource B_Card}" BorderBrush="{StaticResource B_Border}"
                    BorderThickness="1" CornerRadius="8">
              <DockPanel>
                <ToggleButton x:Name="HeaderSite" DockPanel.Dock="Top" Cursor="Hand"
                              Content="{TemplateBinding Header}"
                              Foreground="{TemplateBinding Foreground}"
                              FocusVisualStyle="{StaticResource FocusRing}"
                              IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                  <ToggleButton.Template>
                    <ControlTemplate TargetType="ToggleButton">
                      <Grid>
                        <Border x:Name="hb" Background="Transparent" CornerRadius="6" Margin="4"/>
                        <Grid Margin="14,9,12,9">
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                          </Grid.ColumnDefinitions>
                          <TextBlock Text="&#xE756;" FontFamily="{StaticResource F_Icons}" FontSize="15"
                                     Foreground="{StaticResource B_Accent}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                          <ContentPresenter Grid.Column="1" Content="{TemplateBinding Content}" VerticalAlignment="Center"
                                            TextElement.Foreground="{TemplateBinding Foreground}"
                                            TextElement.FontWeight="SemiBold"/>
                          <Path x:Name="chev" Grid.Column="2" Data="M 1 1 L 6 6 L 11 1" Stroke="{StaticResource B_TextSec}"
                                StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                VerticalAlignment="Center" Margin="12,0,2,0" RenderTransformOrigin="0.5,0.5">
                            <Path.RenderTransform>
                              <RotateTransform Angle="0"/>
                            </Path.RenderTransform>
                          </Path>
                        </Grid>
                      </Grid>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="hb" Property="Background" Value="{StaticResource B_CardHover}"/>
                          <Setter Property="Foreground" Value="{StaticResource B_TextPrimary}"/>
                          <Setter TargetName="chev" Property="Stroke" Value="{StaticResource B_TextPrimary}"/>
                        </Trigger>
                        <Trigger Property="IsChecked" Value="True">
                          <Setter TargetName="chev" Property="Stroke" Value="{StaticResource B_Accent}"/>
                          <Trigger.EnterActions>
                            <BeginStoryboard>
                              <Storyboard>
                                <DoubleAnimation Storyboard.TargetName="chev"
                                                 Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                                 To="180" Duration="0:0:0.18">
                                  <DoubleAnimation.EasingFunction>
                                    <CubicEase EasingMode="EaseOut"/>
                                  </DoubleAnimation.EasingFunction>
                                </DoubleAnimation>
                              </Storyboard>
                            </BeginStoryboard>
                          </Trigger.EnterActions>
                          <Trigger.ExitActions>
                            <BeginStoryboard>
                              <Storyboard>
                                <DoubleAnimation Storyboard.TargetName="chev"
                                                 Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                                 To="0" Duration="0:0:0.18"/>
                              </Storyboard>
                            </BeginStoryboard>
                          </Trigger.ExitActions>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </ToggleButton.Template>
                </ToggleButton>
                <Border x:Name="Console" Visibility="Collapsed" Background="{StaticResource B_Console}"
                        BorderBrush="{StaticResource B_Border}" BorderThickness="0,1,0,0"
                        CornerRadius="0,0,7,7" Padding="12,10,8,10">
                  <ContentPresenter/>
                </Border>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True">
                <Setter TargetName="Console" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Console" Storyboard.TargetProperty="Opacity"
                                       From="0" To="1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Консоль: прозрачный фон (его даёт Border шаблона), моноширинный шрифт -->
    <Style x:Key="LogConsole" TargetType="RichTextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource B_LogText}"/>
      <Setter Property="FontFamily" Value="{StaticResource F_Mono}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="IsReadOnlyCaretVisible" Value="False"/>
      <Setter Property="IsUndoEnabled" Value="False"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="20">
    <StackPanel>
      <!-- Header -->
      <Grid Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="mpv.net + Anime4K" FontSize="24" FontWeight="Bold"/>
          <TextBlock x:Name="txtSubtitle" Style="{StaticResource Muted}" Text="Системная установка • .NET 10 Desktop Runtime • GLSL-пресеты v4.0.1"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnLang" Content="EN" ToolTip="RU / EN"/>
          <Button x:Name="btnRecheck" Content="⟳ Проверить снова" Margin="0,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- Step 1: статус -->
      <TextBlock x:Name="txtStep1" Style="{StaticResource H2}" Text="Шаг 1 — Проверка компонентов"/>
      <UniformGrid Columns="2">
        <Border Style="{StaticResource Card}" Margin="0,0,6,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="dotMpv" Width="12" Height="12" Fill="#8A8F9C" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtMpvTitle" Text="mpv.net (системно)" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="lblMpvStatus" Style="{StaticResource Muted}" Text="Проверка…" Margin="0,6,0,0"/>
            <TextBlock x:Name="txtMpvSub" Style="{StaticResource Muted}" Text="Установщик: *-setup-x64.exe, ключи /VERYSILENT /ALLUSERS"/>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="6,0,0,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="dotNet" Width="12" Height="12" Fill="#8A8F9C" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock Text=".NET Desktop Runtime 10.0.13 x64" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="lblDotStatus" Style="{StaticResource Muted}" Text="Проверка…" Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="windowsdesktop-runtime-10.0.13-win-x64.exe, /quiet"/>
          </StackPanel>
        </Border>
      </UniformGrid>

      <!-- Step 2: пресет -->
      <TextBlock x:Name="txtStep2" Style="{StaticResource H2}" Text="Шаг 2 — Пресет Anime4K (папка %APPDATA%\mpv.net, перезапись молча)"/>
      <!-- Статус: какой пресет уже установлен (детект по mpv.conf/input.conf) -->
      <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
        <Ellipse x:Name="dotPreset" Width="12" Height="12" Fill="#8A8F9C" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="lblPresetStatus" Style="{StaticResource Muted}" Text="Проверка…" VerticalAlignment="Center"/>
      </StackPanel>
      <UniformGrid Columns="2">
        <Border Style="{StaticResource Card}" Margin="0,0,6,12">
          <StackPanel>
            <RadioButton x:Name="rbLow" Content="Low-end GPU" FontWeight="SemiBold" Foreground="#E6E6E6" GroupName="Preset"/>
            <TextBlock x:Name="txtLowDesc" Style="{StaticResource Muted}" Text="GTX 980, GTX 1060, RX 570. Быстрые шейдеры, меньше нагрузка." Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="GLSL_Windows_Low-end.zip (Tama47 v4.0.1)"/>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="6,0,0,12">
          <StackPanel>
            <RadioButton x:Name="rbHigh" Content="High-end GPU" FontWeight="SemiBold" Foreground="#E6E6E6" GroupName="Preset" IsChecked="True"/>
            <TextBlock x:Name="txtHighDesc" Style="{StaticResource Muted}" Text="GTX 1080, RTX 2070/3060, RX 590, Vega 56, 5700XT, 6600XT." Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="GLSL_Windows_High-end.zip (Tama47 v4.0.1)"/>
          </StackPanel>
        </Border>
      </UniformGrid>
      <TextBlock x:Name="txtShaderNote" Style="{StaticResource Muted}" Margin="0,0,0,12" Text="Порядок и приоритет шейдеров берутся из mpv.conf внутри архива — скрипт их не переписывает, только копирует файлы с перезаписью."/>

      <!-- Step 3: установка -->
      <TextBlock x:Name="txtStep3" Style="{StaticResource H2}" Text="Шаг 3 — Установка"/>
      <Button x:Name="btnInstall" Style="{StaticResource PrimaryButton}" Content="Установить / Обновить всё" Height="46"/>
      <ProgressBar x:Name="progressBar" Style="{StaticResource FluentProgress}" Margin="0,10,0,6" Minimum="0" Maximum="100" Value="0"/>
      <TextBlock x:Name="txtStatus" Style="{StaticResource Muted}" Text="Готов. Выберите пресет и нажмите «Установить»."/>
      <Expander x:Name="expLog" Style="{StaticResource LogExpander}" Header="Логи" IsExpanded="False">
        <RichTextBox x:Name="txtLog" Height="124" Style="{StaticResource LogConsole}">
          <RichTextBox.Resources>
            <!-- Тонкий тёмный скроллбар только у консоли (вертикальный) -->
            <Style TargetType="ScrollBar">
              <Setter Property="Width" Value="12"/>
              <Setter Property="Background" Value="Transparent"/>
              <Setter Property="Focusable" Value="False"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ScrollBar">
                    <Grid Background="{TemplateBinding Background}">
                      <Track x:Name="PART_Track" IsDirectionReversed="True">
                        <Track.DecreaseRepeatButton>
                          <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False" Opacity="0"/>
                        </Track.DecreaseRepeatButton>
                        <Track.Thumb>
                          <Thumb MinHeight="28">
                            <Thumb.Template>
                              <ControlTemplate TargetType="Thumb">
                                <Border x:Name="tb" Background="#3DFFFFFF" CornerRadius="3" Margin="3,2"/>
                                <ControlTemplate.Triggers>
                                  <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="tb" Property="Background" Value="#66FFFFFF"/>
                                  </Trigger>
                                  <Trigger Property="IsDragging" Value="True">
                                    <Setter TargetName="tb" Property="Background" Value="#80FFFFFF"/>
                                  </Trigger>
                                </ControlTemplate.Triggers>
                              </ControlTemplate>
                            </Thumb.Template>
                          </Thumb>
                        </Track.Thumb>
                        <Track.IncreaseRepeatButton>
                          <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False" Opacity="0"/>
                        </Track.IncreaseRepeatButton>
                      </Track>
                    </Grid>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
          </RichTextBox.Resources>
          <FlowDocument PagePadding="0" LineHeight="18"/>
        </RichTextBox>
      </Expander>

      <!-- Quick Usage -->
      <Border Style="{StaticResource Card}" Margin="0,12,0,12" BorderBrush="#7AA2F7">
        <StackPanel>
          <TextBlock x:Name="txtQuickTitle" Text="Quick Usage — как пользоваться Anime4K" FontWeight="Bold" FontSize="15" Margin="0,0,0,6"/>
          <TextBlock x:Name="txtQuickSub" Style="{StaticResource Muted}" Text="Mode A включён автоматически (так задано в mpv.conf из шаблона). Вручную:"/>
          <TextBlock Margin="0,6,0,0" TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+1"/> — <Run x:Name="runModeA" Text="Mode A (оптимально для 1080p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+2"/> — <Run x:Name="runModeB" Text="Mode B (оптимально для 720p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+3"/> — <Run x:Name="runModeC" Text="Mode C (оптимально для 480p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#9ECE6A" FontWeight="Bold" Text="Ctrl+4/5/6"/> — <Run x:Name="runBoost" Text="усиленные (двойной проход: A+A / B+B / C+A)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#FF99A4" FontWeight="Bold" Text="Ctrl+0"/> — <Run x:Name="runModeOff" Text="сбросить шейдеры (выключить Anime4K)"/></TextBlock>
        </StackPanel>
      </Border>

      <!-- Footer: строки источников больше нет — вся информация в «О программе» -->
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
        <Button x:Name="btnAdvanced" Content="📖 Подробная инструкция" Background="#31364A" Foreground="White"/>
        <Button x:Name="btnOpenConfig" Content="📁 Открыть папку конфига"/>
        <Button x:Name="btnAbout" Content="ℹ О программе" Margin="0,0,0,0"/>
      </StackPanel>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

# ------------------------------------------------- XAML: Advanced окно (RU) ---
$Script:AdvancedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Подробная инструкция — Anime4K GLSL / MPV v4.x" Height="820" Width="960"
        MinHeight="680" MinWidth="860" WindowStartupLocation="CenterScreen"
        Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="13.5">
  <Grid Margin="0">
    <FlowDocumentScrollViewer Background="Transparent" VerticalScrollBarVisibility="Auto" Padding="24">
      <FlowDocument Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="13.5" PagePadding="0">
        <Paragraph Margin="0,0,0,4">
          <Run FontSize="22" FontWeight="Bold" Text="Подробная инструкция "/>
          <Run FontSize="13" Foreground="#C7C7C7" Text="(GLSL / MPV, v4.x)"/>
        </Paragraph>
        <Paragraph Foreground="#C7C7C7" Margin="0,0,0,12">
          <Run Text="Порядок шейдеров и значения по умолчанию — как в mpv.conf из архива пресета. Ниже — что означают режимы и как собрать свой пайплайн."/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="1. Режимы: A, B, C и вторичные"/></Paragraph>
        <Paragraph><Run Text="Маленькие CNN не могут одинаково хорошо чинить все типы деградаций, поэтому выбор режима — за вами. Проще всего прогнать A → B → C глазами: обычно правильный тот, что выглядит лучше. Режим A при неправильном использовании даёт самые заметные артефакты, B и C на низком разрешении различить сложнее. Для роста перцептуального качества используйте вторичный режим (вторая строка таблицы)."/></Paragraph>
        <Paragraph Foreground="#C7C7C7"><Run Text="Соответствие: A → A+A,  B → B+B,  C → C+A. Вторичные режимы — только при апскейле ×2 и выше (на экране 1080p режим A+A поверх 1080p-видео чаще перешарпит картинку)."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#333333" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns>
            <TableColumn Width="70"/><TableColumn Width="190"/><TableColumn Width="220"/><TableColumn Width="220"/>
          </Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2D2D2D" FontWeight="Bold">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Режим"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Для чего"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Плюсы"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,1,1,1" Padding="8"><Paragraph><Run Text="Минусы при неверном выборе"/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Большинство 1080p, часть старых 720p/SD. Много блюра, ресемплинг, смазы компрессии."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Высокое перцептуальное качество, чинит линии, убирает блюр/шум/компрессию."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Может усилить рингинг/бэндинг, сгладить текстуры сильным денойзом."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#232323">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="B"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Часть 1080p, большинство 720p, 1080p→720p. Мало блюра, рингинг от даунскейла."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Чинит линии, режет шум/блюр/рингинг/алиасинг."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Часть артефактов может остаться, линии — мягкими."/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="C"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="1080p→480p, редко 1080p-мувики, чистые арты/обои/Pixiv."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Самый высокий PSNR, денойз."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Низкое перцептуальное качество, может усилить рингинг."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#232323">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#FCE100" Text="A+A / B+B / C+A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Те же случаи, что у первичного режима. Максимальное качество."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Почти все линии восстановлены (A+A — топ)."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,0" Padding="8"><Paragraph><Run Text="Медленнее; A+A может дать сильный рингинг/бэндинг/алиасинг."/></Paragraph></TableCell>
            </TableRow>
          </TableRowGroup>
        </Table>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="2. Горячие клавиши (из input.conf шаблона)"/></Paragraph>
        <Paragraph FontFamily="Cascadia Code, Consolas" Background="#101010" Padding="10" Foreground="#D6D6D6">
          <Run Text="CTRL+1  → Mode A (1080p)  |  CTRL+2  → Mode B (720p)  |  CTRL+3  → Mode C (480p)  |  CTRL+0  → выключить шейдеры"/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="3. Из чего состоит пайплайн"/></Paragraph>
        <Paragraph><Run Text="Базовые цепочки (Clamp_Highlights и AutoDownscalePre опущены для краткости): A = Restore → Upscale → Upscale; B = Restore_Soft → Upscale → Upscale; C = Upscale_Denoise → Upscale; A+A = Restore → Upscale → Restore → Upscale; B+B = Restore_Soft → Upscale → Restore_Soft → Upscale; C+A = Upscale_Denoise → Restore → Upscale."/></Paragraph>
        <Paragraph><Run Text="Правила: каждый .glsl-файл можно использовать только один раз (дубли — копируйте и переименовывайте); порядок обработки = порядок в input.conf (кроме Clamp_Highlights — он замеряет статистику в точке вставки, а клампит в конце); вариант CNN S/M/L/VL/UL — каждая ступень ×2 ко времени (M 5мс → L ~10мс → VL ~20мс); не-CNN шейдеры быстрее, но слабее."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#333333" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns><TableColumn Width="190"/><TableColumn Width="510"/></Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2D2D2D" FontWeight="Bold">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Тип шейдера"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Эффект"/></Paragraph></TableCell>
            </TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Restore / Restore_Soft"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Главная фишка Anime4K. Чинит картинку ДО апскейла: компрессия, блюр, рингинг. Restore — против апскейл-артефактов и блюра, Soft — против даунскейла и алиасинга."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#232323"><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Upscale / Upscale_Denoise"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Апскейл ×2. Denoise-версия чистит шум без потери скорости. Режим без Restore обязан начинаться с Upscale_Denoise/Denoise (компрессия почти всегда lossy)."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Clamp_Highlights"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Ставьте в начало: запоминает статистику и в конце режет выбросы — меньше рингинга. Снятие даёт чуть больше скорости."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#232323"><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Darken / Thin / Denoise / Deblur"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Затемнение/утоньшение линий (на вкус), денойз, деблюр без овершута."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="6"><Paragraph><Run Text="AutoDownscalePre_x4 / _x2"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,0" Padding="6"><Paragraph><Run Text="Уменьшают картинку между апскейлами под размер экрана — быстрее без потери качества. _x4 — между двумя Upscale, _x2 — после первого Upscale."/></Paragraph></TableCell></TableRow>
          </TableRowGroup>
        </Table>
        <Paragraph Foreground="#C7C7C7"><Run Text="Как читать составные режимы (пример C+A+B): 1) C(Upscale)→A(Restore→Upscale)→B(Restore_Soft→Upscale); 2) раз нет Restore в начале — C становится Upscale_Denoise; 3) итог: Upscale_Denoise → Restore → Upscale → Restore_Soft → Upscale. Все режимы добивают апскейл до ~×4 (480p→4K ≈ ×4.5)."/></Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="4. Best practices и производительность"/></Paragraph>
        <Paragraph><Run Text="• Clamp_Highlights в начале почти всегда полезен. • Restore после апскейла = лучше перцептуально, но медленнее и возможны артефакты. • Шейдер после ×2-апскейла стоит ×4 времени: если до апскейла 10мс — после будет ~40мс; лечится вариантом на 2 ступени ниже (L→S). • На высоких разрешениях артефакты S/M-вариантов почти не видны — так можно снизить шум/нагрев GPU."/></Paragraph>
        <Paragraph><Run Text="Ориентир — уложиться в кадр: 24fps → 41мс, 30fps → 33мс, 60fps → 16мс. Проверка: профайлер mpv — Shift+I, затем 2 (верхний ряд). Если есть дропы — спускайтесь по вариантам CNN."/></Paragraph>
        <Paragraph Foreground="#C7C7C7"><Run Text="Файлы лежат в %APPDATA%\mpv.net (mpv.conf, input.conf, shaders\). Открыть папку можно кнопкой в главном окне."/></Paragraph>
      </FlowDocument>
    </FlowDocumentScrollViewer>
  </Grid>
</Window>
'@

# ------------------------------------------------- XAML: Advanced окно (EN) ---
$Script:AdvancedXamlEn = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Advanced Usage Instructions — Anime4K GLSL / MPV v4.x" Height="820" Width="960"
        MinHeight="680" MinWidth="860" WindowStartupLocation="CenterScreen"
        Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="13.5">
  <Grid Margin="0">
    <FlowDocumentScrollViewer Background="Transparent" VerticalScrollBarVisibility="Auto" Padding="24">
      <FlowDocument Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="13.5" PagePadding="0">
        <Paragraph Margin="0,0,0,4">
          <Run FontSize="22" FontWeight="Bold" Text="Advanced Usage Instructions "/>
          <Run FontSize="13" Foreground="#C7C7C7" Text="(GLSL / MPV, v4.x)"/>
        </Paragraph>
        <Paragraph Foreground="#C7C7C7" Margin="0,0,0,12">
          <Run Text="Shader order and defaults come from mpv.conf inside the preset archive. Below: what the modes mean and how to build your own pipeline."/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="1. Modes: A, B, C and secondary modes"/></Paragraph>
        <Paragraph><Run Text="Small CNNs cannot fix every type of degradation, so the mode choice is yours. The easiest way is to eyeball A → B → C: usually the correct mode is the one that looks best. Mode A shows the most visible artifacts of the three when used incorrectly; B and C can be harder to tell apart on low-resolution anime. For higher perceptual quality, use the corresponding secondary mode (second row of the table)."/></Paragraph>
        <Paragraph Foreground="#C7C7C7"><Run Text="Mapping: A → A+A,  B → B+B,  C → C+A. Secondary modes only make sense at upscale ratios of x2 or higher (on a 1080p screen, A+A over 1080p video will most likely oversharpen the image)."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#333333" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns>
            <TableColumn Width="70"/><TableColumn Width="190"/><TableColumn Width="220"/><TableColumn Width="220"/>
          </Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2D2D2D" FontWeight="Bold">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Mode"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Optimized for"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Pros"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,1,1,1" Padding="8"><Paragraph><Run Text="Cons if misused"/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Most 1080p, some old 720p/SD. Heavy blur, resampling artifacts, compression smearing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="High perceptual quality, restores lines, removes blur/noise/compression."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="May amplify ringing/banding, strong denoise may blur textures."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#232323">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="B"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Some 1080p, most 720p, 1080p→720p. Little blur, downsampling ringing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Restores lines, cuts noise/blur/ringing/aliasing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Some artifacts may remain, lines may stay soft."/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#60CDFF" Text="C"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="1080p→480p, rarely 1080p movies, clean art/wallpapers/Pixiv."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Highest PSNR, denoise."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Low perceptual quality, may amplify ringing."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#232323">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#FCE100" Text="A+A / B+B / C+A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Same cases as the primary mode. Maximum quality."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Almost all lines restored (A+A is the best)."/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,0" Padding="8"><Paragraph><Run Text="Slower; A+A may cause strong ringing/banding/aliasing."/></Paragraph></TableCell>
            </TableRow>
          </TableRowGroup>
        </Table>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="2. Hotkeys (from the template input.conf)"/></Paragraph>
        <Paragraph FontFamily="Cascadia Code, Consolas" Background="#101010" Padding="10" Foreground="#D6D6D6">
          <Run Text="CTRL+1  → Mode A (1080p)  |  CTRL+2  → Mode B (720p)  |  CTRL+3  → Mode C (480p)  |  CTRL+0  → clear shaders"/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="3. What the pipeline is made of"/></Paragraph>
        <Paragraph><Run Text="Base chains (Clamp_Highlights and AutoDownscalePre omitted for clarity): A = Restore → Upscale → Upscale; B = Restore_Soft → Upscale → Upscale; C = Upscale_Denoise → Upscale; A+A = Restore → Upscale → Restore → Upscale; B+B = Restore_Soft → Upscale → Restore_Soft → Upscale; C+A = Upscale_Denoise → Restore → Upscale."/></Paragraph>
        <Paragraph><Run Text="Rules: each .glsl file may be used only once (for duplicates, copy and rename); processing order = order in input.conf (except Clamp_Highlights — it measures stats at its position but clamps at the end); CNN variant S/M/L/VL/UL — each step is ~x2 time (M 5ms → L ~10ms → VL ~20ms); non-CNN shaders are faster but weaker."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#333333" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns><TableColumn Width="190"/><TableColumn Width="510"/></Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2D2D2D" FontWeight="Bold">
              <TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Shader type"/></Paragraph></TableCell>
              <TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Effect"/></Paragraph></TableCell>
            </TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Restore / Restore_Soft"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="What makes Anime4K special. Fixes the image BEFORE upscaling: compression, blur, ringing. Restore targets upscale artifacts and blur, Soft targets downscale artifacts and aliasing."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#232323"><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Upscale / Upscale_Denoise"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="x2 upscale. The Denoise variant cleans noise at no speed cost. A mode without Restore must start with Upscale_Denoise/Denoise (compression is almost always lossy)."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Clamp_Highlights"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Put it first: it records stats and clamps overshoot at the end — less ringing. Removing it is slightly faster."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#232323"><TableCell BorderBrush="#333333" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Darken / Thin / Denoise / Deblur"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Line darkening/thinning (to taste), denoise, overshoot-free deblur."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#333333" BorderThickness="0,0,1,0" Padding="6"><Paragraph><Run Text="AutoDownscalePre_x4 / _x2"/></Paragraph></TableCell><TableCell BorderBrush="#333333" BorderThickness="0,0,0,0" Padding="6"><Paragraph><Run Text="Downscale between upscales to screen size — faster with no visible quality loss. _x4 goes between two Upscales, _x2 goes after the first Upscale."/></Paragraph></TableCell></TableRow>
          </TableRowGroup>
        </Table>
        <Paragraph Foreground="#C7C7C7"><Run Text="How to read combined modes (example C+A+B): 1) C(Upscale)→A(Restore→Upscale)→B(Restore_Soft→Upscale); 2) no Restore at the start, so C becomes Upscale_Denoise; 3) result: Upscale_Denoise → Restore → Upscale → Restore_Soft → Upscale. All modes upscale to ~x4 total (480p→4K is ~x4.5)."/></Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#60CDFF" Text="4. Best practices and performance"/></Paragraph>
        <Paragraph><Run Text="• Clamp_Highlights first is almost always worth it. • Restore after upscale = better perceptually, but slower and may add artifacts. • A shader after a x2 upscale costs x4 time: 10ms before upscale becomes ~40ms after; fix it with a variant two steps smaller (L→S). • At high resolutions S/M-variant artifacts are barely visible — use them to cut GPU noise/heat."/></Paragraph>
        <Paragraph><Run Text="Budget per frame: 24fps → 41ms, 30fps → 33ms, 60fps → 16ms. Check with the mpv profiler — Shift+I, then 2 (top row). If frames drop, step down the CNN variants."/></Paragraph>
        <Paragraph Foreground="#C7C7C7"><Run Text="Files live in %APPDATA%\mpv.net (mpv.conf, input.conf, shaders\). Open the folder with the button in the main window."/></Paragraph>
      </FlowDocument>
    </FlowDocumentScrollViewer>
  </Grid>
</Window>
'@

# ------------------------------------------------- XAML: О программе ---
$Script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="О программе" SizeToContent="Height" Width="500"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="13.5">
  <Window.Resources>
    <!-- Свои ресурсы: стили главного окна между окнами не наследуются -->
    <Style x:Key="SoftButton" TargetType="Button">
      <Setter Property="Background" Value="#A62D2D2D"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#73454545"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#C0323232"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#E0262626"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Margin" Value="0,18,0,8"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C7C7C7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="17"/>
    </Style>
  </Window.Resources>
  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="24">
    <StackPanel>
      <TextBlock Text="mpv.net + Anime4K" FontSize="24" FontWeight="Bold"/>
      <TextBlock x:Name="abtSubtitle" Foreground="#60CDFF" Margin="0,4,0,0" Text="Установщик • Лицензия GPL-3.0"/>
      <TextBlock x:Name="abtDesc" Style="{StaticResource Muted}" FontSize="13" Margin="0,12,0,0"/>

      <TextBlock x:Name="abtSocialTitle" Style="{StaticResource H2}" Text="Соцсети автора"/>
      <WrapPanel>
        <Button x:Name="btnYouTube"  Style="{StaticResource SoftButton}" Content="YouTube"/>
        <Button x:Name="btnTelegram" Style="{StaticResource SoftButton}" Content="Telegram"/>
        <Button x:Name="btnVk"       Style="{StaticResource SoftButton}" Content="VK"/>
        <Button x:Name="btnDzen"     Style="{StaticResource SoftButton}" Content="Dzen"/>
      </WrapPanel>

      <TextBlock x:Name="abtDonateTitle" Style="{StaticResource H2}" Text="Поддержать автора"/>
      <Border Background="#A62B2B2B" BorderBrush="#59333333" BorderThickness="1" CornerRadius="8" Padding="16">
        <StackPanel>
          <TextBlock x:Name="abtCardHint" Style="{StaticResource Muted}" Text="Перевод по номеру карты — SBER"/>
          <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
            <TextBlock x:Name="txtCard" Text="2202 2050 1464 4675" FontFamily="Cascadia Code, Consolas"
                       FontSize="16" VerticalAlignment="Center"/>
            <Button x:Name="btnCopyCard" Style="{StaticResource SoftButton}" Margin="14,0,0,0" Content="📋 Скопировать"/>
          </StackPanel>
          <TextBlock x:Name="lblCopyState" Style="{StaticResource Muted}" Foreground="#6CCB5F"
                     Visibility="Hidden" Margin="0,6,0,0" Text="Номер скопирован в буфер обмена"/>
          <TextBlock x:Name="abtThanks" Style="{StaticResource Muted}" Margin="0,8,0,0" Text="Спасибо за поддержку!"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

# ------------------------------------------------- Локализация ---
$Script:T = @{
  RU = @{
    WinTitle    = 'mpv.net + Anime4K — Установщик'
    Subtitle    = 'Системная установка • .NET 10 Desktop Runtime • GLSL-пресеты v4.0.1'
    Recheck     = '⟳ Проверить снова'
    Step1       = 'Шаг 1 — Проверка компонентов'
    MpvTitle    = 'mpv.net (системно)'
    Checking    = 'Проверка…'
    Installed   = 'Установлен'
    MpvNotFound = 'Не найден — будет установлен системно (Program Files).'
    MpvSub      = 'Установщик: *-setup-x64.exe, ключи /VERYSILENT /ALLUSERS'
    DotNotFound = 'Не найден — будет установлен 10.0.13.'
    Step2       = 'Шаг 2 — Пресет Anime4K (папка %APPDATA%\mpv.net, перезапись молча)'
    LowDesc     = 'GTX 980, GTX 1060, RX 570. Быстрые шейдеры, меньше нагрузка.'
    HighDesc    = 'GTX 1080, RTX 2070/3060, RX 590, Vega 56, 5700XT, 6600XT.'
    ShaderNote  = 'Порядок и приоритет шейдеров берутся из mpv.conf внутри архива — скрипт их не переписывает, только копирует файлы с перезаписью.'
    PstNone     = 'Anime4K-шейдеры не установлены — будет развёрнут выбранный пресет.'
    PstLow      = 'Уже установлен пресет Low-end GPU (определён по mpv.conf).'
    PstHigh     = 'Уже установлен пресет High-end GPU (определён по mpv.conf).'
    PstUnknown  = 'Установленные шейдеры не совпадают с шаблонами Low/High — mpv.conf мог быть изменён вручную.'
    PstLog      = 'Состояние шейдеров до установки: {0}'
    Step3       = 'Шаг 3 — Установка'
    InstallBtn  = '⬇ Установить / Обновить всё'
    Ready       = 'Готов. Выберите пресет и нажмите «Установить».'
    LogHeader   = 'Логи'
    QuickTitle  = 'Quick Usage — как пользоваться Anime4K'
    QuickSub    = 'Mode A включён автоматически (так задано в mpv.conf из шаблона). Вручную:'
    ModeA       = 'Mode A (оптимально для 1080p)'
    ModeB       = 'Mode B (оптимально для 720p)'
    ModeC       = 'Mode C (оптимально для 480p)'
    ModeOff     = 'сбросить шейдеры (выключить Anime4K)'
    ModeBoost   = 'усиленные (двойной проход: A+A / B+B / C+A)'
    AdvBtn      = '📖 Подробная инструкция'
    OpenCfg     = '📁 Открыть папку конфига'
    AboutBtn    = 'ℹ О программе'
    AboutTitle  = 'О программе'
    AboutSubtitle = 'Установщик • Лицензия GPL-3.0'
    AboutDesc   = 'Однофайловый установщик на чистом PowerShell: ставит mpv.net системно, проверяет и при необходимости добавляет .NET Desktop Runtime, а затем разворачивает GLSL-пресет Anime4K v4.0.1 в конфиг mpv.net. Тёмный WPF-интерфейс с Mica, поддержкой RU/EN и живым прогрессом.'
    AboutSocial = 'Соцсети автора'
    AboutDonate = 'Поддержать автора'
    AboutCardHint = 'Перевод по номеру карты — SBER'
    AboutCopy   = '📋 Скопировать'
    AboutCopied = 'Номер скопирован в буфер обмена'
    AboutThanks = 'Спасибо за поддержку!'
    LangBtn     = 'EN'
    AdminTitle  = 'Нужны права администратора'
    AdminMsg    = "Для системной установки mpv.net и .NET Runtime нужны права администратора.`n`nПерезапустить скрипт с повышением?"
    AdminStatus = 'Нужны права администратора. Перезапустите от имени администратора.'
    AdminLog    = 'Нет прав администратора — установка остановлена.'
    StDetect    = 'Определение последней версии mpv.net…'
    StInstMpv   = 'Установка mpv.net системно (тихо)…'
    StDlNet     = 'Скачивание .NET Desktop Runtime 10.0.13…'
    StInstNet   = 'Установка .NET Runtime (тихо)…'
    StPreset    = 'Установка пресета Anime4K ({0}) в %APPDATA%\mpv.net…'
    StDone      = 'Готово. Пресет {0} в {1}. Ctrl+1/2/3 — режимы, Ctrl+4/5/6 — усиленные, Ctrl+0 — выкл.'
    DlProgress  = 'Скачивание…'
    DoneTitle   = 'Anime4K установлен'
    DoneMsg     = "Готово!`n`nmpv.net установлен системно, .NET 10.0.13 проверен,`nпресет Anime4K ({0}) распакован в:`n{1}`n`nПорядок шейдеров — из mpv.conf архива.`nCtrl+1/2/3 — режимы A/B/C, Ctrl+4/5/6 — усиленные, Ctrl+0 — выключить."
    ErrTitle    = 'Ошибка'
    ErrStatus   = 'Ошибка: {0}'
    ErrMsg      = "Ошибка установки:`n{0}`n`nПодробности: {1}"
    StartLog    = '--- Старт установки ---'
    DoneLog     = '--- Установка завершена успешно ---'
    MpvHas      = 'mpv.net уже установлен: {0} @ {1}'
    NetHas      = '.NET уже установлен: {0}'
    OpenLog     = 'Открыт установщик (WPF).'
    S1          = '[1/3] mpv.net…'
    S2          = '[2/3] .NET 10.0.13…'
    S2has       = '  уже установлен: {0}'
    S3          = '[3/3] Anime4K пресет {0}…'
    Sdone       = 'Готово: {0}'
    SneedAdmin  = 'Silent-режим с системной установкой требует запуска от администратора.'
  }
  EN = @{
    WinTitle    = 'mpv.net + Anime4K — Installer'
    Subtitle    = 'System-wide install • .NET 10 Desktop Runtime • GLSL presets v4.0.1'
    Recheck     = '⟳ Check again'
    Step1       = 'Step 1 — Check components'
    MpvTitle    = 'mpv.net (system-wide)'
    Checking    = 'Checking…'
    Installed   = 'Installed'
    MpvNotFound = 'Not found — will be installed system-wide (Program Files).'
    MpvSub      = 'Installer: *-setup-x64.exe, flags /VERYSILENT /ALLUSERS'
    DotNotFound = 'Not found — 10.0.13 will be installed.'
    Step2       = 'Step 2 — Anime4K preset (folder %APPDATA%\mpv.net, silent overwrite)'
    LowDesc     = 'GTX 980, GTX 1060, RX 570. Fast shaders, lower GPU load.'
    HighDesc    = 'GTX 1080, RTX 2070/3060, RX 590, Vega 56, 5700XT, 6600XT.'
    ShaderNote  = 'Shader order and priority come from mpv.conf inside the archive — the script does not rewrite them, it only copies files with overwrite.'
    PstNone     = 'Anime4K shaders are not installed — the selected preset will be deployed.'
    PstLow      = 'Already installed: Low-end GPU preset (detected via mpv.conf).'
    PstHigh     = 'Already installed: High-end GPU preset (detected via mpv.conf).'
    PstUnknown  = 'Installed shaders do not match the Low/High templates — mpv.conf may have been edited manually.'
    PstLog      = 'Shader state before install: {0}'
    Step3       = 'Step 3 — Install'
    InstallBtn  = '⬇ Install / Update all'
    Ready       = 'Ready. Select a preset and click Install.'
    LogHeader   = 'Log'
    QuickTitle  = 'Quick Usage — how to use Anime4K'
    QuickSub    = 'Mode A is enabled automatically (as set in the template mpv.conf). Manually:'
    ModeA       = 'Mode A (best for 1080p)'
    ModeB       = 'Mode B (best for 720p)'
    ModeC       = 'Mode C (best for 480p)'
    ModeOff     = 'clear shaders (disable Anime4K)'
    ModeBoost   = 'boost (double-pass: A+A / B+B / C+A)'
    AdvBtn      = '📖 Detailed guide'
    OpenCfg     = '📁 Open config folder'
    AboutBtn    = 'ℹ About'
    AboutTitle  = 'About'
    AboutSubtitle = 'Installer • GPL-3.0 license'
    AboutDesc   = 'Single-file pure-PowerShell installer: installs mpv.net system-wide, checks and installs the .NET Desktop Runtime when needed, then deploys the Anime4K v4.0.1 GLSL preset into the mpv.net config. Dark WPF UI with Mica, RU/EN support and live progress.'
    AboutSocial = 'Follow the author'
    AboutDonate = 'Support the author'
    AboutCardHint = 'Bank transfer by card number — SBER'
    AboutCopy   = '📋 Copy'
    AboutCopied = 'Card number copied to clipboard'
    AboutThanks = 'Thank you for your support!'
    LangBtn     = 'RU'
    AdminTitle  = 'Administrator rights required'
    AdminMsg    = "System-wide install of mpv.net and .NET Runtime requires administrator rights.`n`nRelaunch the script elevated?"
    AdminStatus = 'Administrator rights required. Please relaunch as administrator.'
    AdminLog    = 'No administrator rights — install aborted.'
    StDetect    = 'Resolving latest mpv.net version…'
    StInstMpv   = 'Installing mpv.net system-wide (silent)…'
    StDlNet     = 'Downloading .NET Desktop Runtime 10.0.13…'
    StInstNet   = 'Installing .NET Runtime (silent)…'
    StPreset    = 'Installing Anime4K preset ({0}) into %APPDATA%\mpv.net…'
    StDone      = 'Done. Preset {0} in {1}. Ctrl+1/2/3 — modes, Ctrl+4/5/6 — boost, Ctrl+0 — off.'
    DlProgress  = 'Downloading…'
    DoneTitle   = 'Anime4K installed'
    DoneMsg     = "Done!`n`nmpv.net installed system-wide, .NET 10.0.13 checked,`nAnime4K preset ({0}) extracted to:`n{1}`n`nShader order — from the archive mpv.conf.`nCtrl+1/2/3 — modes A/B/C, Ctrl+4/5/6 — boost, Ctrl+0 — off."
    ErrTitle    = 'Error'
    ErrStatus   = 'Error: {0}'
    ErrMsg      = "Install failed:`n{0}`n`nDetails: {1}"
    StartLog    = '--- Install started ---'
    DoneLog     = '--- Install finished successfully ---'
    MpvHas      = 'mpv.net already installed: {0} @ {1}'
    NetHas      = '.NET already installed: {0}'
    OpenLog     = 'Installer window opened (WPF).'
    S1          = '[1/3] mpv.net…'
    S2          = '[2/3] .NET 10.0.13…'
    S2has       = '  already installed: {0}'
    S3          = '[3/3] Anime4K preset {0}…'
    Sdone       = 'Done: {0}'
    SneedAdmin  = 'Silent mode with system-wide install requires running as administrator.'
  }
}

function T {
  param([Parameter(Mandatory)][string]$Key)
  $Script:T[$Script:Lang][$Key]
}

function Set-Language {
  param([ValidateSet('RU','EN')][string]$Lang)
  $Script:Lang = $Lang
  $w = $Script:Window
  $w.Title = T WinTitle
  $w.FindName('txtSubtitle').Text    = T Subtitle
  $w.FindName('btnRecheck').Content  = T Recheck
  $w.FindName('btnLang').Content     = T LangBtn
  $w.FindName('txtStep1').Text       = T Step1
  $w.FindName('txtMpvTitle').Text    = T MpvTitle
  $w.FindName('txtMpvSub').Text      = T MpvSub
  $w.FindName('txtStep2').Text       = T Step2
  $w.FindName('txtLowDesc').Text     = T LowDesc
  $w.FindName('txtHighDesc').Text    = T HighDesc
  $w.FindName('txtShaderNote').Text  = T ShaderNote
  $w.FindName('txtStep3').Text       = T Step3
  $Script:BtnInstall.Content         = T InstallBtn
  $w.FindName('expLog').Header       = T LogHeader
  $w.FindName('txtQuickTitle').Text  = T QuickTitle
  $w.FindName('txtQuickSub').Text    = T QuickSub
  $w.FindName('runModeA').Text       = T ModeA
  $w.FindName('runModeB').Text       = T ModeB
  $w.FindName('runModeC').Text       = T ModeC
  $w.FindName('runModeOff').Text     = T ModeOff
  $w.FindName('runBoost').Text       = T ModeBoost
  $w.FindName('btnAdvanced').Content   = T AdvBtn
  $w.FindName('btnOpenConfig').Content = T OpenCfg
  $w.FindName('btnAbout').Content      = T AboutBtn
  # «Готов…» переводим на новый язык, но результат последней операции
  # (успех/ошибка/ход установки в статусной строке) не затираем
  $readyTexts = @($Script:T['RU']['Ready'], $Script:T['EN']['Ready'])
  $status = $Script:LblStatus
  if ($null -ne $status -and ([string]::IsNullOrEmpty($status.Text) -or $status.Text -in $readyTexts)) {
    $status.Text = T Ready
  }
  Update-StatusUI
}

# ------------------------------------------------- UI helpers ---
function New-WpfWindow {
  param([string]$Xaml)
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
  $xml = [xml]$Xaml
  $reader = New-Object Xml.XmlNodeReader $xml
  return [Windows.Markup.XamlReader]::Load($reader)
}

# ------------------------------------------------- Fluent chrome (dark titlebar + Mica) ---
# Guard: повторный Add-Type в той же сессии падает, поэтому -as [type] проверка.
# Важно: Handle валиден только после SourceInitialized, вызов до ShowDialog с $h=0 молча ничего не сделает.
if (-not ('Win.DwmApi' -as [type])) {
  Add-Type -Namespace Win -Name DwmApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct MARGINS { public int left; public int right; public int top; public int bottom; }
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(System.IntPtr hwnd, ref MARGINS margins);
'@
}
function Get-WindowsBuild {
  # Реестр не врёт о номере сборки, в отличие от Environment.OSVersion (нужен манифест)
  try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($cv -and $cv.PSObject.Properties['CurrentBuildNumber']) {
      $b = 0
      if ([int]::TryParse([string]$cv.CurrentBuildNumber, [ref]$b)) { return $b }
    }
  } catch {}
  try { return [Environment]::OSVersion.Version.Build } catch { return 0 }
}

function Test-MicaUsable {
  # Mica рисует DWM: нужны Windows 11, включённые эффекты прозрачности, локальная сессия
  if ((Get-WindowsBuild) -lt 22000) { return $false }
  try {
    $tp = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    if ($tp -and $tp.PSObject.Properties['EnableTransparency'] -and [int]$tp.EnableTransparency -eq 0) { return $false }
  } catch {}
  if ($env:SESSIONNAME -like 'RDP*') { return $false }
  return $true
}

# DWMWA_USE_IMMERSIVE_DARK_MODE (20) — тёмный заголовок.
# DWMWA_SYSTEMBACKDROP_TYPE (38): 2 = Mica (MAINWINDOW), 3 = Acrylic (TRANSIENTWINDOW); сборка 22621+.
# DWMWA_MICA_EFFECT (1029): legacy-путь для 22000 (21H2), где атрибута 38 ещё нет.
function Enable-FluentChrome {
  param($win)
  $solid = $null
  try { $solid = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#202020')) } catch {}
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $win).Handle
    if ($h -eq [IntPtr]::Zero) { return $false } # ещё нет HWND — вызовет SourceInitialized

    $dark = 1; [void][Win.DwmApi]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4)

    $backdrop = -1
    if (Test-MicaUsable) {
      if ((Get-WindowsBuild) -ge 22621) {
        $mica = 2
        if ([Win.DwmApi]::DwmSetWindowAttribute($h, 38, [ref]$mica, 4) -eq 0) { $backdrop = 2 }
        else {
          $acrylic = 3 # Acrylic — если Mica недоступна (VM), но backdrop-атрибут поддерживается
          if ([Win.DwmApi]::DwmSetWindowAttribute($h, 38, [ref]$acrylic, 4) -eq 0) { $backdrop = 3 }
        }
      }
      if ($backdrop -lt 0) {
        $on = 1
        if ([Win.DwmApi]::DwmSetWindowAttribute($h, 1029, [ref]$on, 4) -eq 0) { $backdrop = 1 } # 21H2
      }
    }

    if ($backdrop -gt 0) {
      # Для обычных Win32/WPF-окон материал проявляется только в области "glass-frame":
      # без расширения DWM заливает клиент сплошным fallback-цветом, а Mica виден лишь
      # в заголовке. MARGINS=-1 растягивает область на весь клиент (проверено на 26H2).
      $m = New-Object 'Win.DwmApi+MARGINS'
      $m.left = -1; $m.right = -1; $m.top = -1; $m.bottom = -1
      [void][Win.DwmApi]::DwmExtendFrameIntoClientArea($h, [ref]$m)
      # Ключ к Mica в WPF: HwndTarget должен очищать поверхность в прозрачность,
      # иначе сплошная заливка WPF полностью закроет текстуру DWM.
      # AllowsTransparency при этом остаётся False (слоёные окна Mica не получают).
      $src = [Windows.Interop.HwndSource]::FromHwnd($h)
      if ($src -and $src.CompositionTarget) {
        $src.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
      }
      $win.Background = [Windows.Media.Brushes]::Transparent
      return $true
    }

    # Windows 10 / выключены эффекты прозрачности / атрибут не принят — сплошной фон
    if ($solid) { $win.Background = $solid }
    return $false
  } catch {
    if ($solid) { try { $win.Background = $solid } catch {} }
    return $false
  }
}

function Update-StatusUI {
  $mpv = Get-MpvNetStatus
  $dn = Get-DotnetStatus
  # Токены B_Success/B_Error вместо LightGreen/Tomato — иначе выбиваются из палитры
  $ok = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#6CCB5F'))
  $bad = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FF99A4'))
  $warn = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FCE100'))
  if ($mpv.Installed) {
    $Script:LblMpv.Text = $(T Installed) + $(if ($mpv.Version) { " • v$($mpv.Version)" }) + $(if ($mpv.Exe) { "`n$($mpv.Exe)" })
    $Script:DotMpv.Fill = $ok
  } else {
    $Script:LblMpv.Text = T MpvNotFound
    $Script:DotMpv.Fill = $bad
  }
  if ($dn.Installed) {
    $Script:LblDot.Text = "$(T Installed) • $($dn.Detail)"
    $Script:DotNet.Fill = $ok
  } else {
    $Script:LblDot.Text = T DotNotFound
    $Script:DotNet.Fill = $bad
  }
  # Шаг 2: какой пресет шейдеров уже установлен (Low/High/не распознан/нет)
  $pst = Get-AnimePresetStatus
  $Script:LblPreset.Text = Get-PresetStateText $pst
  $Script:DotPreset.Fill = switch ($pst.State) {
    'Low'     { $ok }
    'High'    { $ok }
    'Unknown' { $warn }
    default   { $bad }
  }
  try {
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
      [action]{}, [Windows.Threading.DispatcherPriority]::Background)
  } catch {}
}

function Show-AdvancedWindow {
  $x = if ($Script:Lang -eq 'EN') { $Script:AdvancedXamlEn } else { $Script:AdvancedXaml }
  $w = New-WpfWindow $x
  try { $w.Owner = $Script:Window } catch {}
  # Как у главного окна: обработчик обращается к переменной скрипта. GetNewClosure()
  # использовать нельзя — он исполняет код в отдельном модуле, где не видны функции
  # скрипта (падало с CommandNotFoundException на Enable-FluentChrome).
  $Script:GuideWindow = $w
  $w.Add_SourceInitialized({ [void](Enable-FluentChrome $Script:GuideWindow) })
  $w.ShowDialog() | Out-Null
}

function Show-AboutWindow {
  $w = New-WpfWindow $Script:AboutXaml
  try { $w.Owner = $Script:Window } catch {}
  # Тексты — из локализации, ссылки и донат — из README (хранятся в $Script:Cfg)
  $w.Title = T AboutTitle
  $w.FindName('abtSubtitle').Text    = T AboutSubtitle
  $w.FindName('abtDesc').Text        = T AboutDesc
  $w.FindName('abtSocialTitle').Text = T AboutSocial
  $w.FindName('abtDonateTitle').Text = T AboutDonate
  $w.FindName('abtCardHint').Text    = T AboutCardHint
  $w.FindName('abtThanks').Text      = T AboutThanks
  $w.FindName('lblCopyState').Text   = T AboutCopied
  $w.FindName('btnCopyCard').Content = T AboutCopy
  $w.FindName('txtCard').Text        = $Script:Cfg.DonateSber
  $w.FindName('btnYouTube').Add_Click({  Start-Process $Script:Cfg.SocialYouTube })
  $w.FindName('btnTelegram').Add_Click({ Start-Process $Script:Cfg.SocialTelegram })
  $w.FindName('btnVk').Add_Click({       Start-Process $Script:Cfg.SocialVk })
  $w.FindName('btnDzen').Add_Click({     Start-Process $Script:Cfg.SocialDzen })
  $w.FindName('btnCopyCard').Add_Click({
    # В буфер кладём номер без пробелов — его удобно вставить в банковское приложение
    try {
      Set-Clipboard -Value ($Script:Cfg.DonateSber -replace '\D', '')
      $Script:AboutWindow.FindName('lblCopyState').Visibility = 'Visible'
    } catch {}
  })
  # Как у остальных окон: обработчик через переменную скрипта (GetNewClosure не работает
  # с функциями скрипта), Mica/тёмный заголовок — после появления HWND
  $Script:AboutWindow = $w
  $w.Add_SourceInitialized({ [void](Enable-FluentChrome $Script:AboutWindow) })
  $w.ShowDialog() | Out-Null
}

# ------------------------------------------------- Главная процедура установки (UI-поток) ---
function Start-FullInstall {
  $which = if ($Script:RbLow.IsChecked) { 'Low' } else { 'High' }
  $Script:BtnInstall.IsEnabled = $false
  $Script:Bar.IsIndeterminate = $false
  try { $Script:Bar.Foreground = $Script:Window.FindResource('B_Accent') } catch {}
  try {
    if (-not (Test-IsAdmin)) {
      $r = [Windows.MessageBox]::Show($(T AdminMsg), $(T AdminTitle), 'YesNo', 'Warning')
      if ($r -eq 'Yes') {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $me = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        $psi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$me`""
        $psi.Verb = 'runas'
        [Diagnostics.Process]::Start($psi) | Out-Null
      }
      Write-Log $(T AdminLog) 'WARN'
      $Script:LblStatus.Text = T AdminStatus
      return
    }

    $Script:Bar.Value = 5
    $Script:LblStatus.Text = T StDetect
    Write-Log $(T StartLog)
    $latest = Get-LatestMpvSetupUrl
    Write-Log ("Latest mpv.net: {0} / {1}" -f $latest.Tag, $latest.Name)
    $mpv = Get-MpvNetStatus

    # --- mpv.net ---
    $needMpv = -not $mpv.Installed
    if ($mpv.Installed) {
      Write-Log ($(T MpvHas) -f $mpv.Version, $mpv.Exe)
      $needMpv = $true  # системный setup идемпотентен — прогоняем для гарантии нужной версии
    }
    if ($needMpv) {
      $Script:LblStatus.Text = T StDetect
      $Script:Bar.Value = 10
      $setup = Join-Path $env:TEMP $latest.Name
      Invoke-DownloadFile -Url $latest.Url -Dest $setup -Bar $Script:Bar -StatusLabel $Script:LblStatus -BarMin 10 -BarMax 40
      $Script:LblStatus.Text = T StInstMpv
      $Script:Bar.Value = 45
      $Script:Bar.IsIndeterminate = $true
      Install-MpvNetSetup -SetupExe $setup -UseDispatcher $true
      try { Remove-Item $setup -Force -ErrorAction SilentlyContinue } catch {}
      $Script:Bar.IsIndeterminate = $false
      $Script:Bar.Value = 55
    }

    # --- .NET ---
    $dn = Get-DotnetStatus
    if (-not $dn.Installed) {
      $Script:LblStatus.Text = T StDlNet
      $Script:Bar.Value = 60
      $nd = Join-Path $env:TEMP 'windowsdesktop-runtime-10.0.13-win-x64.exe'
      Invoke-DownloadFile -Url $Script:Cfg.DotnetUrl -Dest $nd -Bar $Script:Bar -StatusLabel $Script:LblStatus -BarMin 60 -BarMax 70
      $Script:LblStatus.Text = T StInstNet
      $Script:Bar.IsIndeterminate = $true
      Install-DotnetRuntime -InstallerExe $nd -UseDispatcher $true
      try { Remove-Item $nd -Force -ErrorAction SilentlyContinue } catch {}
      $Script:Bar.IsIndeterminate = $false
      $Script:Bar.Value = 75
    } else {
      Write-Log ($(T NetHas) -f $dn.Detail)
    }

    # --- Anime4K пресет ---
    $prev = Get-AnimePresetStatus
    Write-Log ($(T PstLog) -f (Get-PresetStateText $prev))
    $Script:LblStatus.Text = $(T StPreset) -f $which
    $Script:Bar.Value = 80
    Install-AnimePreset -Which $which -BarMin 80 -BarMax 93
    $Script:Bar.Value = 95

    Update-StatusUI
    $Script:Bar.Value = 100
    try { $Script:Bar.Foreground = $Script:Window.FindResource('B_Success') } catch {}
    $Script:LblStatus.Text = $(T StDone) -f $which, $Script:Cfg.ConfigDir
    Write-Log $(T DoneLog)
    [Windows.MessageBox]::Show(($(T DoneMsg) -f $which, $Script:Cfg.ConfigDir),
      $(T DoneTitle), 'OK', 'Information') | Out-Null
  } catch {
    $msg = $_.Exception.Message
    Write-Log $msg 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    $Script:LblStatus.Text = $(T ErrStatus) -f $msg
    $Script:Bar.IsIndeterminate = $false
    try { $Script:Bar.Foreground = $Script:Window.FindResource('B_Error') } catch {}
    [Windows.MessageBox]::Show(($(T ErrMsg) -f $msg, $Script:Cfg.LogFile),
      $(T ErrTitle), 'OK', 'Error') | Out-Null
  } finally {
    $Script:Bar.IsIndeterminate = $false
    $Script:BtnInstall.IsEnabled = $true
  }
}

# ------------------------------------------------- Silent-режим ---
function Start-SilentInstall {
  if (-not (Test-IsAdmin)) { throw $(T SneedAdmin) }
  Write-Host $(T S1)
  $latest = Get-LatestMpvSetupUrl
  $setup = Join-Path $env:TEMP $latest.Name
  Invoke-WebRequest -Uri $latest.Url -OutFile $setup -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -UseBasicParsing
  Install-MpvNetSetup -SetupExe $setup -UseDispatcher $false
  Remove-Item $setup -Force -ErrorAction SilentlyContinue
  Write-Host $(T S2)
  $dn = Get-DotnetStatus
  if (-not $dn.Installed) {
    $nd = Join-Path $env:TEMP 'windowsdesktop-runtime-10.0.13-win-x64.exe'
    Invoke-WebRequest -Uri $Script:Cfg.DotnetUrl -OutFile $nd -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -UseBasicParsing
    Install-DotnetRuntime -InstallerExe $nd -UseDispatcher $false
    Remove-Item $nd -Force -ErrorAction SilentlyContinue
  } else { Write-Host ($(T S2has) -f $dn.Detail) }
  Write-Host ($(T S3) -f $Preset)
  Install-AnimePreset -Which $Preset
  Write-Host ($(T Sdone) -f $Script:Cfg.ConfigDir)
}

# ------------------------------------------------- Точка входа ---
if ($Silent) {
  Start-SilentInstall
  return
}

# WPF требует STA
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Write-Host 'Перезапуск в STA-режиме для WPF…'
  $me = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
  & powershell.exe -ExecutionPolicy Bypass -STA -File "$me" -Preset $Preset
  return
}

$Script:Window = New-WpfWindow $Script:MainXaml
# Размер окна подобран так, чтобы весь контент (включая раскрытый лог) был виден
# без прокрутки. На маленьких экранах не даём окну вылезти за рабочую область —
# тогда остаётся обычное поведение со скроллом.
$wa = [Windows.SystemParameters]::WorkArea
if ($Script:Window.Height -gt ($wa.Height - 8)) {
  $Script:Window.Height = [Math]::Max($Script:Window.MinHeight, $wa.Height - 8)
}
if ($Script:Window.Width -gt ($wa.Width - 8)) {
  $Script:Window.Width = [Math]::Max($Script:Window.MinWidth, $wa.Width - 8)
}
$Script:LblMpv    = $Script:Window.FindName('lblMpvStatus')
$Script:LblDot    = $Script:Window.FindName('lblDotStatus')
$Script:DotMpv    = $Script:Window.FindName('dotMpv')
$Script:DotNet    = $Script:Window.FindName('dotNet')
$Script:LblPreset = $Script:Window.FindName('lblPresetStatus')
$Script:DotPreset = $Script:Window.FindName('dotPreset')
$Script:RbLow     = $Script:Window.FindName('rbLow')
$Script:RbHigh    = $Script:Window.FindName('rbHigh')
$Script:BtnInstall = $Script:Window.FindName('btnInstall')
$Script:Bar       = $Script:Window.FindName('progressBar')
$Script:LblStatus = $Script:Window.FindName('txtStatus')
$Script:TxtLog    = $Script:Window.FindName('txtLog')

if ($Preset -eq 'Low') { $Script:RbLow.IsChecked = $true } else { $Script:RbHigh.IsChecked = $true }

$Script:Window.FindName('btnRecheck').Add_Click({ Update-StatusUI })
$Script:Window.FindName('btnLang').Add_Click({
  if ($Script:Lang -eq 'RU') { Set-Language 'EN' } else { Set-Language 'RU' }
})
$Script:BtnInstall.Add_Click({ Start-FullInstall })
$Script:Window.FindName('btnAdvanced').Add_Click({ Show-AdvancedWindow })
$Script:Window.FindName('btnAbout').Add_Click({ Show-AboutWindow })
$Script:Window.FindName('btnOpenConfig').Add_Click({
  $d = $Script:Cfg.ConfigDir
  if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
  Start-Process explorer.exe $d
})

Write-Log $(T OpenLog)
Set-Language 'RU'
# HWND готов только здесь; вызов раньше вернёт Zero и Mica не применится
$Script:Window.Add_SourceInitialized({ [void](Enable-FluentChrome $Script:Window) })
[void]$Script:Window.ShowDialog()
