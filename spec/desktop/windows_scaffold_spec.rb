# frozen_string_literal: true

require "json"
require "spec_helper"

# Phase 1 of the Windows port (docs/windows-desktop-plan.md): packaging,
# platform seams, and runtime guidance exist; the local-install path is
# explicitly guarded until the PowerShell installer lands. These specs pin
# the seams so mac-only assumptions don't creep back in.
RSpec.describe "desktop Windows scaffold" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }
  let(:repo_root) { File.expand_path("../..", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  it "documents the plan the scaffold implements" do
    plan = File.read(File.join(repo_root, "docs/windows-desktop-plan.md"), encoding: "UTF-8")
    expect(plan).to include("NSIS one-click")
    expect(plan).to include("Podman Desktop")
    expect(plan).to include("UTM")
  end

  it "pins electron-builder past the arm64 PE-skip bug" do
    # electron-builder 26.15.0–26.15.5 packed arm64 NSIS payloads with a
    # 7-Zip ARM64 branch filter the install-time Nsis7z decoder can't
    # decode — every .exe/.dll was silently skipped (exit 0, no error)
    # while data files extracted, i.e. an installed app with no binaries.
    # electron-userland/electron-builder#9983, fixed in 26.15.6. Cost us a
    # full field-debugging round that blamed Defender; never regress it.
    lock = JSON.parse(read("package-lock.json"))
    version = lock.dig("packages", "node_modules/electron-builder", "version")
    expect(Gem::Version.new(version)).to be >= Gem::Version.new("26.15.6")
  end

  it "packages a per-user NSIS one-click installer with the brand .ico (x64 only)" do
    config = read("electron-builder.yml")
    expect(config).to include("icon: build/icon.ico")
    # x64 only — arm64 Windows runs it via emulation, so one installer covers all.
    expect(config).to match(/win:[\s\S]{0,600}- target: nsis\s+arch: \[x64\]/)
    expect(config).to match(/nsis:\s+oneClick: true\s+perMachine: false/)
    expect(File).to exist(File.join(desktop_root, "build/icon.ico"))
    expect(File).to exist(File.join(desktop_root, "scripts/make-ico.mjs"))
    # electron-updater cannot auto-update MSI installs; NSIS is the canonical
    # Windows artifact (see the plan doc) — no msi target without a decision.
    expect(config).not_to include("msi")
  end

  it "guards the one-click launch with a post-extraction executable check" do
    # Without this, a missing exe (Defender quarantining the unsigned
    # binary right after extraction) surfaces as the shell's baffling
    # "Missing Shortcut" dialog — the installer must fail with guidance
    # instead. See docs/windows-desktop-plan.md field notes.
    config = read("electron-builder.yml")
    expect(config).to include("include: build/installer.nsh")
    expect(config).to include("installerHeaderIcon: build/icon.ico")
    expect(config).to include("installerIcon: build/icon.ico")

    guard = read("build/installer.nsh")
    expect(guard).to include("!macro customInstall")
    expect(guard).to include('${ifNot} ${FileExists} "$INSTDIR\\${APP_EXECUTABLE_FILENAME}"')
    expect(guard).to include("Protection history")
    expect(guard).to include("SetErrorLevel 2")
    # Silent installs (/S) must not hang on a MessageBox.
    expect(guard).to match(/\$\{ifNot\} \$\{Silent\}\s*\n\s*MessageBox/)
  end

  it "ships no build-only packages in the Windows payload" do
    # electron-builder packs package.json "dependencies" into the asar;
    # tailwind (and its darwin native binaries) is build-time only.
    package = JSON.parse(read("package.json"))
    expect(package.fetch("dependencies").keys).not_to include("tailwindcss", "@tailwindcss/vite")
    expect(package.fetch("devDependencies").keys).to include("tailwindcss", "@tailwindcss/vite")
  end

  it "keeps the macOS-only titleBarStyle off other platforms" do
    onboarding_window = read("electron/windows/onboardingWindow.ts")
    expect(onboarding_window).to match(/process\.platform === "darwin" \? \{ titleBarStyle: "hiddenInset"/)
  end

  it "detects Windows Docker runtimes; installing Podman is never recommended" do
    runtime = read("electron/installer/dockerRuntime.ts")
    expect(runtime).to include('process.platform === "win32"')
    expect(runtime).to include("docker.exe")
    # An already-installed Podman Desktop is detected and startable (its
    # Docker socket works), but the guided setup's download recommendation
    # is Docker-Desktop-only — no install suggestion, no download URL.
    expect(runtime).to include("Podman Desktop.exe")
    expect(runtime).not_to include("podman-desktop.io")
    expect(runtime).to include("path.delimiter")
  end

  it "drives the local install through the platform-selected installer script" do
    paths = read("electron/installer/installPaths.ts")
    expect(paths).to match(/process\.platform === "win32" \? "install\.ps1" : "install\.sh"/)
    # -File (not -Command) so the script's exit code propagates.
    expect(paths).to match(/"-ExecutionPolicy", "Bypass", "-File"/)

    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include("installerCommand(installerScriptPath()")
    # Cancel must kill the whole tree: POSIX process groups don't exist on
    # Windows, so taskkill /T walks it there.
    expect(driver).to include('["/pid", String(this.child.pid), "/T", "/F"]')
    # The image-update path IS the installer and must share the seam.
    expect(read("electron/installer/backendLifecycle.ts")).to include("installerCommand(installerScriptPath()")
  end

  it "notifies reliably on Windows (AUMID matches the NSIS shortcut identity)" do
    main = read("electron/main.ts")
    expect(main).to include('app.setAppUserModelId("app.syrus.desktop")')
    expect(read("electron-builder.yml")).to include("appId: app.syrus.desktop")
  end

  it "positions the tray popover inside the work area (bottom taskbars open upward)" do
    # The main.ts wrapper gathers tray/window/screen state; the arithmetic is
    # a pure module so vitest covers the open-above flip and the clamps
    # behaviorally (desktop/src/popoverPosition.test.ts).
    main = read("electron/main.ts")
    position = main[/const popoverPosition[\s\S]{0,1600}/]
    expect(position).to include("getDisplayNearestPoint")
    expect(position).to include("workArea")
    expect(position).to include("computePopoverPosition")

    math = read("electron/windows/popoverPosition.ts")
    expect(math).to include("workArea")
    expect(math).to match(/trayBounds\.y - windowBounds\.height/)
  end

  it "uses the full-color tray icon with a bitmap badge on Windows" do
    main = read("electron/main.ts")
    expect(main).to match(/process\.platform === "win32" \? "syrusIcon\.png" : "syrusMenubarTemplate\.png"/)
    # nativeImage cannot rasterize SVG data URLs (blank icon on Windows);
    # the unread dot is drawn into the BGRA bitmap directly.
    expect(main).to include("createFromBitmap")
    expect(main).not_to include("image/svg+xml")
    # The pixel writes live in an Electron-free module so vitest can pin the
    # BGRA bytes (desktop/src/trayBadge.test.ts); createFromBitmap stays here.
    expect(main).to include("paintUnreadDot")
    badge = read("electron/trayBadge.ts")
    expect(badge).to include("0xdc")
    expect(badge).not_to include("image/svg+xml")
  end

  it "exposes the platform to the renderer so onboarding can adapt" do
    expect(read("electron/preload.cts")).to include("platform: process.platform")
    expect(read("src/vite-env.d.ts")).to include("platform: string")
    welcome = read("src/onboarding/Welcome.tsx")
    # Both install paths are real choices on Windows now (install.ps1).
    expect(welcome).to include("Install on this PC")
    runtime_setup = read("src/onboarding/RuntimeSetup.tsx")
    expect(runtime_setup).to include("Docker Desktop")
    # Podman compose isn't supported — the guided setup must not claim it.
    expect(runtime_setup).not_to include("Podman")
  end

  it "resumes onboarding after a Docker/WSL install forces a Windows reboot" do
    # Field failure: Docker Desktop's installer rebooted Windows mid-setup and
    # Syrus never came back — the user restarted the wizard from scratch. Two
    # halves: HKCU RunOnce relaunches the app at the next logon, and the
    # persisted onboardingResumeLocal flag (source of truth — manual relaunches
    # resume too) jumps straight back into the local flow.
    resume = read("electron/installer/windowsResume.ts")
    expect(resume).to include("HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\RunOnce")
    expect(resume).to include("SyrusResumeSetup")
    # Quoted exe path — profile directories contain spaces.
    expect(resume).to include('`"${execPath}" --resume-setup`')

    expect(read("electron/settings.ts")).to include("onboardingResumeLocal")

    driver = read("electron/installer/installerDriver.ts")
    # Armed at BOTH reboot-risk points: the Docker Desktop download handoff
    # and the one-click WSL install.
    expect(driver.scan("this.armRebootResume()").length).to be >= 2
    # Cleared when onboarding resolves (done or a deliberate back-to-welcome).
    expect(driver).to include("this.clearRebootResume()")

    main = read("electron/main.ts")
    expect(main).to match(/getOnboardingResumeLocal\(\)[\s\S]{0,120}chooseMode\("local"\)/)
  end

  it "detects per-user Docker Desktop installs and guides its first-run setup" do
    runtime = read("electron/installer/dockerRuntime.ts")
    # Docker Desktop's `--user` install lands under %LOCALAPPDATA% — probing
    # only Program Files reads a per-user install as "no runtime". Fixed paths
    # (not PATH) are load-bearing: the Electron process never sees PATH
    # changes made after it launched, which is why docker worked in a fresh
    # cmd while the app said no docker.
    expect(runtime).to include('"Programs", "DockerDesktop", "resources", "bin"')
    expect(runtime).to include('"Programs", "DockerDesktop", "Docker Desktop.exe"')

    # First-start attention: after a quiet 30s the wizard must say exactly
    # what to click in Docker Desktop (accept the agreement; sign-in is
    # skippable) instead of spinning on "Starting…" — and the deadline
    # extends so the user isn't timed out mid-dialog.
    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include("RUNTIME_ATTENTION_POLLS")
    expect(driver).to include("RUNTIME_FIRST_START_POLLS")
    expect(driver).to match(/needsAttention: true/)

    runtime_setup = read("src/onboarding/RuntimeSetup.tsx")
    expect(runtime_setup).to include("runtime-attention")
    expect(runtime_setup).to include("service agreement")
    expect(runtime_setup).to match(/Open \{runtimeName\}/)
  end

  it "installs Docker Desktop itself: unattended, per-user, license pre-accepted" do
    # The auto-install kills the field failure at the root: --accept-license
    # removes the first-start service-agreement dialog entirely, and --user
    # installs per-user with NO admin elevation (no UAC) to the
    # %LOCALAPPDATA%\Programs\DockerDesktop location detection already probes.
    installer = read("electron/installer/dockerDesktopInstaller.ts")
    expect(installer).to include('"--accept-license"')
    expect(installer).to include('"--user"')
    expect(installer).to include('"--backend=wsl-2"')
    expect(installer).to include('"--quiet"')
    # Official permanent links, both real hardware architectures (the x64-only
    # app runs emulated on arm64 Windows — PROCESSOR_ARCHITEW6432 disambiguates).
    expect(installer).to include("https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe")
    expect(installer).to include("https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe")
    expect(installer).to include("PROCESSOR_ARCHITEW6432")
    # Per-user needs no elevation — no UAC round-trip in this path.
    expect(installer).not_to include("-Verb RunAs")

    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include("local.runtimeInstalling")
    # A Docker install can still end in a WSL reboot — the resume save point
    # arms before the installer runs.
    expect(driver).to match(/async installRuntime\(\)[\s\S]{0,400}armRebootResume\(\)/)

    runtime_setup = read("src/onboarding/RuntimeSetup.tsx")
    expect(runtime_setup).to include("Install Docker Desktop")
    expect(runtime_setup).to include("runtime-auto-install")
    # Manual download survives as the fallback for cautious users / failures.
    expect(runtime_setup).to include("download manually instead")
  end

  it "preflights WSL 2 with a one-click elevated install and reboot guidance" do
    runtime = read("electron/installer/dockerRuntime.ts")
    expect(runtime).to include("export const wslReady")
    expect(runtime).to match(/wsl\.exe.*--status|"wsl\.exe", \["--status"\]/)
    # Elevation is unavoidable (UAC); the default distro is skipped because
    # Docker Desktop brings its own.
    expect(runtime).to include("'--install','--no-distribution'")
    expect(runtime).to include("-Verb RunAs")

    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include("wslMissing: !(await wslReady())")
    expect(read("electron/main.ts")).to include('ipcMain.handle("onboarding:install-wsl"')

    runtime_setup = read("src/onboarding/RuntimeSetup.tsx")
    expect(runtime_setup).to include("Install WSL 2")
    # Docker Desktop and WSL installs can both require a Windows restart;
    # the copy must say the flow picks up again afterwards.
    expect(runtime_setup.scan("picks up right here").length).to be >= 2
  end
end
