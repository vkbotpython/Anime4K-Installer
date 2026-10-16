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
  - UI: WPF dark, два языка (RU/EN, кнопка в шапке), Quick Usage в главном окне,
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
  AnimeTag         = 'v4.0.1'
  AnimeLowUrl      = 'https://github.com/Tama47/Anime4K/releases/download/v4.0.1/GLSL_Windows_Low-end.zip'
  AnimeHighUrl     = 'https://github.com/Tama47/Anime4K/releases/download/v4.0.1/GLSL_Windows_High-end.zip'
  ConfigDir        = (Join-Path $env:APPDATA 'mpv.net')
  LogFile          = (Join-Path $env:TEMP 'Anime4K-Install.log')
}
$Script:Lang = 'RU'

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
  try { Add-Content -Path $Script:Cfg.LogFile -Value $line -Encoding UTF8 } catch {}
  if ($Script:TxtLog) {
    try {
      $Script:TxtLog.Dispatcher.Invoke([action]{
        $Script:TxtLog.AppendText($line + "`r`n")
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
  # 3) реестр dotnet
  try {
    $r = Get-ItemProperty 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App' -ErrorAction SilentlyContinue
    if ($r -and $r.Version -like "$want*") { $res.Installed = $true; $res.Detail = $r.Version; return $res }
  } catch {}
  return $res
}

# ------------------------------------------------- Download (с прогрессом, UI жив) ---
function Invoke-DownloadFile {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Dest,
    $Bar = $null,       # System.Windows.Controls.ProgressBar
    $StatusLabel = $null
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
            $Bar.Dispatcher.Invoke([action]{ $Bar.Value = $pct })
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
  param([ValidateSet('Low','High')][string]$Which)
  $dest = $Script:Cfg.ConfigDir
  if (-not (Test-Path $dest)) { New-Item $dest -ItemType Directory -Force | Out-Null }
  # shaders подпапка (архивы Tama47 уже содержат shaders/, но гарантируем наличие)
  $shDir = Join-Path $dest 'shaders'
  if (-not (Test-Path $shDir)) { New-Item $shDir -ItemType Directory -Force | Out-Null }

  $url = if ($Which -eq 'Low') { $Script:Cfg.AnimeLowUrl } else { $Script:Cfg.AnimeHighUrl }
  $zip = Join-Path $env:TEMP ("Anime4K_" + $Which + ".zip")
  if ($Script:Bar -and $Script:LblStatus) {
    Invoke-DownloadFile -Url $url -Dest $zip -Bar $Script:Bar -StatusLabel $Script:LblStatus
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
        Title="mpv.net + Anime4K — Установщик" Height="880" Width="980"
        MinHeight="820" MinWidth="900" WindowStartupLocation="CenterScreen"
        Background="#202020" Foreground="#E6E6E6" FontFamily="Segoe UI Variable, Segoe UI" FontSize="14">
  <Window.Resources>
    <!-- Токены: только Brush (Color->Brush через StaticResource падает) -->
    <SolidColorBrush x:Key="B_Card" Color="#2B2B2B"/>
    <SolidColorBrush x:Key="B_CardHover" Color="#323232"/>
    <SolidColorBrush x:Key="B_Subtle" Color="#2D2D2D"/>
    <SolidColorBrush x:Key="B_Pressed" Color="#262626"/>
    <SolidColorBrush x:Key="B_Log" Color="#101010"/>
    <SolidColorBrush x:Key="B_LogText" Color="#D6D6D6"/>
    <SolidColorBrush x:Key="B_Border" Color="#333333"/>
    <SolidColorBrush x:Key="B_BorderStrong" Color="#454545"/>
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
    <!-- Вариант A: TextBox оставляем (без смены логики Write-Log), монохром + префиксы -->
    <Style x:Key="LogBox" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource B_Log}"/>
      <Setter Property="Foreground" Value="{StaticResource B_LogText}"/>
      <Setter Property="FontFamily" Value="{StaticResource F_Mono}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderBrush" Value="{StaticResource B_Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10"/>
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
      <Expander x:Name="expLog" Header="Логи" Foreground="#C7C7C7" Margin="0,8,0,0" IsExpanded="False">
        <TextBox x:Name="txtLog" Style="{StaticResource LogBox}" Height="130" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap" AcceptsReturn="True"/>
      </Expander>

      <!-- Quick Usage -->
      <Border Style="{StaticResource Card}" Margin="0,12,0,12" BorderBrush="#7AA2F7">
        <StackPanel>
          <TextBlock x:Name="txtQuickTitle" Text="Quick Usage — как пользоваться Anime4K" FontWeight="Bold" FontSize="15" Margin="0,0,0,6"/>
          <TextBlock x:Name="txtQuickSub" Style="{StaticResource Muted}" Text="Mode A включён автоматически (так задано в mpv.conf из шаблона). Вручную:"/>
          <TextBlock Margin="0,6,0,0" TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+1"/> — <Run x:Name="runModeA" Text="Mode A (оптимально для 1080p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+2"/> — <Run x:Name="runModeB" Text="Mode B (оптимально для 720p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#60CDFF" FontWeight="Bold" Text="Ctrl+3"/> — <Run x:Name="runModeC" Text="Mode C (оптимально для 480p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#FF99A4" FontWeight="Bold" Text="Ctrl+0"/> — <Run x:Name="runModeOff" Text="сбросить шейдеры (выключить Anime4K)"/></TextBlock>
        </StackPanel>
      </Border>

      <!-- Footer -->
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
        <Button x:Name="btnAdvanced" Content="📖 Подробная инструкция" Background="#31364A" Foreground="White"/>
        <Button x:Name="btnOpenConfig" Content="📁 Открыть папку конфига" Margin="0,0,0,0"/>
      </StackPanel>
      <TextBlock x:Name="txtFooter" Style="{StaticResource Muted}" Margin="0,10,0,0" Text="Источники: github.com/mpvnet-player/mpv.net • builds.dotnet.microsoft.com • github.com/Tama47/Anime4K (v4.0.1) • github.com/bloc97/Anime4K (доки). Конфиги: %APPDATA%\mpv.net"/>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

# ------------------------------------------------- XAML: Advanced окно (RU) ---
$Script:AdvancedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Подробная инструкция — Anime4K GLSL / MPV v4.x" Height="700" Width="880"
        MinHeight="560" MinWidth="720" WindowStartupLocation="CenterScreen"
        Background="#16181D" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5">
  <Grid Margin="0">
    <FlowDocumentScrollViewer VerticalScrollBarVisibility="Auto" Padding="24">
      <FlowDocument Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5" PagePadding="0">
        <Paragraph Margin="0,0,0,4">
          <Run FontSize="22" FontWeight="Bold" Text="Подробная инструкция "/>
          <Run FontSize="13" Foreground="#9AA0AE" Text="(GLSL / MPV, v4.x)"/>
        </Paragraph>
        <Paragraph Foreground="#9AA0AE" Margin="0,0,0,12">
          <Run Text="Порядок шейдеров и значения по умолчанию — как в mpv.conf из архива пресета. Ниже — что означают режимы и как собрать свой пайплайн."/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="1. Режимы: A, B, C и вторичные"/></Paragraph>
        <Paragraph><Run Text="Маленькие CNN не могут одинаково хорошо чинить все типы деградаций, поэтому выбор режима — за вами. Проще всего прогнать A → B → C глазами: обычно правильный тот, что выглядит лучше. Режим A при неправильном использовании даёт самые заметные артефакты, B и C на низком разрешении различить сложнее. Для роста перцептуального качества используйте вторичный режим (вторая строка таблицы)."/></Paragraph>
        <Paragraph Foreground="#9AA0AE"><Run Text="Соответствие: A → A+A,  B → B+B,  C → C+A. Вторичные режимы — только при апскейле ×2 и выше (на экране 1080p режим A+A поверх 1080p-видео чаще перешарпит картинку)."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#2C313C" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns>
            <TableColumn Width="70"/><TableColumn Width="190"/><TableColumn Width="220"/><TableColumn Width="220"/>
          </Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2A2E3A" FontWeight="Bold">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Режим"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Для чего"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Плюсы"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,1,1,1" Padding="8"><Paragraph><Run Text="Минусы при неверном выборе"/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Большинство 1080p, часть старых 720p/SD. Много блюра, ресемплинг, смазы компрессии."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Высокое перцептуальное качество, чинит линии, убирает блюр/шум/компрессию."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Может усилить рингинг/бэндинг, сгладить текстуры сильным денойзом."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#1B1E26">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="B"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Часть 1080p, большинство 720p, 1080p→720p. Мало блюра, рингинг от даунскейла."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Чинит линии, режет шум/блюр/рингинг/алиасинг."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Часть артефактов может остаться, линии — мягкими."/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="C"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="1080p→480p, редко 1080p-мувики, чистые арты/обои/Pixiv."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Самый высокий PSNR, денойз."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Низкое перцептуальное качество, может усилить рингинг."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#1B1E26">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#E5C07B" Text="A+A / B+B / C+A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Те же случаи, что у первичного режима. Максимальное качество."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Почти все линии восстановлены (A+A — топ)."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,0" Padding="8"><Paragraph><Run Text="Медленнее; A+A может дать сильный рингинг/бэндинг/алиасинг."/></Paragraph></TableCell>
            </TableRow>
          </TableRowGroup>
        </Table>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="2. Горячие клавиши (из input.conf шаблона)"/></Paragraph>
        <Paragraph FontFamily="Consolas" Background="#0F1116" Padding="10" Foreground="#C9D1D9">
          <Run Text="CTRL+1  → Mode A (1080p)  |  CTRL+2  → Mode B (720p)  |  CTRL+3  → Mode C (480p)  |  CTRL+0  → выключить шейдеры"/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="3. Из чего состоит пайплайн"/></Paragraph>
        <Paragraph><Run Text="Базовые цепочки (Clamp_Highlights и AutoDownscalePre опущены для краткости): A = Restore → Upscale → Upscale; B = Restore_Soft → Upscale → Upscale; C = Upscale_Denoise → Upscale; A+A = Restore → Upscale → Restore → Upscale; B+B = Restore_Soft → Upscale → Restore_Soft → Upscale; C+A = Upscale_Denoise → Restore → Upscale."/></Paragraph>
        <Paragraph><Run Text="Правила: каждый .glsl-файл можно использовать только один раз (дубли — копируйте и переименовывайте); порядок обработки = порядок в input.conf (кроме Clamp_Highlights — он замеряет статистику в точке вставки, а клампит в конце); вариант CNN S/M/L/VL/UL — каждая ступень ×2 ко времени (M 5мс → L ~10мс → VL ~20мс); не-CNN шейдеры быстрее, но слабее."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#2C313C" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns><TableColumn Width="190"/><TableColumn Width="510"/></Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2A2E3A" FontWeight="Bold">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Тип шейдера"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Эффект"/></Paragraph></TableCell>
            </TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Restore / Restore_Soft"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Главная фишка Anime4K. Чинит картинку ДО апскейла: компрессия, блюр, рингинг. Restore — против апскейл-артефактов и блюра, Soft — против даунскейла и алиасинга."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#1B1E26"><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Upscale / Upscale_Denoise"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Апскейл ×2. Denoise-версия чистит шум без потери скорости. Режим без Restore обязан начинаться с Upscale_Denoise/Denoise (компрессия почти всегда lossy)."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Clamp_Highlights"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Ставьте в начало: запоминает статистику и в конце режет выбросы — меньше рингинга. Снятие даёт чуть больше скорости."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#1B1E26"><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Darken / Thin / Denoise / Deblur"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Затемнение/утоньшение линий (на вкус), денойз, деблюр без овершута."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="6"><Paragraph><Run Text="AutoDownscalePre_x4 / _x2"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,0" Padding="6"><Paragraph><Run Text="Уменьшают картинку между апскейлами под размер экрана — быстрее без потери качества. _x4 — между двумя Upscale, _x2 — после первого Upscale."/></Paragraph></TableCell></TableRow>
          </TableRowGroup>
        </Table>
        <Paragraph Foreground="#9AA0AE"><Run Text="Как читать составные режимы (пример C+A+B): 1) C(Upscale)→A(Restore→Upscale)→B(Restore_Soft→Upscale); 2) раз нет Restore в начале — C становится Upscale_Denoise; 3) итог: Upscale_Denoise → Restore → Upscale → Restore_Soft → Upscale. Все режимы добивают апскейл до ~×4 (480p→4K ≈ ×4.5)."/></Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="4. Best practices и производительность"/></Paragraph>
        <Paragraph><Run Text="• Clamp_Highlights в начале почти всегда полезен. • Restore после апскейла = лучше перцептуально, но медленнее и возможны артефакты. • Шейдер после ×2-апскейла стоит ×4 времени: если до апскейла 10мс — после будет ~40мс; лечится вариантом на 2 ступени ниже (L→S). • На высоких разрешениях артефакты S/M-вариантов почти не видны — так можно снизить шум/нагрев GPU."/></Paragraph>
        <Paragraph><Run Text="Ориентир — уложиться в кадр: 24fps → 41мс, 30fps → 33мс, 60fps → 16мс. Проверка: профайлер mpv — Shift+I, затем 2 (верхний ряд). Если есть дропы — спускайтесь по вариантам CNN."/></Paragraph>
        <Paragraph Foreground="#9AA0AE"><Run Text="Файлы лежат в %APPDATA%\mpv.net (mpv.conf, input.conf, shaders\). Открыть папку можно кнопкой в главном окне."/></Paragraph>
      </FlowDocument>
    </FlowDocumentScrollViewer>
  </Grid>
</Window>
'@

# ------------------------------------------------- XAML: Advanced окно (EN) ---
$Script:AdvancedXamlEn = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Advanced Usage Instructions — Anime4K GLSL / MPV v4.x" Height="700" Width="880"
        MinHeight="560" MinWidth="720" WindowStartupLocation="CenterScreen"
        Background="#16181D" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5">
  <Grid Margin="0">
    <FlowDocumentScrollViewer VerticalScrollBarVisibility="Auto" Padding="24">
      <FlowDocument Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5" PagePadding="0">
        <Paragraph Margin="0,0,0,4">
          <Run FontSize="22" FontWeight="Bold" Text="Advanced Usage Instructions "/>
          <Run FontSize="13" Foreground="#9AA0AE" Text="(GLSL / MPV, v4.x)"/>
        </Paragraph>
        <Paragraph Foreground="#9AA0AE" Margin="0,0,0,12">
          <Run Text="Shader order and defaults come from mpv.conf inside the preset archive. Below: what the modes mean and how to build your own pipeline."/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="1. Modes: A, B, C and secondary modes"/></Paragraph>
        <Paragraph><Run Text="Small CNNs cannot fix every type of degradation, so the mode choice is yours. The easiest way is to eyeball A → B → C: usually the correct mode is the one that looks best. Mode A shows the most visible artifacts of the three when used incorrectly; B and C can be harder to tell apart on low-resolution anime. For higher perceptual quality, use the corresponding secondary mode (second row of the table)."/></Paragraph>
        <Paragraph Foreground="#9AA0AE"><Run Text="Mapping: A → A+A,  B → B+B,  C → C+A. Secondary modes only make sense at upscale ratios of x2 or higher (on a 1080p screen, A+A over 1080p video will most likely oversharpen the image)."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#2C313C" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns>
            <TableColumn Width="70"/><TableColumn Width="190"/><TableColumn Width="220"/><TableColumn Width="220"/>
          </Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2A2E3A" FontWeight="Bold">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Mode"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Optimized for"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Pros"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,1,1,1" Padding="8"><Paragraph><Run Text="Cons if misused"/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Most 1080p, some old 720p/SD. Heavy blur, resampling artifacts, compression smearing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="High perceptual quality, restores lines, removes blur/noise/compression."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="May amplify ringing/banding, strong denoise may blur textures."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#1B1E26">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="B"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Some 1080p, most 720p, 1080p→720p. Little blur, downsampling ringing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Restores lines, cuts noise/blur/ringing/aliasing."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Some artifacts may remain, lines may stay soft."/></Paragraph></TableCell>
            </TableRow>
            <TableRow>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#7AA2F7" Text="C"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="1080p→480p, rarely 1080p movies, clean art/wallpapers/Pixiv."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Highest PSNR, denoise."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Low perceptual quality, may amplify ringing."/></Paragraph></TableCell>
            </TableRow>
            <TableRow Background="#1B1E26">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run FontWeight="Bold" Foreground="#E5C07B" Text="A+A / B+B / C+A"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Same cases as the primary mode. Maximum quality."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="8"><Paragraph><Run Text="Almost all lines restored (A+A is the best)."/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,0" Padding="8"><Paragraph><Run Text="Slower; A+A may cause strong ringing/banding/aliasing."/></Paragraph></TableCell>
            </TableRow>
          </TableRowGroup>
        </Table>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="2. Hotkeys (from the template input.conf)"/></Paragraph>
        <Paragraph FontFamily="Consolas" Background="#0F1116" Padding="10" Foreground="#C9D1D9">
          <Run Text="CTRL+1  → Mode A (1080p)  |  CTRL+2  → Mode B (720p)  |  CTRL+3  → Mode C (480p)  |  CTRL+0  → clear shaders"/>
        </Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="3. What the pipeline is made of"/></Paragraph>
        <Paragraph><Run Text="Base chains (Clamp_Highlights and AutoDownscalePre omitted for clarity): A = Restore → Upscale → Upscale; B = Restore_Soft → Upscale → Upscale; C = Upscale_Denoise → Upscale; A+A = Restore → Upscale → Restore → Upscale; B+B = Restore_Soft → Upscale → Restore_Soft → Upscale; C+A = Upscale_Denoise → Restore → Upscale."/></Paragraph>
        <Paragraph><Run Text="Rules: each .glsl file may be used only once (for duplicates, copy and rename); processing order = order in input.conf (except Clamp_Highlights — it measures stats at its position but clamps at the end); CNN variant S/M/L/VL/UL — each step is ~x2 time (M 5ms → L ~10ms → VL ~20ms); non-CNN shaders are faster but weaker."/></Paragraph>

        <Table CellSpacing="0" BorderBrush="#2C313C" BorderThickness="1" Margin="0,8,0,8">
          <Table.Columns><TableColumn Width="190"/><TableColumn Width="510"/></Table.Columns>
          <TableRowGroup>
            <TableRow Background="#2A2E3A" FontWeight="Bold">
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="8"><Paragraph><Run Text="Shader type"/></Paragraph></TableCell>
              <TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="8"><Paragraph><Run Text="Effect"/></Paragraph></TableCell>
            </TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Restore / Restore_Soft"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="What makes Anime4K special. Fixes the image BEFORE upscaling: compression, blur, ringing. Restore targets upscale artifacts and blur, Soft targets downscale artifacts and aliasing."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#1B1E26"><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Upscale / Upscale_Denoise"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="x2 upscale. The Denoise variant cleans noise at no speed cost. A mode without Restore must start with Upscale_Denoise/Denoise (compression is almost always lossy)."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Clamp_Highlights"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Put it first: it records stats and clamps overshoot at the end — less ringing. Removing it is slightly faster."/></Paragraph></TableCell></TableRow>
            <TableRow Background="#1B1E26"><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,1" Padding="6"><Paragraph><Run Text="Darken / Thin / Denoise / Deblur"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,1" Padding="6"><Paragraph><Run Text="Line darkening/thinning (to taste), denoise, overshoot-free deblur."/></Paragraph></TableCell></TableRow>
            <TableRow><TableCell BorderBrush="#2C313C" BorderThickness="0,0,1,0" Padding="6"><Paragraph><Run Text="AutoDownscalePre_x4 / _x2"/></Paragraph></TableCell><TableCell BorderBrush="#2C313C" BorderThickness="0,0,0,0" Padding="6"><Paragraph><Run Text="Downscale between upscales to screen size — faster with no visible quality loss. _x4 goes between two Upscales, _x2 goes after the first Upscale."/></Paragraph></TableCell></TableRow>
          </TableRowGroup>
        </Table>
        <Paragraph Foreground="#9AA0AE"><Run Text="How to read combined modes (example C+A+B): 1) C(Upscale)→A(Restore→Upscale)→B(Restore_Soft→Upscale); 2) no Restore at the start, so C becomes Upscale_Denoise; 3) result: Upscale_Denoise → Restore → Upscale → Restore_Soft → Upscale. All modes upscale to ~x4 total (480p→4K is ~x4.5)."/></Paragraph>

        <Paragraph Margin="0,12,0,4"><Run FontSize="16" FontWeight="Bold" Foreground="#7AA2F7" Text="4. Best practices and performance"/></Paragraph>
        <Paragraph><Run Text="• Clamp_Highlights first is almost always worth it. • Restore after upscale = better perceptually, but slower and may add artifacts. • A shader after a x2 upscale costs x4 time: 10ms before upscale becomes ~40ms after; fix it with a variant two steps smaller (L→S). • At high resolutions S/M-variant artifacts are barely visible — use them to cut GPU noise/heat."/></Paragraph>
        <Paragraph><Run Text="Budget per frame: 24fps → 41ms, 30fps → 33ms, 60fps → 16ms. Check with the mpv profiler — Shift+I, then 2 (top row). If frames drop, step down the CNN variants."/></Paragraph>
        <Paragraph Foreground="#9AA0AE"><Run Text="Files live in %APPDATA%\mpv.net (mpv.conf, input.conf, shaders\). Open the folder with the button in the main window."/></Paragraph>
      </FlowDocument>
    </FlowDocumentScrollViewer>
  </Grid>
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
    AdvBtn      = '📖 Подробная инструкция'
    OpenCfg     = '📁 Открыть папку конфига'
    Footer      = 'Источники: github.com/mpvnet-player/mpv.net • builds.dotnet.microsoft.com • github.com/Tama47/Anime4K (v4.0.1) • github.com/bloc97/Anime4K (доки). Конфиги: %APPDATA%\mpv.net'
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
    StDone      = 'Готово. Пресет {0} в {1}. Ctrl+1/2/3 — режимы, Ctrl+0 — выкл.'
    DlProgress  = 'Скачивание…'
    DoneTitle   = 'Anime4K установлен'
    DoneMsg     = "Готово!`n`nmpv.net установлен системно, .NET 10.0.13 проверен,`nпресет Anime4K ({0}) распакован в:`n{1}`n`nПорядок шейдеров — из mpv.conf архива.`nCtrl+1/2/3 — режимы A/B/C, Ctrl+0 — выключить."
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
    AdvBtn      = '📖 Detailed guide'
    OpenCfg     = '📁 Open config folder'
    Footer      = 'Sources: github.com/mpvnet-player/mpv.net • builds.dotnet.microsoft.com • github.com/Tama47/Anime4K (v4.0.1) • github.com/bloc97/Anime4K (docs). Configs: %APPDATA%\mpv.net'
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
    StDone      = 'Done. Preset {0} in {1}. Ctrl+1/2/3 — modes, Ctrl+0 — off.'
    DlProgress  = 'Downloading…'
    DoneTitle   = 'Anime4K installed'
    DoneMsg     = "Done!`n`nmpv.net installed system-wide, .NET 10.0.13 checked,`nAnime4K preset ({0}) extracted to:`n{1}`n`nShader order — from the archive mpv.conf.`nCtrl+1/2/3 — modes A/B/C, Ctrl+0 — off."
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
  $w.FindName('btnAdvanced').Content   = T AdvBtn
  $w.FindName('btnOpenConfig').Content = T OpenCfg
  $w.FindName('txtFooter').Text      = T Footer
  $Script:LblStatus.Text = T Ready
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
if (-not ('Win.DwmNative' -as [type])) {
  Add-Type -Namespace Win -Name DwmNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
}
function Enable-FluentChrome {
  param($win)
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $win).Handle
    if ($h -eq [IntPtr]::Zero) { return $false } # ещё нет HWND — вызовет SourceInitialized
    $dark = 1; [void][Win.DwmNative]::DwmSetWindowAttribute($h, 20, [ref]$dark, 4)
    # Mica (38) на WPF с Transparent на части сборок даёт чисто чёрный клиент вместо текстуры,
    # поэтому клиент оставляем сплошным #202020 — тёмный titlebar уже даёт Fluent-вид.
    # Не раскомментировать без проверки на 22621+: $mica=2; DwmSetWindowAttribute(h,38)+Transparent.
    return $true
  } catch { return $false }
}

function Update-StatusUI {
  $mpv = Get-MpvNetStatus
  $dn = Get-DotnetStatus
  # Токены B_Success/B_Error вместо LightGreen/Tomato — иначе выбиваются из палитры
  $ok = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#6CCB5F'))
  $bad = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FF99A4'))
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
  try {
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
      [action]{}, [Windows.Threading.DispatcherPriority]::Background)
  } catch {}
}

function Show-AdvancedWindow {
  $x = if ($Script:Lang -eq 'EN') { $Script:AdvancedXamlEn } else { $Script:AdvancedXaml }
  $w = New-WpfWindow $x
  try { $w.Owner = $Script:Window } catch {}
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
      Invoke-DownloadFile -Url $latest.Url -Dest $setup -Bar $Script:Bar -StatusLabel $Script:LblStatus
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
      Invoke-DownloadFile -Url $Script:Cfg.DotnetUrl -Dest $nd -Bar $Script:Bar -StatusLabel $Script:LblStatus
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
    $Script:LblStatus.Text = $(T StPreset) -f $which
    $Script:Bar.Value = 80
    Install-AnimePreset -Which $which
    $Script:Bar.Value = 95

    Update-StatusUI
    $Script:Bar.Value = 100
    try { $Script:Bar.Foreground = $Script:Window.FindResource('B_Success') } catch {}
    $Script:LblStatus.Text = $(T StDone) -f $which, $Script:Cfg.ConfigDir
    Write-Log $(T DoneLog)
    [Windows.MessageBox]::Show($(T DoneMsg) -f $which, $Script:Cfg.ConfigDir,
      $(T DoneTitle), 'OK', 'Information') | Out-Null
  } catch {
    $msg = $_.Exception.Message
    Write-Log $msg 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    $Script:LblStatus.Text = $(T ErrStatus) -f $msg
    $Script:Bar.IsIndeterminate = $false
    try { $Script:Bar.Foreground = $Script:Window.FindResource('B_Error') } catch {}
    [Windows.MessageBox]::Show($(T ErrMsg) -f $msg, $Script:Cfg.LogFile,
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
$Script:LblMpv    = $Script:Window.FindName('lblMpvStatus')
$Script:LblDot    = $Script:Window.FindName('lblDotStatus')
$Script:DotMpv    = $Script:Window.FindName('dotMpv')
$Script:DotNet    = $Script:Window.FindName('dotNet')
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
