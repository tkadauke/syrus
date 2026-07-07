# Uninstall Syrus from this Windows machine - the reverse of install.ps1
# --docker plus the desktop-app artifacts. What it removes:
#
#   - the Docker Compose stack (project `syrus`): containers are found by
#     their compose project label (covers compose v1 underscore and v2
#     hyphen container names alike) and removed by ID; unless --keep-data, the
#     data volumes go too - found by the same label PLUS the known names
#     (syrus_syrus-data, syrus_syrus-search) as a fallback. Teardown is
#     VERIFIED by re-listing afterwards; anything left behind is reported
#     honestly (step status `failed`) and the script exits 3
#   - images whose repository BASENAME is exactly `syrus-backend` or
#     `syrus-local` (any registry/namespace - the same exact-segment
#     semantics as desktop/electron/installer/imageCleanup.ts, so a user's
#     unrelated `my-syrus-backend` never matches). Removal is a plain
#     `docker rmi <repo:tag>` per tag, never -f: -f would untag EVERY tag
#     sharing the image ID (a user's backup tag included). Polite refusals
#     are logged and left in place
#   - %USERPROFILE%\.syrus\local - the .env in here holds the DATABASE
#     ENCRYPTION KEYS; it is deleted ONLY once the docker data volumes are
#     verifiably gone. A surviving syrus_syrus-data volume with the keys
#     deleted would wedge any reinstall (install.ps1's encryption-key
#     guard) with no compose file left to fix it, so if Docker is
#     unreachable or a volume survives, the directory is KEPT, a warning is
#     emitted, and the script exits 3 - start Docker and re-run to finish.
#     (Skipped by --keep-data.)
#   - %USERPROFILE%\.syrus\credentials (skipped by --keep-data), and
#     %USERPROFILE%\.syrus itself when it is empty afterward
#   - the `syrus` CLI at %LOCALAPPDATA%\Syrus\bin\syrus.exe (and .exe.old),
#     plus that directory's HKCU\Environment Path entry (with a
#     WM_SETTINGCHANGE broadcast so new terminals notice)
#   - the Claude Code skill at %USERPROFILE%\.claude\skills\syrus
#   - desktop app settings at %APPDATA%\Syrus (skipped by --keep-data)
#   - the HKCU RunOnce value SyrusResumeSetup (a leftover setup-resume hook)
#   - the desktop app itself, LAST: the NSIS uninstaller under
#     %LOCALAPPDATA%\Programs\syrus-desktop runs silently (/S); if it is
#     missing, use Settings > Apps > Syrus
#
# Shared tools are NEVER touched: Docker Desktop has its own uninstaller.
#
# This file is the PowerShell port of uninstall.sh's machine interface. The
# desktop app can drive both headlessly, so the NDJSON protocol, step ids,
# and exit codes MUST stay aligned; spec/desktop/uninstall_spec.rb pins the
# shared strings - change both scripts together. uninstall.sh's
# `--app-path=PATH` flag is accepted here for interface parity but ignored:
# the NSIS uninstaller owns app removal on Windows.
#
# Default is interactive: prints exactly what will be removed and asks one
# y/N question. Flags:
#
#   --yes            skip the confirmation prompt
#   --keep-data      preserve %USERPROFILE%\.syrus (encryption keys,
#                    credentials), the docker data volumes, and the app
#                    settings; removes only the app, CLI, skill, containers,
#                    and images
#   --json           machine-readable NDJSON events on stdout (start, step,
#                    log, error, done), the same protocol install.ps1
#                    speaks; implies --yes (a GUI does its own confirmation)
#   --app-path=PATH  accepted for parity with uninstall.sh and ignored (the
#                    NSIS uninstaller owns app removal on Windows)
#   --help           show this message
#
# Exit codes: 0 ok (including a declined prompt and "nothing left to
# remove") - 2 usage - 3 partial: something could not be removed or
# verified (Docker unreachable, a leftover container/volume after teardown,
# or a failed file removal); without --keep-data the encryption keys in
# %USERPROFILE%\.syrus\local are kept until the data volumes are verifiably
# gone, so starting Docker and re-running finishes the job; on a partial
# run the NDJSON stream ends with an `error` event (code 3) instead of
# `done` - 1 anything else. Missing artifacts are skipped - re-running is
# always safe.
#
# Target: Windows PowerShell 5.1 (inbox on every Windows 10/11 machine).
# No pwsh-7-only APIs, and keep this file pure ASCII: PS 5.1 parses BOM-less
# script files with the ANSI codepage, so any non-ASCII byte would be misread.

# NDJSON on stdout must be byte-exact UTF-8 for the GUI driver; the console
# codepage would otherwise mangle it. A missing console (headless spawn with
# fully redirected handles) is fine - ignore the failure.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:Json = $false
$script:CurrentStep = ""

$HelpText = @'
Uninstall Syrus from this Windows machine.

Usage: .\uninstall.ps1 [options]

Removes the Docker Compose stack (project syrus, containers found by their
compose project label) and its volumes (found by label plus the known names
as a fallback, verified after teardown), the syrus-backend / syrus-local
images (exact repository basename, any registry; plain docker rmi per tag,
never -f), the install state at %USERPROFILE%\.syrus\local (the .env holds
the DATABASE ENCRYPTION KEYS - it is deleted only once the data volumes are
verifiably gone, otherwise it is kept and the script exits 3),
%USERPROFILE%\.syrus\credentials, the syrus CLI at
%LOCALAPPDATA%\Syrus\bin\syrus.exe (and its HKCU Path entry), the Claude
Code skill at %USERPROFILE%\.claude\skills\syrus, the app settings at
%APPDATA%\Syrus, the SyrusResumeSetup RunOnce value, and finally the desktop
app via its NSIS uninstaller (silent /S).

Docker Desktop itself is never touched - it has its own uninstaller.

  --yes            skip the confirmation prompt
  --keep-data      preserve %USERPROFILE%\.syrus, the docker data volumes,
                   and the app settings; removes only the app, CLI, skill,
                   containers, and images
  --json           machine-readable NDJSON events on stdout (start, step,
                   log, error, done); implies --yes (a GUI does its own
                   confirmation)
  --app-path=PATH  accepted for parity with uninstall.sh and ignored (the
                   NSIS uninstaller owns app removal on Windows)
  --help           show this message

Exit codes: 0 ok (including a declined prompt) - 2 usage - 3 partial
(something could not be removed or verified; the encryption keys are kept
until the data volumes are verifiably gone - start Docker and re-run to
finish) - 1 anything else. Missing artifacts are skipped - re-running is
always safe.
'@

function Show-Help {
  [Console]::Out.WriteLine($HelpText)
}

# In --json mode, stdout carries exactly one JSON event per line and all
# human-readable output moves to stderr, so a GUI can parse the stream.
function Write-HumanStep {
  param([string]$Message)
  if ($script:Json) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("== $Message")
  } else {
    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("== $Message")
  }
}

function Write-Info {
  param([string]$Message)
  if ($script:Json) { [Console]::Error.WriteLine("   $Message") }
  else { [Console]::Out.WriteLine("   $Message") }
}

function Remove-ControlChars {
  # C0 control bytes (ANSI ESC from tool output, etc.) would garble the
  # NDJSON stream for the GUI driver - strip them before emitting. Mirror
  # uninstall.sh's json_escape exactly: TAB and LF survive (ConvertTo-Json
  # escapes them as \t and \n), CR and every other C0 byte is dropped.
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  return ($Text -replace "[\x00-\x08\x0b-\x1f]", "")
}

function Emit-Json {
  param([System.Collections.IDictionary]$Payload)
  if (-not $script:Json) { return }
  [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $Payload))
}

function Emit-Step {
  # emit_step <id> <status> [detail] - also tracks context for Fail
  param([string]$Id, [string]$Status, [string]$Detail = "")
  $script:CurrentStep = $Id
  $payload = [ordered]@{ event = "step"; id = $Id; status = $Status }
  if ($Detail) { $payload["detail"] = (Remove-ControlChars $Detail) }
  Emit-Json $payload
}

function Emit-Log {
  param([string]$Stream, [string]$Line)
  Emit-Json ([ordered]@{ event = "log"; stream = $Stream; line = (Remove-ControlChars $Line) })
}

function Fail {
  # die <message> [exit-code]: protocol error event, human stderr line, exit.
  param([string]$Message, [int]$Code = 1)
  Emit-Json ([ordered]@{ event = "error"; code = $Code; step = $script:CurrentStep; message = (Remove-ControlChars $Message) })
  [Console]::Error.WriteLine("Error: $Message")
  exit $Code
}

# A failed or unverifiable teardown step must not abort the remaining steps
# and must not be reported as success: each one records a reason here, and
# the script exits 3 (with an error event, code 3, instead of done) at the
# end if anything was recorded.
$script:Partial = $false
$script:PartialReasons = New-Object System.Collections.Generic.List[string]

function Add-Partial {
  param([string]$Reason)
  $script:Partial = $true
  $script:PartialReasons.Add($Reason)
}

function Invoke-NativeQuiet {
  # Run a native command discarding all output; exit code lands in
  # $LASTEXITCODE. EAP is relaxed locally because under Stop, PS 5.1 turns
  # redirected native stderr into a terminating NativeCommandError.
  param([string]$Exe, [string[]]$CommandArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try { & $Exe @CommandArgs *> $null } finally { $ErrorActionPreference = $prev }
}

function Invoke-NativeCapture {
  # Run a native command discarding stderr; returns stdout as an array of
  # non-empty trimmed lines. Exit code lands in $LASTEXITCODE. Same local
  # EAP relaxation as Invoke-NativeQuiet.
  param([string]$Exe, [string[]]$CommandArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try { $lines = @(& $Exe @CommandArgs 2> $null) } finally { $ErrorActionPreference = $prev }
  return @($lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
}

function Invoke-LoggedCommand {
  # Stream a native command's merged stdout+stderr as `log` events in --json
  # mode (or plain lines otherwise) and return the lines. Exit code is left
  # in $LASTEXITCODE. Same local EAP relaxation as Invoke-NativeQuiet.
  param([string]$Stream, [string]$Exe, [string[]]$CommandArgs)
  $captured = New-Object System.Collections.Generic.List[string]
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $Exe @CommandArgs 2>&1 | ForEach-Object {
      $line = "$_"    # native stderr arrives as ErrorRecords; stringify them
      $captured.Add($line)
      if ($script:Json) { Emit-Log $Stream $line }
      else { [Console]::Out.WriteLine($line) }
    }
  } finally {
    $ErrorActionPreference = $prev
  }
  return $captured
}

function Add-DockerCliPath {
  # GUI-launched processes may lack a login PATH; make Docker Desktop's CLI
  # directory searchable no matter who spawned us (install.ps1 does the same).
  if (-not $env:ProgramFiles) { return }
  $dockerBin = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin"
  if (-not (Test-Path -LiteralPath $dockerBin)) { return }
  $parts = $env:Path -split ";"
  if ($parts -notcontains $dockerBin) { $env:Path = $env:Path + ";" + $dockerBin }
}

function Test-DockerDaemon {
  if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) { return $false }
  Invoke-NativeQuiet "docker" @("info")
  return ($LASTEXITCODE -eq 0)
}

function Get-PathDescription {
  # "<path> (present)" or "<path> (not present)" for the interactive plan.
  param([string]$Target)
  if (Test-Path -LiteralPath $Target) { return "$Target (present)" }
  return "$Target (not present)"
}

function Remove-PathStep {
  # Guarded Remove-Item with step/log events; skipped when absent. The path
  # actually being gone afterwards is the only success criterion - a
  # silently-failed Remove-Item becomes a failed step + partial exit, never
  # a false "Removed".
  param([string]$Id, [string]$Target, [string]$Label)
  if (Test-Path -LiteralPath $Target) {
    Emit-Step $Id "start"
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Target) {
      Write-Info "WARNING: could not fully remove ${Label}: $Target"
      Emit-Log "files" "failed to remove $Target"
      Emit-Step $Id "failed" "could not remove $Target"
      Add-Partial "could not remove $Target"
    } else {
      Write-Info "Removed ${Label}: $Target"
      Emit-Log "files" "removed $Target"
      Emit-Step $Id "ok"
    }
  } else {
    Emit-Step $Id "skipped" "not present"
  }
}

function Get-SyrusContainerIds {
  # Every container the compose project ever created, by ID. Compose v1 and
  # v2 both stamp this label - it is the reliable way to enumerate the stack
  # regardless of container naming scheme (v1 syrus_web_1 underscores vs v2
  # hyphens).
  return @(Invoke-NativeCapture "docker" @("ps", "-aq", "--filter", $script:ComposeLabelFilter))
}

function Get-SyrusVolumeNames {
  # Label-discovered volumes PLUS the known names, deduped.
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($volumeName in (Invoke-NativeCapture "docker" @("volume", "ls", "-q", "--filter", $script:ComposeLabelFilter))) {
    if ($volumeName -and -not $names.Contains($volumeName)) { $names.Add($volumeName) }
  }
  foreach ($volumeName in $script:KnownVolumes) {
    Invoke-NativeQuiet "docker" @("volume", "inspect", $volumeName)
    if ($LASTEXITCODE -eq 0 -and -not $names.Contains($volumeName)) { $names.Add($volumeName) }
  }
  return @($names)
}

function Remove-FromWindowsUserPath {
  # Reverse of the desktop app's addToWindowsUserPath (desktop/electron/
  # main.ts): read the raw HKCU\Environment Path value with variable
  # expansion disabled so other entries' %VARS% survive the round-trip, drop
  # our entry, write it back with the SAME value kind, and broadcast
  # WM_SETTINGCHANGE so new terminals pick the change up without a logoff.
  # setx is deliberately avoided: it truncates at 1024 chars and rewrites
  # REG_EXPAND_SZ as REG_SZ - the classic PATH-corruption bug.
  param([string]$Dir)
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
  if ($null -eq $key) { return $false }
  try {
    if (-not ($key.GetValueNames() -contains "Path")) { return $false }
    $kind = $key.GetValueKind("Path")
    $current = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($current -split ";" | Where-Object { $_ -ne "" })
    if (-not ($entries -contains $Dir)) { return $false }
    $next = (@($entries | Where-Object { $_ -ne $Dir }) -join ";")
    $key.SetValue("Path", $next, $kind)
    $signature = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    if (-not ("SyrusUninstall.Win32SendMessage" -as [type])) {
      Add-Type -MemberDefinition $signature -Name Win32SendMessage -Namespace SyrusUninstall | Out-Null
    }
    [UIntPtr]$result = [UIntPtr]::Zero
    ("SyrusUninstall.Win32SendMessage" -as [type])::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
    return $true
  } finally {
    $key.Close()
  }
}

# ===========================================================================
# bash's `set -e` analog for everything not classified above: any unexpected
# terminating error becomes a generic failure - protocol error event, human
# stderr line, exit 1.
trap {
  $message = "$_"
  Emit-Json ([ordered]@{ event = "error"; code = 1; step = $script:CurrentStep; message = (Remove-ControlChars $message) })
  [Console]::Error.WriteLine("Error: $message")
  exit 1
}

Add-DockerCliPath

$script:AssumeYes = $false
$script:KeepData = $false

# Walk the raw arg list by hand (no param() block): exact usage exit codes
# need manual control - mirrors install.ps1.
$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
  $arg = [string]$argv[$i]
  switch -CaseSensitive ($arg) {
    "--yes" { $script:AssumeYes = $true }
    "-y" { $script:AssumeYes = $true }
    "--keep-data" { $script:KeepData = $true }
    "--json" { $script:Json = $true; $script:AssumeYes = $true }
    "--app-path" {
      # Accepted for parity with uninstall.sh (bare form carries no value
      # there either) and ignored: NSIS owns app removal on Windows.
    }
    "--help" { Show-Help; exit 0 }
    "-h" { Show-Help; exit 0 }
    default {
      if ($arg.StartsWith("--app-path=")) {
        # Accepted for parity with uninstall.sh and ignored: the NSIS
        # uninstaller owns app removal on Windows.
      } else {
        Fail "Unknown flag: $arg (try --help)" 2
      }
    }
  }
  $i++
}

$userProfile = $env:USERPROFILE
if (-not $userProfile) { $userProfile = [Environment]::GetFolderPath("UserProfile") }
$localAppData = $env:LOCALAPPDATA
if (-not $localAppData) { $localAppData = Join-Path $userProfile "AppData\Local" }
$roamingAppData = $env:APPDATA
if (-not $roamingAppData) { $roamingAppData = Join-Path $userProfile "AppData\Roaming" }

$syrusDir = Join-Path $userProfile ".syrus"
$stateDir = Join-Path $syrusDir "local"
$credentialsFile = Join-Path $syrusDir "credentials"
$cliDir = Join-Path $localAppData "Syrus\bin"
$cliExe = Join-Path $cliDir "syrus.exe"
$cliExeOld = Join-Path $cliDir "syrus.exe.old"
$skillDir = Join-Path $userProfile ".claude\skills\syrus"
$settingsDir = Join-Path $roamingAppData "Syrus"
$nsisDir = Join-Path $localAppData "Programs\syrus-desktop"
$runOncePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"

# Belt-and-braces alongside the compose file's `name: syrus`: keeps the
# `syrus_` volume prefix stable for docker-compose v1 and odd invocation dirs.
$env:COMPOSE_PROJECT_NAME = "syrus"
$script:ComposeLabelFilter = "label=com.docker.compose.project=syrus"
$script:KnownVolumes = @("syrus_syrus-data", "syrus_syrus-search")

$dockerReady = Test-DockerDaemon

# ---------------------------------------------------------------------------
# The plan - printed before anything is touched (stderr in --json mode).
Write-HumanStep "Uninstalling Syrus - the plan"
if ($dockerReady) {
  if ($script:KeepData) {
    Write-Info "Docker: stop and remove the syrus containers (volumes KEPT: --keep-data)"
  } else {
    Write-Info "Docker: remove the syrus containers AND the data volumes (found by"
    Write-Info "        compose label; known names syrus_syrus-data, syrus_syrus-search"
    Write-Info "        as a fallback) - verified by re-listing after teardown"
  }
  Write-Info "Docker images: syrus-backend and syrus-local images (exact repository"
  Write-Info "               basename, any registry) - plain docker rmi per tag, never -f"
} else {
  Write-Info "Docker: not reachable - container/volume/image removal will be SKIPPED."
}
if ($script:KeepData) {
  Write-Info "Keeping (--keep-data): $stateDir, $credentialsFile,"
  Write-Info "                       $settingsDir, and the docker data volumes"
} else {
  if ($dockerReady) {
    Write-Info ("DELETE " + (Get-PathDescription $stateDir))
    Write-Info "       WARNING: its .env holds the ENCRYPTION KEYS for the Syrus database;"
    Write-Info "       together with the data volume this DESTROYS the local Syrus data"
    Write-Info "       permanently. Use --keep-data to keep it. Deleted only once the"
    Write-Info "       data volumes are verifiably gone."
  } else {
    Write-Info ("KEEP   " + (Get-PathDescription $stateDir))
    Write-Info "       WARNING: its .env holds the ENCRYPTION KEYS for the data volumes,"
    Write-Info "       and Docker is unreachable so the volumes cannot be removed now."
    Write-Info "       The keys stay until the volumes are verifiably gone (this run"
    Write-Info "       will exit 3 - start Docker and re-run to finish)."
  }
  Write-Info ("DELETE " + (Get-PathDescription $credentialsFile))
  Write-Info ("DELETE " + (Get-PathDescription $settingsDir))
}
Write-Info ("DELETE " + (Get-PathDescription $cliExe))
Write-Info ("DELETE " + (Get-PathDescription $skillDir))
if (Test-Path -LiteralPath $nsisDir) {
  Write-Info "UNINSTALL the desktop app via its NSIS uninstaller ($nsisDir, silent /S)"
} else {
  Write-Info "Desktop app: no NSIS install found under $nsisDir"
}
Write-Info "NOT touched: Docker Desktop - a shared tool with its own uninstaller."

if (-not $script:AssumeYes) {
  $interactive = $false
  try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
  if (-not $interactive) {
    Fail "Not an interactive shell. Pass --yes (or --json) to confirm removal." 2
  }
  [Console]::Out.WriteLine("")
  $answer = Read-Host "Remove Syrus from this machine? [y/N]"
  if ($answer -notmatch "^(?i)y(es)?$") {
    Write-Info "Aborted - nothing was removed."
    exit 0
  }
}

Emit-Json ([ordered]@{ event = "start"; mode = "uninstall"; keep_data = [bool]$script:KeepData })

# ---------------------------------------------------------------------------
# 1. Docker: stop the stack, remove containers (+ volumes unless --keep-data),
#    verify the removal actually happened, then remove the syrus images. An
#    unreachable daemon skips this whole section with a warning - file removal
#    below still runs, but the encryption keys are kept (see section 2) and
#    the run counts as partial.
Write-HumanStep "Docker stack"
$script:VolumesVerifiedGone = $false
if ($dockerReady) {
  Emit-Step "docker_down" "start"
  $composeExe = $null
  $composePrefix = @()
  Invoke-NativeQuiet "docker" @("compose", "version")
  if ($LASTEXITCODE -eq 0) {
    $composeExe = "docker"
    $composePrefix = @("compose")
  } elseif (Get-Command "docker-compose" -ErrorAction SilentlyContinue) {
    $composeExe = "docker-compose"
  }
  $downArgs = @("down", "-v", "--remove-orphans")
  if ($script:KeepData) { $downArgs = @("down", "--remove-orphans") }
  if ($composeExe) {
    $composeFile = Join-Path $stateDir "docker-compose.yml"
    if (Test-Path -LiteralPath $composeFile) {
      # Run against the desktop install's compose file; --project-directory
      # makes its relative env_file resolve no matter where we were invoked.
      $null = Invoke-LoggedCommand "docker" $composeExe ($composePrefix + @("-p", "syrus", "-f", $composeFile, "--project-directory", $stateDir) + $downArgs)
    } else {
      # Clone-dir installs keep their compose file elsewhere; newer compose
      # can tear a project down by name alone. Older ones fail harmlessly -
      # the direct removal below finishes the job.
      $null = Invoke-LoggedCommand "docker" $composeExe ($composePrefix + @("-p", "syrus") + $downArgs)
    }
  }
  # Belt and braces for whatever compose couldn't reach (no compose file, no
  # compose plugin, a half-removed stack): enumerate the project's actual
  # containers by compose label and remove them by ID.
  $containerIds = @(Get-SyrusContainerIds)
  if ($containerIds.Count -gt 0) {
    Invoke-NativeQuiet "docker" (@("rm", "-f") + $containerIds)
  }
  if (-not $script:KeepData) {
    $volumeNames = @(Get-SyrusVolumeNames)
    if ($volumeNames.Count -gt 0) {
      Invoke-NativeQuiet "docker" (@("volume", "rm") + $volumeNames)
    }
  }
  # Trust nothing: re-list and report honestly. Only a clean re-list counts
  # as success - and (without --keep-data) unlocks deleting the encryption
  # keys in section 2.
  $leftoverContainers = @(Get-SyrusContainerIds)
  $leftoverVolumes = @()
  if (-not $script:KeepData) { $leftoverVolumes = @(Get-SyrusVolumeNames) }
  if ($leftoverContainers.Count -eq 0 -and $leftoverVolumes.Count -eq 0) {
    if (-not $script:KeepData) {
      $script:VolumesVerifiedGone = $true
      Write-Info "Containers and data volumes removed (verified: none left)."
    } else {
      Write-Info "Containers removed (data volumes kept)."
    }
    Emit-Step "docker_down" "ok"
  } else {
    $leftovers = ((@($leftoverContainers) + @($leftoverVolumes)) -join " ")
    Write-Info "WARNING: docker teardown left something behind: $leftovers"
    Emit-Log "docker" "teardown left behind: $leftovers"
    Emit-Step "docker_down" "failed" "leftovers: $leftovers"
    Add-Partial "docker teardown left behind: $leftovers"
  }

  Emit-Step "docker_images" "start"
  $removedImages = 0
  $keptImages = 0
  $imageLines = Invoke-NativeCapture "docker" @("images", "--format", "{{.Repository}} {{.Tag}}")
  foreach ($imageLine in ($imageLines | Sort-Object -Unique)) {
    $parts = @("$imageLine" -split " " | Where-Object { $_ -ne "" })
    if ($parts.Count -lt 2) { continue }
    $repo = $parts[0]
    $tag = $parts[1]
    if ($repo -eq "<none>" -or $tag -eq "<none>") { continue }
    # Exact repository BASENAME match (mirrors desktop/electron/installer/
    # imageCleanup.ts): a user's unrelated my-syrus-backend never matches.
    $repoBasename = ($repo -split "/")[-1]
    if ($repoBasename -ne "syrus-backend" -and $repoBasename -ne "syrus-local") { continue }
    $ref = "${repo}:${tag}"
    # Plain rmi by repo:tag, never -f: -f would untag EVERY tag sharing the
    # image ID (a user's backup tag included). An image still referenced by
    # a container refuses politely and stays.
    Invoke-NativeQuiet "docker" @("rmi", $ref)
    if ($LASTEXITCODE -eq 0) {
      Write-Info "Removed image $ref"
      Emit-Log "docker" "removed image $ref"
      $removedImages++
    } else {
      Write-Info "Left image $ref in place (still referenced, or removal failed)"
      Emit-Log "docker" "left image $ref in place (still referenced, or removal failed)"
      $keptImages++
    }
  }
  if ($removedImages -eq 0 -and $keptImages -eq 0) {
    Write-Info "No syrus images found."
    Emit-Step "docker_images" "ok" "none found"
  } elseif ($keptImages -eq 0) {
    Emit-Step "docker_images" "ok" "$removedImages removed"
  } else {
    Emit-Step "docker_images" "ok" "$removedImages removed, $keptImages left in place"
  }
} else {
  Write-Info "Docker is not reachable - skipping containers, volumes, and images."
  Emit-Log "docker" "docker unavailable; skipping container, volume, and image removal"
  Emit-Step "docker_down" "skipped" "docker unavailable"
  Emit-Step "docker_images" "skipped" "docker unavailable"
  Add-Partial "docker unreachable: containers, volumes, and images were not removed"
}

# ---------------------------------------------------------------------------
# 2. Files: install state, credentials, CLI (binary + PATH entry), skill.
Write-HumanStep "Files"
if ($script:KeepData) {
  Emit-Step "state_dir" "skipped" "--keep-data"
  Emit-Step "credentials" "skipped" "--keep-data"
} else {
  if ($script:VolumesVerifiedGone) {
    Remove-PathStep "state_dir" $stateDir "install state (encryption keys, .env, compose file, install log)"
  } elseif (Test-Path -LiteralPath $stateDir) {
    # THE ENCRYPTION-KEY GATE: the data volumes were NOT verifiably removed
    # (Docker unreachable, or a volume survived teardown). Deleting the .env
    # now would strand an encrypted volume with no keys - the installer's
    # encryption-key guard would then refuse every reinstall, and the
    # compose file needed for `docker compose down -v` would be gone too.
    # Keep the whole directory; starting Docker and re-running this
    # uninstaller finishes.
    Write-Info "WARNING: keeping $stateDir - the syrus docker data volumes were not"
    Write-Info "         verifiably removed, and its .env holds the only ENCRYPTION"
    Write-Info "         KEYS for them. Start Docker and re-run this uninstaller to"
    Write-Info "         remove the volumes and then the keys."
    Emit-Log "files" "kept ${stateDir}: data volumes not verifiably removed; start Docker and re-run to finish"
    Emit-Step "state_dir" "failed" "kept: data volumes not verifiably removed"
    Add-Partial "kept $stateDir (encryption keys) until the docker data volumes are removed"
  } else {
    Emit-Step "state_dir" "skipped" "not present"
  }
  Remove-PathStep "credentials" $credentialsFile "app/CLI credentials"
}

if ((Test-Path -LiteralPath $cliExe) -or (Test-Path -LiteralPath $cliExeOld)) {
  Emit-Step "cli" "start"
  Remove-Item -LiteralPath $cliExe -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $cliExeOld -Force -ErrorAction SilentlyContinue
  if ((Test-Path -LiteralPath $cliExe) -or (Test-Path -LiteralPath $cliExeOld)) {
    Write-Info "WARNING: could not fully remove the syrus CLI: $cliExe"
    Emit-Log "files" "failed to remove $cliExe"
    Emit-Step "cli" "failed" "could not remove $cliExe"
    Add-Partial "could not remove $cliExe"
  } else {
    Write-Info "Removed the syrus CLI: $cliExe"
    Emit-Log "files" "removed $cliExe"
    Emit-Step "cli" "ok"
  }
} else {
  Emit-Step "cli" "skipped" "not present"
}
# Empty-only cleanup of the CLI's directory chain (the LocalAppData Syrus dir
# may be shared if anything else ever lands there - never force it).
foreach ($dir in @($cliDir, (Join-Path $localAppData "Syrus"))) {
  if ((Test-Path -LiteralPath $dir) -and (@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
  }
}

Emit-Step "path_cleanup" "start"
$pathRemoved = $false
try { $pathRemoved = Remove-FromWindowsUserPath $cliDir } catch { $pathRemoved = $false }
if ($pathRemoved) {
  Write-Info "Removed $cliDir from the per-user PATH (HKCU\Environment)."
  Emit-Log "files" "removed $cliDir from HKCU Path"
  Emit-Step "path_cleanup" "ok"
} else {
  Emit-Step "path_cleanup" "skipped" "no PATH entry"
}

Remove-PathStep "skill" $skillDir "the Claude Code skill"

# ---------------------------------------------------------------------------
# 3. App settings, the setup-resume RunOnce hook, then the app itself LAST
#    (its NSIS uninstaller can take the elevated context down with it).
Write-HumanStep "Desktop app"
if ($script:KeepData) {
  Emit-Step "app_settings" "skipped" "--keep-data"
} else {
  Remove-PathStep "app_settings" $settingsDir "desktop app settings"
}

$runOnceEntry = $null
try { $runOnceEntry = Get-ItemProperty -Path $runOncePath -Name "SyrusResumeSetup" -ErrorAction SilentlyContinue } catch { $runOnceEntry = $null }
if ($runOnceEntry) {
  Emit-Step "runonce" "start"
  Remove-ItemProperty -Path $runOncePath -Name "SyrusResumeSetup" -ErrorAction SilentlyContinue
  Write-Info "Removed the SyrusResumeSetup RunOnce entry."
  Emit-Log "files" "removed the SyrusResumeSetup RunOnce entry"
  Emit-Step "runonce" "ok"
} else {
  Emit-Step "runonce" "skipped" "not present"
}

# Empty-only cleanup of ~\.syrus (a bare-metal clone cache - or the
# encryption keys kept by the gate above - may still live in it) - before
# the NSIS handoff, mirroring uninstall.sh's rmdir.
if ((Test-Path -LiteralPath $syrusDir) -and (@(Get-ChildItem -LiteralPath $syrusDir -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
  Remove-Item -LiteralPath $syrusDir -Force -ErrorAction SilentlyContinue
}

$uninstaller = $null
if (Test-Path -LiteralPath $nsisDir) {
  $uninstaller = Get-ChildItem -LiteralPath $nsisDir -Filter "Uninstall*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($uninstaller) {
  Emit-Step "desktop_app" "start"
  Write-Info "Quit Syrus if it is running, then let the uninstaller finish."
  Write-Info "Running the desktop app's NSIS uninstaller silently (/S)..."
  Emit-Log "files" "running the NSIS uninstaller: $($uninstaller.FullName)"
  # LAST on purpose, and not waited on: the uninstaller deletes the app
  # directory we may have been launched from and can take this console's
  # context with it. Everything above has already happened.
  Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S"
  Emit-Step "desktop_app" "ok"
} elseif (Test-Path -LiteralPath $nsisDir) {
  Write-Info "No NSIS uninstaller found in $nsisDir - remove Syrus via Settings > Apps."
  Emit-Log "files" "no NSIS uninstaller found; use Settings > Apps"
  Emit-Step "desktop_app" "skipped" "no uninstaller found; use Settings > Apps"
} else {
  Emit-Step "desktop_app" "skipped" "not present"
}

if ($script:Partial) {
  $reasons = ($script:PartialReasons -join "; ")
  Write-HumanStep "Done - with warnings"
  Write-Info "Syrus was only PARTIALLY removed: $reasons"
  Write-Info "Re-run this uninstaller after fixing the above (usually: start Docker)."
  [Console]::Error.WriteLine("Warning: partial uninstall - $reasons")
  Emit-Json ([ordered]@{ event = "error"; code = 3; step = $script:CurrentStep; message = (Remove-ControlChars ("partial uninstall: " + $reasons)) })
  exit 3
}

Write-HumanStep "Done"
Write-Info "Syrus has been removed."
Write-Info "NOT touched: Docker Desktop - a shared tool with its own uninstaller."
Emit-Json ([ordered]@{ event = "done" })
exit 0
