# Install Syrus on this Windows machine. One way to run it:
#
#   --docker       Pull the prebuilt image (ghcr.io/tkadauke/syrus-backend) and
#                  start web + worker with Compose. Nothing compiles. Requires
#                  Docker Desktop (or a Docker-compatible runtime such as
#                  Podman Desktop with its Docker socket enabled).
#
# --bare-metal is the macOS-only source install (see install.sh) and is
# rejected here. With no mode flag, the script asks. The docker path is
# idempotent - safe to re-run. The in-app first-run wizard handles
# GitHub/agent/repo credentials.
#
# This file is the PowerShell port of install.sh's --docker machine interface.
# The desktop app drives both headlessly, so the NDJSON protocol, step ids,
# and exit codes MUST stay identical; spec/desktop/install_parity_spec.rb pins
# the shared strings - change both installers together.
#
# Target: Windows PowerShell 5.1 (inbox on every Windows 10/11 machine).
# No pwsh-7-only APIs, and keep this file pure ASCII: PS 5.1 parses BOM-less
# script files with the ANSI codepage, so any non-ASCII byte would be misread.

# NDJSON on stdout must be byte-exact UTF-8 for the GUI driver; the console
# codepage would otherwise mangle it. A missing console (headless spawn with
# fully redirected handles) is fine - ignore the failure.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Cmdlet failures are terminating (the `set -e` analog); native commands are
# NOT covered by this, so every native call site checks $LASTEXITCODE.
$ErrorActionPreference = "Stop"
# Keep Invoke-WebRequest's PS 5.1 progress rendering out of headless runs.
$ProgressPreference = "SilentlyContinue"

$script:Json = $false
$script:CurrentStep = ""
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# The script lives at the repo root (or the app's resources) - the read-only
# home of docker-compose.yml + compose.env.example.
$AssetsDir = $PSScriptRoot

$HelpText = @'
Install Syrus on this Windows machine (Docker mode only).

Usage: .\install.ps1 --docker [options]

  --docker                pull the prebuilt image and start web + worker with
                          Docker Compose; nothing compiles (needs Docker
                          Desktop or a Docker-compatible runtime)
  --start                 ignored for --docker; the Compose stack always starts
  --help                  show this message

--bare-metal is the macOS-only source install (see install.sh); on Windows
it is rejected.

Docker-mode flags for driving this script from a GUI (the desktop app):

  --non-interactive       never prompt; a missing decision is an error (exit 2)
  --json                  machine-readable NDJSON events on stdout (start, step,
                          log, error, done); human-readable output moves to stderr
  --target-dir DIR        directory that owns mutable state: .env and a synced
                          copy of docker-compose.yml; Compose runs from there.
                          Default: this script's own directory.
  --skip-runtime-install  never install a runtime; exit 10 if no container
                          runtime exists, 11 if the daemon won't start
  --image REF             pin SYRUS_IMAGE; persisted into .env so later plain
                          `docker compose up` runs use the same tag
  --port N                first install only: serve on this port instead of 3000

Exit codes: 0 ok - 2 usage - 10 no runtime - 11 daemon never became ready -
12 no compose - 20 data volume exists but .env is missing (encryption-key
guard) - 30 image pull failed (network/other) - 31 image pull denied (private
package / unpublished tag / not logged in) - 32 image tag not found in the
registry - 40 compose up failed - 41 health check timed out - 1 anything else
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
  # install.sh's json_escape exactly: TAB and LF survive (ConvertTo-Json
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

function Invoke-NativeQuiet {
  # Run a native command discarding all output; exit code lands in
  # $LASTEXITCODE. EAP is relaxed locally because under Stop, PS 5.1 turns
  # redirected native stderr into a terminating NativeCommandError.
  param([string]$Exe, [string[]]$CommandArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try { & $Exe @CommandArgs *> $null } finally { $ErrorActionPreference = $prev }
}

function Invoke-LoggedCommand {
  # run_logged / run_logged_captured: stream a native command's merged
  # stdout+stderr as `log` events in --json mode (or plain lines otherwise)
  # and return the lines for failure classification. Exit code is left in
  # $LASTEXITCODE. Same local EAP relaxation as Invoke-NativeQuiet.
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

function New-HexSecret {
  # CSPRNG hex - the `openssl rand -hex N` analog. The one-call hex-string
  # convenience API is pwsh 7+ only, so format each byte by hand for PS 5.1.
  param([int]$ByteCount)
  $bytes = New-Object byte[] $ByteCount
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return (($bytes | ForEach-Object { "{0:x2}" -f $_ }) -join "")
}

function Write-EnvFile {
  # PS 5.1 file-writing defaults (UTF-16 / BOM / CRLF) would corrupt the
  # encryption keys the Rails container reads back as raw bytes; write
  # BOM-less UTF-8 explicitly. Callers pass LF-normalized content.
  param([string]$Path, [string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Add-DockerCliPath {
  # GUI-launched processes may lack a login PATH; make Docker Desktop's CLI
  # directory searchable no matter who spawned us (install.sh does the same
  # for orbstack/homebrew/Docker.app on macOS).
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

# Make sure a container runtime is installed AND its daemon is reachable. This
# port never installs a runtime (the GUI owns runtime acquisition on Windows),
# but it does start an installed-but-stopped Docker Desktop, then waits for
# the daemon - mirroring install.sh's ensure_docker_runtime.
function Ensure-DockerRuntime {
  Emit-Step "runtime_check" "start"
  if (Test-DockerDaemon) {
    Write-Info "Docker runtime is up."
    Emit-Step "runtime_check" "ok"
    # The GUI ensures the daemon is up before spawning us, so this is the
    # common path - resolve the start step so its checklist row never
    # dangles as pending.
    Emit-Step "runtime_start" "skipped"
    return
  }
  Emit-Step "runtime_check" "ok" "runtime not ready yet"

  $desktopExe = ""
  if ($env:ProgramFiles) { $desktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe" }
  $hasDesktop = [bool]($desktopExe -and (Test-Path -LiteralPath $desktopExe))
  $hasCli = [bool](Get-Command "docker" -ErrorAction SilentlyContinue)

  if (-not $hasCli -and -not $hasDesktop) {
    # With or without --skip-runtime-install the answer is the same on
    # Windows (no unattended runtime install): point at Docker Desktop, stop.
    Emit-Step "runtime_install" "start"
    if (-not $script:SkipRuntimeInstall) {
      Write-Info "Unattended runtime install is not supported on Windows; install one manually."
    }
    Fail "No container runtime found. Install Docker Desktop (https://www.docker.com/products/docker-desktop/), then retry." 10
  }

  if ($hasDesktop) {
    Write-Info "A container runtime is installed but not running - starting Docker Desktop..."
    Start-Process -FilePath $desktopExe
  } else {
    Fail "A docker CLI exists but no runtime app to start. Start your runtime and re-run." 11
  }

  Emit-Step "runtime_start" "start"
  Write-Info "Waiting for the Docker daemon (first Docker Desktop launch may show a setup prompt)..."
  $tries = 0
  while (-not (Test-DockerDaemon)) {
    $tries++
    if ($tries -gt 90) {
      Fail "Docker daemon didn't come up. Open Docker Desktop, finish any setup prompt, then re-run." 11
    }
    Add-DockerCliPath   # docker.exe becomes resolvable once Desktop materializes it
    Start-Sleep -Seconds 2
  }
  Write-Info "Docker daemon is up."
  Emit-Step "runtime_start" "ok"
}

# ===========================================================================
function Run-Docker {
  if ($script:StartAfter) {
    Write-Info "(--start is ignored for --docker; the Compose stack always starts.)"
  }

  $image = $script:ImageOverride
  if (-not $image) { $image = $env:SYRUS_IMAGE }
  if (-not $image) { $image = "ghcr.io/tkadauke/syrus-backend:latest" }
  $env:SYRUS_IMAGE = $image
  # Belt-and-braces alongside the compose file's `name: syrus`: keeps the
  # `syrus_` volume prefix stable for docker-compose v1 and odd invocation dirs.
  $env:COMPOSE_PROJECT_NAME = "syrus"

  # The target dir owns mutable state (.env, a synced copy of
  # docker-compose.yml). Default: the script's own directory. The desktop app
  # passes --target-dir because its install dir is read-only.
  if ($script:TargetDir) {
    New-Item -ItemType Directory -Force -Path $script:TargetDir | Out-Null
    $resolved = (Resolve-Path -LiteralPath $script:TargetDir).Path
    # Keep the compose file in sync with this installer's version on every run.
    Copy-Item -LiteralPath (Join-Path $AssetsDir "docker-compose.yml") -Destination (Join-Path $resolved "docker-compose.yml") -Force
    Set-Location -LiteralPath $resolved
  }
  # PowerShell's location and .NET's process cwd are separate; align them so
  # file IO and child processes (compose reads .env from its cwd) agree.
  $workDir = (Get-Location).Path
  [Environment]::CurrentDirectory = $workDir
  $envFile = Join-Path $workDir ".env"

  Emit-Json ([ordered]@{ event = "start"; mode = "docker"; image = $image; target_dir = $workDir })

  # 1. Make sure a container runtime is installed and running.
  Write-HumanStep "Container runtime"
  Ensure-DockerRuntime

  # 2. Resolve the Compose command (Docker Desktop ships the v2 plugin).
  Emit-Step "compose_resolve" "start"
  $composeExe = $null
  $composePrefix = @()
  Invoke-NativeQuiet "docker" @("compose", "version")
  if ($LASTEXITCODE -eq 0) {
    $composeExe = "docker"
    $composePrefix = @("compose")
  } elseif (Get-Command "docker-compose" -ErrorAction SilentlyContinue) {
    $composeExe = "docker-compose"
  } else {
    Fail "Docker Compose not found. Install Docker Desktop (it bundles Compose v2) or docker-compose." 12
  }
  Emit-Step "compose_resolve" "ok"

  # 3. Generate .env with fresh secrets on first run - but NEVER mint fresh
  #    encryption keys when a data volume already exists. The existing DB was
  #    encrypted with the old keys; new keys can't decrypt it and every page
  #    500s with ActiveRecord::Encryption::Errors::Decryption.
  Emit-Step "env_check" "start"
  if (-not (Test-Path -LiteralPath $envFile)) {
    Invoke-NativeQuiet "docker" @("volume", "inspect", "syrus_syrus-data")
    if ($LASTEXITCODE -eq 0) {
      [Console]::Error.WriteLine("Error: a data volume (syrus_syrus-data) exists but .env is missing.")
      [Console]::Error.WriteLine("Its database is encrypted with keys that lived in that .env. Generating")
      [Console]::Error.WriteLine("fresh keys now would make the existing data undecryptable. Do ONE of:")
      [Console]::Error.WriteLine("  - Restore the original .env (the keys that match this volume), or")
      [Console]::Error.WriteLine("  - Wipe the old data and start clean:")
      [Console]::Error.WriteLine("      docker compose down -v; .\install.ps1 --docker")
      Fail "a data volume (syrus_syrus-data) exists but .env is missing (see above)" 20
    }
  }
  Emit-Step "env_check" "ok"

  if (-not (Test-Path -LiteralPath $envFile)) {
    Write-HumanStep "Generating .env with fresh secrets"
    Emit-Step "env_generate" "start"
    # Normalize the template to LF up front: a git checkout with autocrlf may
    # hand us CRLF, and the container reads this file back as raw bytes.
    $content = ([System.IO.File]::ReadAllText((Join-Path $AssetsDir "compose.env.example"))) -replace "`r`n", "`n"
    $content = [regex]::Replace($content, "(?m)^SECRET_KEY_BASE=.*$", ("SECRET_KEY_BASE=" + (New-HexSecret 64)))
    $content = [regex]::Replace($content, "(?m)^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*$", ("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=" + (New-HexSecret 32)))
    $content = [regex]::Replace($content, "(?m)^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*$", ("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=" + (New-HexSecret 32)))
    $content = [regex]::Replace($content, "(?m)^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*$", ("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=" + (New-HexSecret 32)))
    if ($script:PortOverride) {
      $content = [regex]::Replace($content, "(?m)^SYRUS_PORT=.*$", "SYRUS_PORT=" + $script:PortOverride)
      $content = [regex]::Replace($content, "(?m)^SYRUS_APP_HOST=.*$", "SYRUS_APP_HOST=localhost:" + $script:PortOverride)
    }
    Write-EnvFile $envFile $content
    Write-Info "Wrote .env (keep it safe - it holds your instance secrets)."
    Emit-Step "env_generate" "ok"
  } else {
    Emit-Step "env_generate" "skipped"
    if ($script:PortOverride) {
      Write-Info "(--port is ignored: .env already exists and owns the port.)"
    }
  }

  # Persist an explicit image pin so later plain `docker compose up` runs (the
  # desktop app's Start/Stop controls) use the same tag as this install.
  # Unlike --port, this intentionally updates an existing .env - app updates
  # move the pin forward - but never silently: a changed pin is announced.
  if ($script:ImageOverride) {
    $envText = ([System.IO.File]::ReadAllText($envFile)) -replace "`r`n", "`n"
    $pin = [regex]::Match($envText, "(?m)^SYRUS_IMAGE=(.*)$")
    if ($pin.Success) {
      $currentPin = $pin.Groups[1].Value
      if ($currentPin -cne $script:ImageOverride) {
        $renderedPin = if ($currentPin) { $currentPin } else { "<empty>" }
        Write-Info "Updating the SYRUS_IMAGE pin: $renderedPin -> $($script:ImageOverride)"
        Emit-Log "env" "SYRUS_IMAGE pin updated: $renderedPin -> $($script:ImageOverride)"
        # Safe splice: --image values are charset-validated at parse time, so
        # the replacement cannot contain regex substitution metacharacters.
        $envText = [regex]::Replace($envText, "(?m)^SYRUS_IMAGE=.*$", "SYRUS_IMAGE=" + $script:ImageOverride)
        Write-EnvFile $envFile $envText
      }
    } else {
      if ($envText.Length -gt 0 -and -not $envText.EndsWith("`n")) { $envText += "`n" }
      $envText += "SYRUS_IMAGE=" + $script:ImageOverride + "`n"
      Write-EnvFile $envFile $envText
    }
  }

  # 4. Pull the prebuilt image. The daemon is already known reachable, so a
  #    failure here is about the image itself - surface the real error. The
  #    download is large, so a transient network blip gets a couple of
  #    automatic retries before we give up.
  Write-HumanStep "Pulling $image"
  Emit-Step "image_pull" "start" $image
  $pullOk = $false
  # The capture file mirrors install.sh's mktemp+tee: placed under $env:TEMP
  # (GetTempPath honors it), read-then-delete before the classification.
  $pullLog = Join-Path ([System.IO.Path]::GetTempPath()) ("syrus-pull-" + [Guid]::NewGuid().ToString("N") + ".log")
  $retryDelay = 5
  if ($env:SYRUS_PULL_RETRY_DELAY) { $retryDelay = [int]$env:SYRUS_PULL_RETRY_DELAY }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $lines = @(Invoke-LoggedCommand "pull" $composeExe ($composePrefix + @("pull")))
    $pullExit = $LASTEXITCODE
    [System.IO.File]::WriteAllLines($pullLog, [string[]]$lines, $script:Utf8NoBom)
    if ($pullExit -eq 0) { $pullOk = $true; break }
    if ($attempt -lt 3) {
      Write-Info "Pull failed (attempt $attempt/3) - retrying..."
      Emit-Log "pull" "pull attempt $attempt failed; retrying"
      Start-Sleep -Seconds $retryDelay
    }
  }
  $pullError = ""
  if (Test-Path -LiteralPath $pullLog) {
    $pullError = [System.IO.File]::ReadAllText($pullLog)
    Remove-Item -LiteralPath $pullLog -Force -ErrorAction SilentlyContinue
  }
  if (-not $pullOk) {
    # A locally built or previously pulled copy still works - key for fork
    # iteration (build the image locally, install without any registry) and
    # for offline reinstalls.
    Invoke-NativeQuiet "docker" @("image", "inspect", $image)
    if ($LASTEXITCODE -eq 0) {
      Write-Info "Pull failed, but $image exists locally - continuing with the local copy."
      Emit-Log "pull" "pull failed; using the local image copy"
    } else {
      # Ordered classification of the LAST attempt's output. Denied wins over
      # not-found: GHCR's anonymous-denied message mentions both, and on GHCR
      # an unauthorized pull is indistinguishable from a missing private repo.
      [Console]::Error.WriteLine("")
      [Console]::Error.WriteLine("Couldn't pull $image. See the error above.")
      if ($pullError -cmatch "[Dd]enied|[Uu]nauthorized|authentication required|[Ff]orbidden") {
        [Console]::Error.WriteLine("The registry refused the download - the package is private, the tag was")
        [Console]::Error.WriteLine("never published, or this machine isn't logged in. Either make the package")
        [Console]::Error.WriteLine("public, or log in once:")
        [Console]::Error.WriteLine("    echo <YOUR_PAT_with_read:packages> | docker login ghcr.io -u <your-username> --password-stdin")
        [Console]::Error.WriteLine("Then re-run .\install.ps1 --docker.")
        Fail "access to $image was denied (private package, unpublished tag, or not logged in)" 31
      } elseif ($pullError -cmatch "manifest unknown|not found") {
        [Console]::Error.WriteLine("The package exists but this tag doesn't - the build that produced this")
        [Console]::Error.WriteLine("installer references an image that was never published.")
        Fail "the image tag $image does not exist in the registry" 32
      } else {
        [Console]::Error.WriteLine("This usually means a network problem. Check your connection and re-run")
        [Console]::Error.WriteLine(".\install.ps1 --docker.")
        Fail "couldn't pull $image after 3 attempts" 30
      }
    }
  }
  Emit-Step "image_pull" "ok"

  # 5. Start the stack.
  Write-HumanStep "Starting Syrus"
  Emit-Step "stack_up" "start"
  $null = Invoke-LoggedCommand "up" $composeExe ($composePrefix + @("up", "-d"))
  if ($LASTEXITCODE -ne 0) { Fail "docker compose up failed" 40 }
  Emit-Step "stack_up" "ok"

  # A hand-written/adopted .env may lack SYRUS_PORT - default to 3000.
  $port = "3000"
  $portText = ([System.IO.File]::ReadAllText($envFile)) -replace "`r`n", "`n"
  $portMatch = [regex]::Match($portText, "(?m)^SYRUS_PORT=(.*)$")
  if ($portMatch.Success -and $portMatch.Groups[1].Value.Trim()) {
    $port = $portMatch.Groups[1].Value.Trim()
  }

  # 6. Wait until the web app actually answers, so success means "usable",
  #    not just "containers created". First boot runs migrations.
  Emit-Step "health" "start"
  Write-Info "Waiting for Syrus to answer at http://localhost:$port ..."
  $maxPolls = 90
  if ($env:SYRUS_HEALTH_POLLS) { $maxPolls = [int]$env:SYRUS_HEALTH_POLLS }
  $tries = 0
  while ($true) {
    $healthy = $false
    try {
      $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://localhost:$port/up"
      $healthy = $true
    } catch {
      $healthy = $false
    }
    if ($healthy) { break }
    $tries++
    if ($tries -gt $maxPolls) {
      Fail "Syrus didn't become healthy within 3 minutes. Check: docker compose logs web worker" 41
    }
    Start-Sleep -Seconds 2
  }
  Emit-Step "health" "ok"
  Emit-Json ([ordered]@{ event = "done"; url = "http://localhost:$port" })

  # In --json mode stdout is protocol-only; the blank spacer line must not
  # leak into the NDJSON stream.
  if (-not $script:Json) { [Console]::Out.WriteLine("") }
  Write-Info "Syrus is running at http://localhost:$port"
  Write-Info "Next steps:"
  Write-Info "  1. Open http://localhost:$port and create the first admin account."
  Write-Info "  2. Complete /onboarding: GitHub credentials, agent, first repository."
  Write-Info "  3. Logs: docker compose logs -f web worker   Stop: docker compose down"
  Write-Info "  4. Read README.md or website docs for next steps."
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
# Mutable state defaults to living next to the script, exactly like
# install.sh's `cd "$(dirname "$0")"`.
Set-Location -LiteralPath $AssetsDir

$script:Mode = ""
$script:StartAfter = $false
$script:NonInteractive = $false
$script:SkipRuntimeInstall = $false
$script:TargetDir = ""
$script:ImageOverride = ""
$script:PortOverride = ""

# Walk the raw arg list by hand (no param() block): GNU-style two-token flags
# (--target-dir DIR) and exact usage exit codes need manual control.
$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
  $arg = [string]$argv[$i]
  switch -CaseSensitive ($arg) {
    "--docker" { $script:Mode = "docker" }
    "--bare-metal" { $script:Mode = "bare-metal" }
    "--bare" { $script:Mode = "bare-metal" }
    "--start" { $script:StartAfter = $true }
    "--non-interactive" { $script:NonInteractive = $true }
    "--json" { $script:Json = $true }
    "--skip-runtime-install" { $script:SkipRuntimeInstall = $true }
    "--target-dir" {
      if ($i + 1 -ge $argv.Count) { Fail "--target-dir needs a path" 2 }
      $i++
      $script:TargetDir = [string]$argv[$i]
    }
    "--image" {
      if ($i + 1 -ge $argv.Count) { Fail "--image needs an image reference" 2 }
      $i++
      $candidate = [string]$argv[$i]
      # Validated because the value is spliced into a regex replacement below;
      # docker references never contain such metacharacters anyway. \z (not $)
      # because .NET's $ would accept a trailing newline that bash rejects.
      if ($candidate -cnotmatch "^[A-Za-z0-9._/:@-]+\z") { Fail "--image must be a plain image reference, got: $candidate" 2 }
      $script:ImageOverride = $candidate
    }
    "--port" {
      if ($i + 1 -ge $argv.Count) { Fail "--port needs a number" 2 }
      $i++
      $candidate = [string]$argv[$i]
      if ($candidate -cnotmatch "^[0-9]+\z") { Fail "--port must be a number, got: $candidate" 2 }
      $script:PortOverride = $candidate
    }
    "--help" { Show-Help; exit 0 }
    "-h" { Show-Help; exit 0 }
    default { Fail "Unknown flag: $arg (try --help)" 2 }
  }
  $i++
}

# Ask when no mode was given.
if (-not $script:Mode) {
  if ($script:NonInteractive) {
    Fail "No mode given. Pass --docker." 2
  }
  $interactive = $false
  try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
  if (-not $interactive) {
    Fail "No mode given and not an interactive shell. Pass --docker." 2
  }
  [Console]::Out.WriteLine("How should Syrus run on this machine?")
  [Console]::Out.WriteLine("  1) Docker - pull a prebuilt image; nothing compiles (needs Docker Desktop)")
  $choice = Read-Host "Choose [1]"
  if ($choice -eq "1" -or $choice -eq "") { $script:Mode = "docker" }
  else { Fail "Invalid choice: '$choice'. Pass --docker." 2 }
}

# The bare-metal source install is macOS-only (install.sh); Windows is
# Docker-only, so the GUI-flags-only-for-docker guard is subsumed here.
if ($script:Mode -eq "bare-metal") {
  Fail "--bare-metal is not supported on Windows. Use --docker." 2
}

Run-Docker
exit 0
