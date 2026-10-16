# frozen_string_literal: true

require "spec_helper"

# The first-run onboarding drives install.sh headlessly. These assertions pin
# the contract between the Electron installer driver and the script's machine
# interface (flags, exit codes, NDJSON events), plus the safety rails around
# the encryption-key guard.
RSpec.describe "desktop onboarding installer" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:driver) { read("electron/installer/installerDriver.ts") }
  let(:docker_runtime) { read("electron/installer/dockerRuntime.ts") }
  let(:install_paths) { read("electron/installer/installPaths.ts") }
  let(:onboarding_window) { read("electron/windows/onboardingWindow.ts") }
  let(:main_process) { read("electron/main.ts") }
  let(:preload) { read("electron/preload.cts") }
  let(:renderer_entry) { read("src/main.tsx") }

  it "spawns the platform-selected installer headlessly with a scrubbed env" do
    # POSIX keeps the detached process group (cancel signals the whole tree);
    # Windows spawns hidden and cancels via taskkill /T.
    expect(driver).to include("installerCommand(installerScriptPath()")
    expect(driver).to include("spawn(command, spawnArgs, { env, detached: true })")
    expect(driver).to include("spawn(command, spawnArgs, { env, windowsHide: true })")
    # A stray spec knob in the user's environment must not gate a real install.
    expect(driver).to include("delete env.SYRUS_HEALTH_POLLS")
    expect(driver).to include("delete env.SYRUS_PULL_RETRY_DELAY")
    %w[--docker --non-interactive --json --skip-runtime-install --target-dir].each do |flag|
      expect(driver).to include(%("#{flag}"))
    end
  end

  it "forwards the channel's Compose project (and pauses polling for a test stack)" do
    # The load-bearing cross-channel isolation: without --project, a test-channel
    # install runs install.sh on the built-in default project "syrus" and adopts
    # the PRODUCTION stack/volume. --pause-polling keeps a fresh test stack from
    # racing production to file Jobs. Pinned here so deleting either push fails a
    # spec (install_sh_gui_spec only proves the SCRIPT accepts the flags).
    expect(driver).to include('flags.push("--project", identity.project)')
    expect(driver).to match(/identity\.channel === "test"[\s\S]{0,80}flags\.push\("--pause-polling"\)/)
  end

  it "augments PATH for GUI-spawned docker invocations" do
    expect(docker_runtime).to include('".orbstack", "bin"')
    expect(docker_runtime).to include("/Applications/Docker.app/Contents/Resources/bin")
    expect(driver).to include("execEnv()")
  end

  it "resolves bundled assets from the sealed Resources dir when packaged" do
    expect(install_paths).to include('path.join(process.resourcesPath, "backend")')
    expect(install_paths).to include("manifest.json")
  end

  it "maps installer exit codes onto recovery states" do
    # 10 = no runtime at all -> guided download; 11 = runtime present but
    # daemon never ready -> accurate failure, NOT the download screen.
    expect(driver).to include("if (code === 10)")
    expect(driver).to match(/code === 11[\s\S]{0,200}installed but its daemon never became ready/)
    expect(driver).to include("if (code === 20)")
    expect(driver).to match(/code === 20.*adoptExisting/m)
    expect(driver).to include('"local.failed"')
  end

  it "persists the backend config only on a successful install" do
    expect(driver).to match(/code === 0[\s\S]*?saveBackendConfig\(\{\s*mode: "local"/)
  end

  it "cancels the whole process group and finalizes only after stdio drains" do
    expect(driver).to include('process.kill(-this.child.pid, "SIGTERM")')
    expect(driver).to include('child.on("close", (code) => {')
    expect(driver).not_to include('child.on("exit"')
    expect(driver).to match(/cancelRequested[\s\S]*?\{ phase: "welcome" \}/)
  end

  it "waits for Docker Desktop tree termination before aborting its parent" do
    back_fn = driver[/  async backToWelcome\(\) \{[\s\S]*?\n  \}/]
    expect(back_fn).to match(/await stopDockerDesktopInstaller[\s\S]+?installAbort = null/)
    expect(main_process).to include("await ensureOnboardingDriver().backToWelcome()")
  end

  it "serializes installer startup before the child exists" do
    expect(driver).to include("if (this.child || this.installPromise) return")
    expect(driver).to match(/const promise = this\.performStartInstall[\s\S]+?this\.installPromise = promise/)
    expect(driver).to include("if (this.child === child) this.child = null")
    expect(main_process).to match(/onboarding:start-install[\s\S]{0,180}phase !== "local\.portConflict"/)
  end

  it "invalidates in-flight daemon polls when navigation stops polling" do
    expect(driver).to include("private pollGeneration = 0")
    expect(driver).to match(/private stopPolling\(\)[\s\S]{0,80}this\.pollGeneration \+= 1/)
    expect(driver).to include("generation !== this.pollGeneration")
  end

  it "adopts an existing install by copying the original .env, never moving it" do
    expect(driver).to include("fs.copyFile(")
    expect(driver).not_to include("fs.rename(")
    expect(driver).to include('"showHiddenFiles"')
  end

  it "guides runtime acquisition through OrbStack without Homebrew" do
    expect(driver).to include("https://orbstack.dev/download")
    expect(driver).not_to include("brew ")
  end

  it "uses a fixed-size hiddenInset onboarding window" do
    expect(onboarding_window).to include('titleBarStyle: "hiddenInset"')
    expect(onboarding_window).to include("width: 760")
    expect(onboarding_window).to include("resizable: false")
  end

  it "opens onboarding on startup until a backend mode is configured" do
    expect(main_process).to include('if (getBackendMode() === "") {')
    expect(main_process).to include("await showOnboardingWindow()")
  end

  it "registers the onboarding IPC surface and pushes state changes" do
    %w[
      onboarding:get-state onboarding:choose-mode onboarding:connect-remote
      onboarding:start-install onboarding:cancel-install onboarding:retry
      onboarding:locate-env onboarding:wipe-data onboarding:open-orbstack-download
    ].each do |channel|
      expect(main_process).to include(%("#{channel}"))
    end
    expect(main_process).to include('"onboarding:state-changed"')
    expect(preload).to include("onOnboardingState")
    expect(preload).to include("getOnboardingState")
  end

  it "routes the onboarding view to its own renderer surface" do
    expect(renderer_entry).to include('view === "onboarding"')
    expect(renderer_entry).to include("<OnboardingApp />")
  end

  it "fingerprints a running instance before offering adoption" do
    # A bare 200 from /up isn't Syrus — every Rails 7.1+ app ships /up.
    expect(driver).to match(/adoptRunning[\s\S]{0,600}isSyrusInstance/m) if driver.index("adoptRunning") > driver.index("isSyrusInstance")
    expect(driver).to match(/await isSyrusInstance\(localUrl\)/)
  end

  it "offers the port-conflict picker only for fresh installs" do
    # With an existing .env the port is owned by that file (install.sh
    # ignores --port), and a busy port there is usually our own stack booting.
    expect(driver).to match(/!hasEnv && !\(await syrusHealthy[\s\S]{0,80}portInUse/)
  end

  it "derives the persisted port from the installer's done URL" do
    expect(driver).to include("const port = portFromUrl(url) ?? this.port")
  end

  it "ignores unknown step ids from the installer protocol" do
    expect(driver).to include("(INSTALL_STEP_IDS as readonly string[]).includes(event.id)")
  end

  it "can reset to Welcome so a reopened wizard never shows stale terminal state" do
    reset_fn = driver[/  reset\(\) \{[\s\S]*?\n  \}/]
    expect(reset_fn).to include('this.setState({ phase: "welcome" })')
    expect(reset_fn).to include("this.killInstallChild()")
  end

  it "starts a stopped Colima instead of pushing its user to OrbStack" do
    expect(docker_runtime).to include('"Colima"')
    expect(docker_runtime).to match(/colima.*\["start"\]|\["start"\], \{ env: execEnv\(\)/)
  end

  it "guards against duplicate onboarding windows during renderer load" do
    expect(main_process).to include("onboardingWindowOpening")
    expect(main_process).to match(/if \(onboardingWindowOpening\) \{\s*return onboardingWindowOpening/)
  end

  it "gates the destructive wipe behind a typed confirmation in the renderer" do
    adopt_existing = read("src/onboarding/AdoptExisting.tsx")
    expect(adopt_existing).to include('=== "delete"')
    expect(adopt_existing).to include("disabled={!wipeArmed}")
    expect(driver).to match(/wipeData[\s\S]*?showMessageBox/)
  end
end
