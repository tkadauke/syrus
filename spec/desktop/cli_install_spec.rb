# frozen_string_literal: true

require "json"
require "spec_helper"

# The desktop app is the CLI's distribution channel for users without a
# repo clone (docs/install-experience-spec.md): per-arch pure-Go binaries
# staged into the bundle, installed silently at launch and kept current by
# a per-launch content-hash check (the binary has no version command),
# credentials shared through ~/.syrus/credentials so the CLI is signed in
# on first run, and an optional Claude Code skill — the one piece that IS
# offered rather than imposed — installed through the CLI's own
# `skill install` subcommand.
RSpec.describe "desktop CLI install" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  it "stages darwin AND windows CLI binaries with platform-filtered bundling" do
    stage = read("scripts/stage-cli.mjs")
    expect(stage).to include('CGO_ENABLED: "0"')
    expect(stage).to match(/for \(const arch of \["arm64", "amd64"\]\)/)
    # Naming mirrors Electron's process.platform/process.arch so main.ts can
    # derive the bundled source; windows binaries carry .exe.
    expect(stage).to match(/goos: "darwin", platform: "darwin", suffix: ""/)
    expect(stage).to match(/goos: "windows", platform: "win32", suffix: "\.exe"/)
    # Missing Go must degrade to a notice in DEV builds, not break packaging.
    expect(stage).to include("skipping CLI bundling")
    # ...but RELEASE builds hard-fail: 0.1.1/0.1.2 shipped with an empty
    # Resources/cli because the mac runner had no Go and this script exited 0
    # after wiping the staging dir — every in-app CLI/skill install then died
    # with ENOENT. A release without the bundled CLI is broken, not degraded.
    release_guard = stage[/process\.env\.SYRUS_RELEASE_BUILD === "1"[\s\S]{0,600}/]
    expect(release_guard).to include("process.exit(1)")
    expect(release_guard).to include("console.error")
    # The hard fail must trigger BEFORE the dev-build soft skip is reached.
    expect(release_guard.index("process.exit(1)")).to be < release_guard.index("process.exit(0)")

    config = read("electron-builder.yml")
    # Per-platform filters: mac DMGs must not ship ~40 MB of windows exes and
    # vice versa.
    expect(config).to match(%r{mac:[\s\S]{0,900}- from: resources/cli\s+to: cli\s+filter: \["syrus-darwin-\*"\]})
    expect(config).to match(%r{win:[\s\S]{0,400}- from: resources/cli\s+to: cli\s+filter: \["syrus-win32-x64\*"\]})

    package = JSON.parse(read("package.json"))
    expect(package.dig("scripts", "build")).to include("stage:cli")
  end

  it "installs per-platform with no login step" do
    main = read("electron/main.ts")
    # The probe/install target: ~/.local/bin on macOS; %LocalAppData%\Syrus\bin
    # on Windows — deliberately OUTSIDE the NSIS $INSTDIR, which the updater
    # replaces wholesale on every auto-update.
    probe = main[/const localBinSyrus =[\s\S]{0,400}/]
    expect(probe).to include('path.join(os.homedir(), ".local", "bin", "syrus")')
    expect(probe).to include('"Syrus", "bin", "syrus.exe"')

    install = main[/const performCliInstall[\s\S]{0,3600}/]
    # The bundled-source path derivation lives in bundledCliPath so the
    # launch-time freshness check and the installer share it.
    expect(main[/const bundledCliPath[\s\S]{0,900}/]).to match(/syrus-\$\{process\.platform\}-/)
    expect(install).to include("const source = bundledCliPath()")
    # No credentials writing here: credentialsStore.ts owns
    # ~/.syrus/credentials, and the app already keeps it in the CLI-shared
    # format — the CLI is signed in the moment the binary lands.
    expect(install).not_to include("writeFile")
    expect(install).to include("const signedIn = cachedCredentials !== null")
    # The availability cache must be re-probed after install.
    expect(install).to include("cachedCliAvailable = null")
    # A running syrus.exe can't be overwritten on Windows, but it can be renamed.
    expect(install).to match(/fs\.rename\(target, `\$\{target\}\.old`\)/)
    # The IPC handler delegates so the tray banner, Preferences, and the
    # post-setup dialog share one install path.
    expect(main).to match(/ipcMain\.handle\("install-syrus-cli", async \(_event, options\?: CliInstallOptions\) => performCliInstall\(options\)\)/)
  end

  it "resolves the bundled CLI from desktop/resources in dev builds" do
    main = read("electron/main.ts")
    helper = main[/const bundledCliPath[\s\S]{0,900}/]
    # Packaged apps read <Resources>/cli (electron-builder's `to: cli`).
    expect(helper).to include('path.join(process.resourcesPath, "cli")')
    # Dev builds run the COMPILED main.js from desktop/dist-electron
    # (tsconfig.electron.json outDir), so ONE level up reaches desktop/,
    # where stage-cli.mjs stages resources/cli. Two levels up (the old bug)
    # pointed at <repo>/resources/cli — every dev run then reported the
    # bundled CLI missing and skipped the automatic install.
    expect(helper).to include('path.join(__dirname, "..", "resources", "cli")')
    expect(helper).not_to include('"..", "..", "resources"')
    tsconfig = JSON.parse(read("tsconfig.electron.json"))
    expect(tsconfig.dig("compilerOptions", "outDir")).to eq("dist-electron")
    # ...and the stage script must agree on that staging dir.
    stage = read("scripts/stage-cli.mjs")
    expect(stage).to include('path.join(desktopRoot, "resources", "cli")')
  end

  it "adds the Windows per-user PATH entry safely (registry, not setx)" do
    main = read("electron/main.ts")
    path_helper = main[/const addToWindowsUserPath[\s\S]{0,2200}/]
    # Raw registry read with expansion disabled preserves other entries'
    # %VARS%; setx would truncate at 1024 chars and flatten REG_EXPAND_SZ.
    expect(path_helper).to include("DoNotExpandEnvironmentNames")
    expect(path_helper).to include("SendMessageTimeout")
    expect(main).not_to match(/execFileAsync\("setx"/)
    # A failed PATH write must not fail the install (absolute path still works).
    expect(read("electron/main.ts")).to match(/addToWindowsUserPath\(binDir\)\.catch/)
  end

  it "installs the Claude Code skill through the CLI itself" do
    main = read("electron/main.ts")
    install = main[/const performCliInstall[\s\S]{0,3600}/]
    # CLI-level (`syrus skill install`), not a desktop-side file write — so
    # clone-based users share the exact same skill path (cli/cmd/skill.go).
    expect(install).to match(/execFileAsync\(target, \["skill", "install"\]/)
    # A failed skill write must not report the whole install as broken.
    expect(install).to include("skillError")
  end

  it "installs the CLI silently at launch and refreshes it on every app update" do
    main = read("electron/main.ts")
    # Batteries included (spec I1/I2): no dialog, no opt-out — the launch
    # path compares the bundled binary's content hash against the installed
    # one (the Go binary ships no version command) and reinstalls on drift,
    # which is exactly the post-auto-update state.
    ensure_current = main[/const ensureCliCurrent[\s\S]{0,1400}/]
    expect(ensure_current).to include("fileSha256(bundledCliPath())")
    expect(ensure_current).to include("fileSha256(localBinSyrus())")
    expect(ensure_current).to match(/installedHash === bundledHash/)
    # A previously installed skill rides along so its content tracks the CLI.
    expect(ensure_current).to match(/performCliInstall\(\{ withSkill: skillPresent \}\)/)
    # Wired into app.whenReady, non-blocking, failure self-heals next launch.
    expect(main).to match(/void ensureCliCurrent\(\)\.catch/)
    # Dev builds without staged binaries must skip, not error — and a
    # PACKAGED app in that state (the 0.1.1/0.1.2 missing-Resources/cli
    # builds) must log the skip so it's diagnosable, never crash.
    expect(ensure_current).to match(/if \(bundledHash === null\)/)
    expect(ensure_current).to match(/console\.warn\(`\[cli-install\] bundled CLI missing/)
  end

  it "installs the CLI automatically the moment local onboarding completes" do
    main = read("electron/main.ts")
    # A fresh local install must end with a working `syrus` — no tray click.
    # The hook lives on the onboarding driver's done/local transition (which
    # fires even when the wizard is closed via the traffic light) and reuses
    # the same idempotent content-hash install as launch.
    done_transition = main[/state\.phase === "done" && state\.mode === "local"[\s\S]{0,900}/]
    expect(done_transition).to match(/void ensureCliCurrent\(\)\.catch/)
  end

  it "surfaces a bundle with no CLI as guidance, not a doomed install button" do
    main = read("electron/main.ts")
    # syrus-cli-status reports whether the app package carries a binary to
    # install from; the tray banner and Preferences degrade to manual
    # guidance when it doesn't (ENOENT was the 0.1.1/0.1.2 experience).
    expect(main).to include("const bundledCliAvailable")
    status_handler = main[/ipcMain\.handle\("syrus-cli-status"[\s\S]{0,600}/]
    expect(status_handler).to include("bundledAvailable: await bundledCliAvailable()")

    app = read("src/App.tsx")
    banner = app[/data-testid="cli-missing-banner"[\s\S]{0,1600}/]
    expect(banner).to include("cliBundleMissing")
    expect(banner).to include("missing its bundled Syrus CLI")
    section = app[/export function CliInstallSection[\s\S]{0,4200}/]
    expect(section).to include("carries no bundled CLI")
    expect(section).to match(/disabled=\{installing \|\| bundleMissing\}/)
  end

  it "offers the Claude Code skill as a sidebar notice, never a dialog" do
    main = read("electron/main.ts")
    # The old interruptive "Coding agent detected — teach it Syrus?" dialog
    # is gone; the web app renders the offer inline from the shell-notice
    # bridge state. The skill stays the ONE offered piece — it writes into
    # another tool's config dir (spec I4) — gated on agent presence.
    expect(main).not_to include("offerSkillIfAgentDetected")
    expect(main).not_to include("Coding agent detected")
    expect(main).to include("claudeDetected: await agentToolPresent()")
    detection = main[/const agentToolPresent[\s\S]{0,600}/]
    expect(detection).to include('".claude"')
    expect(detection).to include('".codex"')
    # Asked-and-answered survives the dialog era: both legacy flags count as
    # a dismissal so upgraded installs aren't re-nagged by the notice.
    dismissed = main[/const skillOfferDismissed[\s\S]{0,400}/]
    expect(dismissed).to include('store.get("skillOfferDismissed", false)')
    expect(dismissed).to include('store.get("skillInstallOffered", false)')
    expect(dismissed).to include('store.get("cliInstallOffered", false)')

    settings = read("electron/settings.ts")
    expect(settings).to include("skillInstallOffered: boolean")
    expect(settings).to include("skillInstallOffered: false")
    expect(settings).to include("skillOfferDismissed: boolean")
    expect(settings).to include("skillOfferDismissed: false")
  end

  it "documents the install experience and keeps Preferences as the fallback surface" do
    spec_doc = File.read(File.join(repo_root, "docs/install-experience-spec.md"), encoding: "UTF-8")
    expect(spec_doc).to include("I1. The CLI is always installed.")
    expect(spec_doc).to include("content hash")
    expect(spec_doc).to include("~/.codex")

    app = read("src/App.tsx")
    section = app[/export function CliInstallSection[\s\S]{0,3200}/]
    expect(section).to include("kept current automatically")
    expect(section).to include("Reinstall CLI")
  end

  it "finds and executes the installed CLI even though GUI PATH lacks ~/.local/bin" do
    main = read("electron/main.ts")
    expect(main).to include("const localBinSyrus = ()")
    expect(main).to match(/syrusCliBinary[\s\S]{0,400}localBinSyrus\(\)/)
    # Exec sites must prefer the resolved binary over a bare PATH lookup.
    expect(main).to match(/const cliBinary = \(await syrusCliBinary\(\)\) \?\? "syrus"/)
  end

  it "exposes the install through the bridge with the skill option" do
    expect(read("electron/preload.cts")).to include('ipcRenderer.invoke("install-syrus-cli", options)')
    expect(read("src/vite-env.d.ts")).to include("installSyrusCli: (options?: { withSkill?: boolean }) => Promise<SyrusCliInstallResult>")
  end

  it "gives the tray a real install button when the CLI is missing" do
    app = read("src/App.tsx")
    banner = app[/data-testid="cli-missing-banner"[\s\S]{0,900}/]
    expect(banner).to include("installCliFromBanner")
    # The old escape hatch pointed at public docs that don't exist for
    # desktop users; the banner installs directly now.
    expect(banner).not_to include("openTokenDocs")
  end
end
