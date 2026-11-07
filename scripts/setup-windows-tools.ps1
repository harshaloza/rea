<#
.SYNOPSIS
  Installs the external analysis tools that REA supports on Windows x64,
  builds this checkout, and registers it with Claude Code.

.DESCRIPTION
  Every download is pinned to an exact version and checked against its
  published SHA-256 before use. Steps that are already complete are skipped,
  so the script can be run again safely.

  See WINDOWS_SETUP.md for what is installed and why some REA features stay
  Linux-only.

.PARAMETER ToolsDir
  Folder for the portable tools (Ghidra, JADX, apktool, Rizin, Cutter, WABT).

.PARAMETER SkipRepoBuild
  Do not run submodule checkout, npm ci, or the builds.

.PARAMETER SkipClaude
  Do not change Claude Code's MCP registration or REA skill.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup-windows-tools.ps1
#>
[CmdletBinding()]
param(
  [string]$ToolsDir = 'C:\Tools',
  [switch]$SkipRepoBuild,
  [switch]$SkipClaude
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoDir = Split-Path -Parent $PSScriptRoot
$DownloadDir = Join-Path $env:TEMP 'rea-windows-tools'

# --- Pinned downloads ------------------------------------------------------
# SHA-256 values are the digests published on each project's GitHub release.
$Downloads = @{
  ghidra = @{
    Url    = 'https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip'
    Sha256 = 'ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db'
  }
  jadx = @{
    Url    = 'https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar'
    Sha256 = '6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75'
  }
  apktool = @{
    Url    = 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar'
    Sha256 = 'dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423'
  }
  rizin = @{
    Url    = 'https://github.com/rizinorg/rizin/releases/download/v0.9.1/rizin-windows-static-v0.9.1.zip'
    Sha256 = '2d14e0a6ecba1196dcd742d63de83bbaffed2a7a78ef5a0a9b4e92a0f73d1d28'
  }
  cutter = @{
    Url    = 'https://github.com/rizinorg/cutter/releases/download/v2.5.0/Cutter-v2.5.0-Windows-x86_64.zip'
    Sha256 = 'a04154a03a392dbf5886a629938582f7d23a93636fa0611c3e1c34905b197e69'
  }
  wabt = @{
    Url    = 'https://github.com/WebAssembly/wabt/releases/download/1.0.42/wabt-1.0.42-windows-x64.tar.gz'
    Sha256 = '62f1eb2b51aa57cf0f0b8ba333bf2c72a049930aa9c5de01dcad271c4fe48c88'
  }
}

# --- Helpers -----------------------------------------------------------------
function Write-Step([string]$Message) {
  Write-Host ''
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Done([string]$Message) { Write-Host "    ok: $Message" -ForegroundColor Green }
function Write-Skip([string]$Message) { Write-Host "    skip: $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    warning: $Message" -ForegroundColor Yellow }

# Runs a native command and fails on a non-zero exit code. Windows PowerShell
# 5.1 turns native stderr into errors under 'Stop', so relax it locally.
function Invoke-Native {
  param([string]$FilePath, [string[]]$Arguments = @(), [switch]$AllowFailure)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $FilePath @Arguments 2>&1 | ForEach-Object {
      $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
      if ($line.Trim() -and $line -ne 'System.Management.Automation.RemoteException') { Write-Host "    $line" }
    }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $code"
  }
  return $code
}

function Test-WingetPackage([string]$Id) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
  } finally {
    $ErrorActionPreference = $previous
  }
  return ($out -match [regex]::Escape($Id))
}

function Install-WingetPackage([string]$Id, [string]$Version) {
  if (Test-WingetPackage $Id) { Write-Skip "$Id is already installed"; return }
  $wingetArgs = @('install', '--id', $Id, '--exact', '--silent',
    '--accept-package-agreements', '--accept-source-agreements')
  if ($Version) { $wingetArgs += @('--version', $Version) }
  Invoke-Native winget $wingetArgs | Out-Null
  Write-Done "installed $Id"
}

function Get-VerifiedDownload([hashtable]$Spec) {
  New-Item -ItemType Directory -Force $DownloadDir | Out-Null
  $file = Join-Path $DownloadDir ([IO.Path]::GetFileName($Spec.Url))
  if (Test-Path $file) {
    if ((Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant() -eq $Spec.Sha256) { return $file }
    Remove-Item -Force $file
  }
  Write-Host "    downloading $($Spec.Url)"
  Invoke-WebRequest -UseBasicParsing -Uri $Spec.Url -OutFile $file
  $hash = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
  if ($hash -ne $Spec.Sha256) {
    Remove-Item -Force $file
    throw "SHA-256 mismatch for $($Spec.Url): expected $($Spec.Sha256), got $hash"
  }
  Write-Done "SHA-256 verified for $([IO.Path]::GetFileName($file))"
  return $file
}

function Find-WingetFile([string]$PackagePrefix, [string]$RelativePath) {
  $root = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (-not (Test-Path $root)) { return $null }
  foreach ($dir in Get-ChildItem $root -Directory -Filter "$PackagePrefix*") {
    $candidate = Join-Path $dir.FullName $RelativePath
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Test-NodeVersion([string]$Text) {
  if ($Text -notmatch '^v(\d+)\.(\d+)\.(\d+)') { return $false }
  $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
  # Mirrors package.json engines: ^22.23.4 || ^24.22.1 || >=26.12.1
  return (($v.Major -eq 22 -and $v -ge [version]'22.23.4') -or
          ($v.Major -eq 24 -and $v -ge [version]'24.22.1') -or
          ($v -ge [version]'26.12.1'))
}

# --- 1. Prerequisites --------------------------------------------------------
Write-Step 'Checking prerequisites'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'REA on Windows needs 64-bit Windows.' }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  throw 'winget was not found. Install "App Installer" from the Microsoft Store and run this script again.'
}
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$nodeVersion = if ($nodeCmd) { (& node --version) } else { '' }
if (Test-NodeVersion $nodeVersion) {
  Write-Done "Node.js $nodeVersion"
} else {
  Write-Warn "Node.js '$nodeVersion' does not meet REA's requirement; installing 24.22.1"
  Invoke-Native winget @('install', '--id', 'OpenJS.NodeJS.LTS', '--version', '24.22.1', '--exact',
    '--silent', '--force', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
  $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
  $nodeVersion = & "$env:ProgramFiles\nodejs\node.exe" --version
  if (-not (Test-NodeVersion $nodeVersion)) { throw "Node.js is still $nodeVersion after the update." }
  Write-Done "Node.js $nodeVersion"
}
$NodeExe = (Get-Command node).Source

# --- 2. Installed packages ---------------------------------------------------
Write-Step 'Installing packages with winget'
Install-WingetPackage 'EclipseAdoptium.Temurin.21.JDK'
Install-WingetPackage 'Google.PlatformTools'
Install-WingetPackage 'BrechtSanders.WinLibs.POSIX.UCRT'
Install-WingetPackage 'WiresharkFoundation.Wireshark'

$jdk = Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium" -Directory -Filter 'jdk-21*' -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $jdk) { throw 'JDK 21 was not found under Program Files\Eclipse Adoptium.' }
$JavaHome = $jdk.FullName
$JavaExe = Join-Path $JavaHome 'bin\java.exe'
Write-Done "JDK at $JavaHome"

# --- 3. Portable tools -------------------------------------------------------
Write-Step "Installing portable tools into $ToolsDir"
New-Item -ItemType Directory -Force $ToolsDir | Out-Null

$GhidraDir = Join-Path $ToolsDir 'ghidra_12.1.4_PUBLIC'
if (Test-Path (Join-Path $GhidraDir 'support\analyzeHeadless.bat')) { Write-Skip 'Ghidra 12.1.4' } else {
  Expand-Archive -Force (Get-VerifiedDownload $Downloads.ghidra) $ToolsDir
  Write-Done 'Ghidra 12.1.4'
}

$JadxJar = Join-Path $ToolsDir 'jadx\jadx-headless-mcp-0.7.1-all.jar'
if (Test-Path $JadxJar) { Write-Skip 'JADX headless MCP 0.7.1' } else {
  New-Item -ItemType Directory -Force (Split-Path $JadxJar) | Out-Null
  Copy-Item (Get-VerifiedDownload $Downloads.jadx) $JadxJar
  Write-Done 'JADX headless MCP 0.7.1'
}

$ApktoolDir = Join-Path $ToolsDir 'apktool'
$ApktoolBat = Join-Path $ApktoolDir 'apktool.bat'
if (Test-Path (Join-Path $ApktoolDir 'apktool_3.0.3.jar')) { Write-Skip 'apktool 3.0.3' } else {
  New-Item -ItemType Directory -Force $ApktoolDir | Out-Null
  Copy-Item (Get-VerifiedDownload $Downloads.apktool) (Join-Path $ApktoolDir 'apktool_3.0.3.jar')
  Write-Done 'apktool 3.0.3'
}
# Always rewrite the launcher so it follows the current JDK.
[IO.File]::WriteAllText($ApktoolBat, "@echo off`r`n`"$JavaExe`" -jar `"%~dp0apktool_3.0.3.jar`" %*`r`n")

$RizinExe = Join-Path $ToolsDir 'rizin\rizin-win-installer-vs2019_static-64\bin\rizin.exe'
if (Test-Path $RizinExe) { Write-Skip 'Rizin 0.9.1' } else {
  Expand-Archive -Force (Get-VerifiedDownload $Downloads.rizin) (Join-Path $ToolsDir 'rizin')
  Write-Done 'Rizin 0.9.1'
}

$CutterExe = Join-Path $ToolsDir 'cutter\Cutter-v2.5.0-Windows-x86_64\cutter.exe'
if (Test-Path $CutterExe) { Write-Skip 'Cutter 2.5.0' } else {
  Expand-Archive -Force (Get-VerifiedDownload $Downloads.cutter) (Join-Path $ToolsDir 'cutter')
  Write-Done 'Cutter 2.5.0'
}

$WabtBin = Join-Path $ToolsDir 'wabt\wabt-1.0.42\bin'
if (Test-Path (Join-Path $WabtBin 'wasm-objdump.exe')) { Write-Skip 'WABT 1.0.42' } else {
  New-Item -ItemType Directory -Force (Join-Path $ToolsDir 'wabt') | Out-Null
  Invoke-Native tar @('-xzf', (Get-VerifiedDownload $Downloads.wabt), '-C', (Join-Path $ToolsDir 'wabt')) | Out-Null
  Write-Done 'WABT 1.0.42'
}

$CutterPlugins = Join-Path $env:APPDATA 'rizin\cutter\plugins\python'
New-Item -ItemType Directory -Force $CutterPlugins | Out-Null
Copy-Item (Join-Path $RepoDir 'bridge\cutter\rea_bridge.py') $CutterPlugins -Force
Write-Done "REA Cutter plugin copied to $CutterPlugins"

# --- 4. .NET and Python tools ------------------------------------------------
Write-Step 'Installing .NET and Python tools'
$IlspyCmd = $null
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
  $toolDir = Join-Path $env:USERPROFILE '.dotnet\tools'
  $IlspyCmd = Get-ChildItem $toolDir -Filter 'ilspycmd.*' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($IlspyCmd) { Write-Skip 'ilspycmd' } else {
    Invoke-Native dotnet @('tool', 'install', '--global', 'ilspycmd') | Out-Null
    $IlspyCmd = Get-ChildItem $toolDir -Filter 'ilspycmd.*' | Select-Object -First 1 -ExpandProperty FullName
    Write-Done 'ilspycmd'
  }
} else {
  Write-Warn '.NET SDK not found; skipping ilspycmd (install it with: winget install Microsoft.DotNet.SDK.9)'
}

if (Get-Command python -ErrorAction SilentlyContinue) {
  Invoke-Native python @('-m', 'pip', 'install', '--user', '--upgrade', '--quiet', 'esptool', 'frida-tools') | Out-Null
  Write-Done 'esptool and frida-tools'
} else {
  Write-Warn 'Python not found; skipping esptool and frida-tools'
}

# --- 5. Build this checkout --------------------------------------------------
$NativeAotJar = Join-Path $RepoDir '_reference\nativeaot-integration\extension\rea-ghidra-nativeaot.jar'
if ($SkipRepoBuild) {
  Write-Step 'Skipping repository build (-SkipRepoBuild)'
} else {
  Write-Step "Building REA in $RepoDir"
  Push-Location $RepoDir
  try {
    # Unblob is left out: its upstream test fixtures have names NTFS rejects,
    # and REA's firmware tools are Linux-only anyway.
    Invoke-Native git @('submodule', 'update', '--init', 'third_party/binwalk', 'third_party/ghidra-nativeaot',
      'third_party/jadx-headless-mcp', 'third_party/wakaru') | Out-Null
    Write-Done 'submodules'

    Invoke-Native npm @('ci', '--no-audit', '--no-fund') | Out-Null
    Write-Done 'npm ci'

    # The Windows native controls can only be built on Linux, so take them
    # from the published npm package of the same version.
    $nativeDir = Join-Path $RepoDir 'native\windows\build'
    if (Test-Path (Join-Path $nativeDir 'rea-windows-x64.node')) {
      Write-Skip 'Windows native controls already present'
    } else {
      $version = (Get-Content (Join-Path $RepoDir 'package.json') -Raw | ConvertFrom-Json).version
      $packDir = Join-Path $DownloadDir "rea-agents-$version"
      New-Item -ItemType Directory -Force $packDir | Out-Null
      Invoke-Native npm @('pack', "rea-agents@$version", '--pack-destination', $packDir) | Out-Null
      $tgz = Get-ChildItem $packDir -Filter '*.tgz' | Select-Object -First 1 -ExpandProperty FullName
      Invoke-Native tar @('-xzf', $tgz, '-C', $packDir, 'package/native/windows/build') | Out-Null
      New-Item -ItemType Directory -Force $nativeDir | Out-Null
      Copy-Item (Join-Path $packDir 'package\native\windows\build\*') $nativeDir -Force
      Write-Done "Windows native controls from rea-agents@$version"
    }

    Invoke-Native npm @('run', 'build:cached') | Out-Null
    Write-Done 'CLI and MCP server built'

    $env:GHIDRA_INSTALL_DIR = $GhidraDir
    $env:JAVA_HOME = $JavaHome
    $env:Path = "$JavaHome\bin;$env:Path"
    Invoke-Native npm @('run', 'build:ghidra:nativeaot') | Out-Null
    Write-Done 'NativeAOT Ghidra extension built'
  } finally {
    Pop-Location
  }
}

# --- 6. Environment variables -------------------------------------------------
Write-Step 'Setting user environment variables'
$browser = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1

$adb = Find-WingetFile 'Google.PlatformTools' 'platform-tools\adb.exe'
if (-not $adb) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
$objdump = Find-WingetFile 'BrechtSanders.WinLibs.POSIX.UCRT' 'mingw64\bin\objdump.exe'

$EnvVars = [ordered]@{
  GHIDRA_INSTALL_DIR       = $GhidraDir
  JAVA_HOME                = $JavaHome
  REA_ADB_PATH             = $adb
  REA_APKTOOL_COMMAND      = $ApktoolBat
  REA_JADX_MCP_JAR         = $JadxJar
  REA_RIZIN_COMMAND        = $RizinExe
  REA_OBJDUMP_COMMAND      = $objdump
  REA_TSHARK_COMMAND       = "$env:ProgramFiles\Wireshark\tshark.exe"
  REA_CAPINFOS_COMMAND     = "$env:ProgramFiles\Wireshark\capinfos.exe"
  REA_WABT_BIN_DIRECTORY   = $WabtBin
  REA_ILSPY_CMD_PATH       = $IlspyCmd
  REA_GHIDRA_NATIVEAOT_JAR = $NativeAotJar
  REA_BROWSER_EXECUTABLE   = $browser
}
$SetVars = [ordered]@{}
foreach ($name in $EnvVars.Keys) {
  $value = $EnvVars[$name]
  if ($value -and (Test-Path $value)) {
    [Environment]::SetEnvironmentVariable($name, $value, 'User')
    Set-Item "Env:$name" $value
    $SetVars[$name] = $value
    Write-Done "$name"
  } else {
    Write-Warn "$name not set: path not found ($value)"
  }
}

# --- 7. Claude Code ------------------------------------------------------------
if ($SkipClaude) {
  Write-Step 'Skipping Claude Code registration (-SkipClaude)'
} elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Step 'Claude Code CLI not found; skipping registration'
} else {
  Write-Step 'Registering this checkout with Claude Code'
  Invoke-Native claude @('mcp', 'remove', 'rea', '-s', 'user') -AllowFailure | Out-Null
  $claudeArgs = @('mcp', 'add', 'rea', '-s', 'user')
  foreach ($name in $SetVars.Keys) { $claudeArgs += @('-e', "$name=$($SetVars[$name])") }
  $claudeArgs += @('--', $NodeExe, (Join-Path $RepoDir 'scripts\rea.mjs'), 'mcp')
  Invoke-Native claude $claudeArgs | Out-Null
  Write-Done 'rea MCP server registered for all projects'

  Invoke-Native $NodeExe @((Join-Path $RepoDir 'scripts\rea.mjs'), 'setup', '--skill-client', 'claude_code',
    '--skill', '--yes') | Out-Null
  Write-Done 'REA skill updated'
}

# --- 8. Verify -----------------------------------------------------------------
Write-Step 'Running rea doctor for Ghidra and JADX'
Invoke-Native $NodeExe @((Join-Path $RepoDir 'scripts\rea.mjs'), 'doctor', '--provider', 'ghidra',
  '--provider', 'jadx') -AllowFailure | Out-Null

Write-Host ''
Write-Host 'Done. Start a new Claude Code session (or restart your agent) to load REA with these tools.' -ForegroundColor Green
