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
  - UI: WPF dark, Quick Usage в главном окне, кнопка Advanced открывает
    стилизованный русскоязычный гайд.
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
    $hit = $out | Select-String -Pattern ([regex]::Escape('Microsoft.WindowsDesktop.App ' + $want)) -SimpleMatch:$false |
      Select-Object -First 1
    # проще: ищем строку с нужной версией
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
              $mb = '{0:N1} / {1:N1} МБ ({2}%)' -f ($got/1MB), ($total/1MB), $pct
              $StatusLabel.Dispatcher.Invoke([action]{ $StatusLabel.Text = "Скачивание… $mb" })
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
        Title="mpv.net + Anime4K — Установщик" Height="740" Width="930"
        MinHeight="680" MinWidth="860" WindowStartupLocation="CenterScreen"
        Background="#16181D" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="14">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1F222B"/>
      <Setter Property="BorderBrush" Value="#2C313C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AA0AE"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2E3A"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#3A4050"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
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
          <TextBlock Style="{StaticResource Muted}" Text="Системная установка • .NET 10 Desktop Runtime • GLSL-пресеты v4.0.1"/>
        </StackPanel>
        <Button x:Name="btnRecheck" Grid.Column="1" Content="⟳ Проверить снова" VerticalAlignment="Center"/>
      </Grid>

      <!-- Step 1: статус -->
      <TextBlock Style="{StaticResource H2}" Text="Шаг 1 — Проверка компонентов"/>
      <UniformGrid Columns="2">
        <Border Style="{StaticResource Card}" Margin="0,0,6,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="dotMpv" Width="12" Height="12" Fill="#8A8F9C" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock Text="mpv.net (системно)" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="lblMpvStatus" Style="{StaticResource Muted}" Text="Проверка…" Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="Установщик: *-setup-x64.exe, ключи /VERYSILENT /ALLUSERS"/>
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
      <TextBlock Style="{StaticResource H2}" Text="Шаг 2 — Пресет Anime4K (папка %APPDATA%\mpv.net, перезапись молча)"/>
      <UniformGrid Columns="2">
        <Border Style="{StaticResource Card}" Margin="0,0,6,12">
          <StackPanel>
            <RadioButton x:Name="rbLow" Content="Low-end GPU" FontWeight="SemiBold" Foreground="#E6E6E6" GroupName="Preset"/>
            <TextBlock Style="{StaticResource Muted}" Text="GTX 980, GTX 1060, RX 570. Быстрые шейдеры, меньше нагрузка." Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="GLSL_Windows_Low-end.zip (Tama47 v4.0.1)"/>
          </StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="6,0,0,12">
          <StackPanel>
            <RadioButton x:Name="rbHigh" Content="High-end GPU" FontWeight="SemiBold" Foreground="#E6E6E6" GroupName="Preset" IsChecked="True"/>
            <TextBlock Style="{StaticResource Muted}" Text="GTX 1080, RTX 2070/3060, RX 590, Vega 56, 5700XT, 6600XT." Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource Muted}" Text="GLSL_Windows_High-end.zip (Tama47 v4.0.1)"/>
          </StackPanel>
        </Border>
      </UniformGrid>
      <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,12" Text="Порядок и приоритет шейдеров берутся из mpv.conf внутри архива — скрипт их не переписывает, только копирует файлы с перезаписью."/>

      <!-- Step 3: установка -->
      <TextBlock Style="{StaticResource H2}" Text="Шаг 3 — Установка"/>
      <Button x:Name="btnInstall" Content="⬇ Установить / Обновить всё" Height="46" FontSize="15" FontWeight="SemiBold"
              Background="#7AA2F7" Foreground="#0B0E14" BorderThickness="0"/>
      <ProgressBar x:Name="progressBar" Height="10" Margin="0,10,0,6" Minimum="0" Maximum="100" Value="0"/>
      <TextBlock x:Name="txtStatus" Style="{StaticResource Muted}" Text="Готов. Выберите пресет и нажмите «Установить»."/>
      <Expander Header="Логи" Foreground="#9AA0AE" Margin="0,8,0,0" IsExpanded="False">
        <TextBox x:Name="txtLog" Height="130" Background="#0F1116" Foreground="#C9D1D9"
                 FontFamily="Consolas" FontSize="12" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap" AcceptsReturn="True"/>
      </Expander>

      <!-- Quick Usage -->
      <Border Style="{StaticResource Card}" Margin="0,12,0,12" BorderBrush="#7AA2F7">
        <StackPanel>
          <TextBlock Text="Quick Usage — как пользоваться Anime4K" FontWeight="Bold" FontSize="15" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Muted}" Text="Mode A включён автоматически (так задано в mpv.conf из шаблона). Вручную:"/>
          <TextBlock Margin="0,6,0,0" TextWrapping="Wrap"><Run Foreground="#7AA2F7" FontWeight="Bold" Text="Ctrl+1"/> — <Run Text="Mode A (оптимально для 1080p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#7AA2F7" FontWeight="Bold" Text="Ctrl+2"/> — <Run Text="Mode B (оптимально для 720p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#7AA2F7" FontWeight="Bold" Text="Ctrl+3"/> — <Run Text="Mode C (оптимально для 480p)"/></TextBlock>
          <TextBlock TextWrapping="Wrap"><Run Foreground="#E06C75" FontWeight="Bold" Text="Ctrl+0"/> — <Run Text="сбросить шейдеры (выключить Anime4K)"/></TextBlock>
        </StackPanel>
      </Border>

      <!-- Footer -->
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
        <Button x:Name="btnAdvanced" Content="📖 Advanced Usage Instructions (подробный гайд)" Background="#31364A" Foreground="White"/>
        <Button x:Name="btnOpenConfig" Content="📁 Открыть папку конфига"/>
      </StackPanel>
      <TextBlock Style="{StaticResource Muted}" Margin="0,10,0,0" Text="Источники: github.com/mpvnet-player/mpv.net • builds.dotnet.microsoft.com • github.com/Tama47/Anime4K (v4.0.1) • github.com/bloc97/Anime4K (доки). Конфиги: %APPDATA%\mpv.net"/>
    </StackPanel>
  </ScrollViewer>
</Window>
'@

# ------------------------------------------------- XAML: Advanced окно ---
$Script:AdvancedXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Advanced Usage Instructions — Anime4K GLSL / MPV v4.x (на русском)" Height="700" Width="880"
        MinHeight="560" MinWidth="720" WindowStartupLocation="CenterScreen"
        Background="#16181D" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5">
  <Grid Margin="0">
    <FlowDocumentScrollViewer VerticalScrollBarVisibility="Auto" Padding="24">
      <FlowDocument Background="Transparent" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13.5" PagePadding="0">
        <Paragraph Margin="0,0,0,4">
          <Run FontSize="22" FontWeight="Bold" Text="Advanced Usage Instructions "/>
          <Run FontSize="13" Foreground="#9AA0AE" Text="(GLSL / MPV, v4.x) — перевод на русский"/>
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

# ------------------------------------------------- UI helpers ---
function New-WpfWindow {
  param([string]$Xaml)
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null
  $xml = [xml]$Xaml
  $reader = New-Object Xml.XmlNodeReader $xml
  return [Windows.Markup.XamlReader]::Load($reader)
}

function Update-StatusUI {
  $mpv = Get-MpvNetStatus
  $dn = Get-DotnetStatus
  $ok = [Windows.Media.Brushes]::LightGreen
  $bad = [Windows.Media.Brushes]::Tomato
  $mid = [Windows.Media.Brushes]::Gray
  if ($mpv.Installed) {
    $Script:LblMpv.Text = "Установлен" + $(if ($mpv.Version) { " • v$($mpv.Version)" }) + $(if ($mpv.Exe) { "`n$($mpv.Exe)" })
    $Script:DotMpv.Fill = $ok
  } else {
    $Script:LblMpv.Text = "Не найден — будет установлен системно (Program Files)."
    $Script:DotMpv.Fill = $bad
  }
  if ($dn.Installed) {
    $Script:LblDot.Text = "Установлен • $($dn.Detail)"
    $Script:DotNet.Fill = $ok
  } else {
    $Script:LblDot.Text = "Не найден — будет установлен $($Script:Cfg.DotnetVersion)."
    $Script:DotNet.Fill = $bad
  }
  try {
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
      [action]{}, [Windows.Threading.DispatcherPriority]::Background)
  } catch {}
}

function Show-AdvancedWindow {
  $w = New-WpfWindow $Script:AdvancedXaml
  try { $w.Owner = $Script:Window } catch {}
  $w.ShowDialog() | Out-Null
}

# ------------------------------------------------- Главная процедура установки (UI-поток) ---
function Start-FullInstall {
  $which = if ($Script:RbLow.IsChecked) { 'Low' } else { 'High' }
  $Script:BtnInstall.IsEnabled = $false
  $Script:Bar.IsIndeterminate = $false
  try {
    if (-not (Test-IsAdmin)) {
      $r = [Windows.MessageBox]::Show(
        "Для системной установки mpv.net и .NET Runtime нужны права администратора.`n`nПерезапустить скрипт с повышением?",
        'Нужны права администратора', 'YesNo', 'Warning')
      if ($r -eq 'Yes') {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $me = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        $psi.Arguments = "-ExecutionPolicy Bypass -STA -File `"$me`""
        $psi.Verb = 'runas'
        [Diagnostics.Process]::Start($psi) | Out-Null
      }
      Write-Log 'Нет прав администратора — установка остановлена.' 'WARN'
      $Script:LblStatus.Text = 'Нужны права администратора. Перезапустите от имени администратора.'
      return
    }

    $Script:Bar.Value = 5
    $Script:LblStatus.Text = 'Определение последней версии mpv.net…'
    Write-Log '--- Старт установки ---'
    $latest = Get-LatestMpvSetupUrl
    Write-Log ("Latest mpv.net: {0} / {1}" -f $latest.Tag, $latest.Name)
    $mpv = Get-MpvNetStatus

    # --- mpv.net ---
    $needMpv = -not $mpv.Installed
    if ($mpv.Installed) {
      # грубое сравнение: если pinned-тег новее установленной — обновить; иначе всё равно дать обновить
      Write-Log ("mpv.net уже установлен: {0} @ {1}" -f $mpv.Version, $mpv.Exe)
      $needMpv = $true  # системный setup идемпотентен — прогоняем для гарантии нужной версии
    }
    if ($needMpv) {
      $Script:LblStatus.Text = "Скачивание $($latest.Name)…"
      $Script:Bar.Value = 10
      $setup = Join-Path $env:TEMP $latest.Name
      Invoke-DownloadFile -Url $latest.Url -Dest $setup -Bar $Script:Bar -StatusLabel $Script:LblStatus
      $Script:LblStatus.Text = 'Установка mpv.net системно (тихо)…'
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
      $Script:LblStatus.Text = 'Скачивание .NET Desktop Runtime 10.0.13…'
      $Script:Bar.Value = 60
      $nd = Join-Path $env:TEMP 'windowsdesktop-runtime-10.0.13-win-x64.exe'
      Invoke-DownloadFile -Url $Script:Cfg.DotnetUrl -Dest $nd -Bar $Script:Bar -StatusLabel $Script:LblStatus
      $Script:LblStatus.Text = 'Установка .NET Runtime (тихо)…'
      $Script:Bar.IsIndeterminate = $true
      Install-DotnetRuntime -InstallerExe $nd -UseDispatcher $true
      try { Remove-Item $nd -Force -ErrorAction SilentlyContinue } catch {}
      $Script:Bar.IsIndeterminate = $false
      $Script:Bar.Value = 75
    } else {
      Write-Log (".NET уже установлен: {0}" -f $dn.Detail)
    }

    # --- Anime4K пресет ---
    $Script:LblStatus.Text = "Установка пресета Anime4K ($which) в %APPDATA%\mpv.net…"
    $Script:Bar.Value = 80
    Install-AnimePreset -Which $which
    $Script:Bar.Value = 95

    Update-StatusUI
    $Script:Bar.Value = 100
    $Script:LblStatus.Text = "Готово. Пресет $which в $($Script:Cfg.ConfigDir). Ctrl+1/2/3 — режимы, Ctrl+0 — выкл."
    Write-Log '--- Установка завершена успешно ---'
    [Windows.MessageBox]::Show(
      "Готово!`n`nmpv.net установлен системно, .NET 10.0.13 проверен,`nпресет Anime4K ($which) распакован в:`n$($Script:Cfg.ConfigDir)`n`nПорядок шейдеров — из mpv.conf архива.`nCtrl+1/2/3 — режимы A/B/C, Ctrl+0 — выключить.",
      'Anime4K установлен', 'OK', 'Information') | Out-Null
  } catch {
    $msg = $_.Exception.Message
    Write-Log $msg 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    $Script:LblStatus.Text = "Ошибка: $msg"
    $Script:Bar.IsIndeterminate = $false
    [Windows.MessageBox]::Show("Ошибка установки:`n$msg`n`nПодробности: $($Script:Cfg.LogFile)",
      'Ошибка', 'OK', 'Error') | Out-Null
  } finally {
    $Script:Bar.IsIndeterminate = $false
    $Script:BtnInstall.IsEnabled = $true
  }
}

# ------------------------------------------------- Silent-режим ---
function Start-SilentInstall {
  if (-not (Test-IsAdmin)) { throw 'Silent-режим с системной установкой требует запуска от администратора.' }
  Write-Host '[1/3] mpv.net…'
  $latest = Get-LatestMpvSetupUrl
  $setup = Join-Path $env:TEMP $latest.Name
  Invoke-WebRequest -Uri $latest.Url -OutFile $setup -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -UseBasicParsing
  Install-MpvNetSetup -SetupExe $setup -UseDispatcher $false
  Remove-Item $setup -Force -ErrorAction SilentlyContinue
  Write-Host '[2/3] .NET 10.0.13…'
  $dn = Get-DotnetStatus
  if (-not $dn.Installed) {
    $nd = Join-Path $env:TEMP 'windowsdesktop-runtime-10.0.13-win-x64.exe'
    Invoke-WebRequest -Uri $Script:Cfg.DotnetUrl -OutFile $nd -Headers @{ 'User-Agent' = 'Anime4K-Installer' } -UseBasicParsing
    Install-DotnetRuntime -InstallerExe $nd -UseDispatcher $false
    Remove-Item $nd -Force -ErrorAction SilentlyContinue
  } else { Write-Host "  уже установлен: $($dn.Detail)" }
  Write-Host "[3/3] Anime4K пресет $Preset…"
  Install-AnimePreset -Which $Preset
  Write-Host "Готово: $($Script:Cfg.ConfigDir)"
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
$Script:BtnInstall.Add_Click({ Start-FullInstall })
$Script:Window.FindName('btnAdvanced').Add_Click({ Show-AdvancedWindow })
$Script:Window.FindName('btnOpenConfig').Add_Click({
  $d = $Script:Cfg.ConfigDir
  if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
  Start-Process explorer.exe $d
})

Write-Log 'Открыт установщик (WPF).'
Update-StatusUI
$Script:LblStatus.Text = 'Готов. Выберите пресет и нажмите «Установить». Права админа нужны для системной установки.'
[void]$Script:Window.ShowDialog()
