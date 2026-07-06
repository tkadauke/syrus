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
    # Missing Go must degrade to a notice, not break packaging.
    expect(stage).to include("skipping CLI bundling")

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
    expect(main[/const bundledCliPath[\s\S]{0,500}/]).to match(/syrus-\$\{process\.platform\}-/)
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
    # Dev builds without staged binaries must skip, not error.
    expect(ensure_current).to match(/if \(bundledHash === null\)/)
  end

  it "offers the Claude Code skill once, only when a coding agent is present" do
    main = read("electron/main.ts")
    # The web app window has no IPC bridge (remote content), so the setup
    # step is the main process watching navigation events. The skill is the
    # ONE offered piece — it writes into another tool's config dir (spec I4).
    expect(main).to include("const offerSkillIfAgentDetected")
    offer = main[/const offerSkillIfAgentDetected[\s\S]{0,4200}/]
    # Never interrupt onboarding/auth — only the settled home surface.
    expect(offer).to match(%r{pathname !== "/" && pathname !== "/dashboard"})
    # Gated on agent presence (~/.claude or ~/.codex), and the once-only
    # flag must NOT burn while no agent is detected — the offer stays live
    # for the launch after Claude Code shows up.
    expect(offer).to match(/if \(!\(await agentToolPresent\(\)\)\)/)
    detection = main[/const agentToolPresent[\s\S]{0,600}/]
    expect(detection).to include('".claude"')
    expect(detection).to include('".codex"')
    # Asked-and-answered: one offer, ever; the legacy CLI-offer flag counts
    # (that dialog included the skill checkbox).
    expect(offer).to include('store.set("skillInstallOffered", true)')
    expect(offer).to include('store.get("cliInstallOffered", false)')
    expect(main).to match(/did-navigate-in-page", attemptSkillOffer/)

    settings = read("electron/settings.ts")
    expect(settings).to include("skillInstallOffered: boolean")
    expect(settings).to include("skillInstallOffered: false")
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
