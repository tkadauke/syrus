# frozen_string_literal: true

require "spec_helper"

# The app manages the local Docker stack it installed: ensure-on-launch, a
# transition-only watchdog, and explicit Backend-menu controls. Quitting the
# app must leave the stack running (jobs keep flowing), so nothing here may
# tear containers down or touch volumes.
RSpec.describe "desktop backend lifecycle" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:lifecycle) { read("electron/installer/backendLifecycle.ts") }
  let(:image_cleanup) { read("electron/installer/imageCleanup.ts") }
  let(:main_process) { read("electron/main.ts") }
  let(:backend_status) { read("src/BackendStatus.tsx") }

  it "runs compose from the state dir with the pinned project name and augmented PATH" do
    expect(lifecycle).to include('[...prefixArgs, "-p", "syrus", ...args]')
    expect(lifecycle).to include("cwd: stateDir()")
    expect(lifecycle).to include("env: execEnv()")
  end

  it "stops with `compose stop` and never destroys containers or volumes" do
    expect(lifecycle).to include('compose(["stop"])')
    expect(lifecycle).not_to include('"down"')
  end

  it "never pulls images — updates happen only through the installer" do
    expect(lifecycle).not_to match(/compose\(\[[^\]]*"pull"/)
  end

  it "gates every action on local mode so remote instances are untouched" do
    expect(lifecycle.scan(/getBackendMode\(\) !== "local"/).length).to be >= 3
  end

  it "supervises on launch: ensure running plus a transition-only watchdog" do
    expect(main_process).to include("startLocalBackendSupervision()")
    expect(lifecycle).to include("export const ensureRunning")
    expect(lifecycle).to include("WATCHDOG_INTERVAL_MS = 30_000")
    expect(lifecycle).to include("if (healthy === lastHealthy)")
  end

  it "diagnoses daemon-down vs data-gone vs containers-down without auto-restarting" do
    expect(lifecycle).to include('"daemon-down"')
    expect(lifecycle).to include('"containers-down"')
    expect(lifecycle).to match(/volumeExists\(DATA_VOLUME_NAME\)[\s\S]{0,80}"data-gone"/)
    expect(lifecycle).not_to match(/onHealthyChanged[\s\S]*startBackend\(\)/)
  end

  it "offers a setup escape hatch that never touches data or credentials" do
    expect(main_process).to include('"Run Setup Again…"')
    setup_again = main_process[/const runSetupAgain = async[\s\S]*?\n\}/]
    expect(setup_again).to include("clearBackendConfig()")
    # Without a driver reset the reopened wizard shows the previous run's
    # terminal phase (done/failed) instead of Welcome.
    expect(setup_again).to include("onboardingDriver?.reset()")
    expect(setup_again).to include("await showOnboardingWindow()")
    expect(setup_again).not_to include("deleteCredentials")
    expect(setup_again).not_to include("down")
  end

  it "prompts once for a fresh setup when the data volume is gone" do
    expect(main_process).to match(/diagnosis === "data-gone"[\s\S]{0,80}offerSetupAfterDataLoss/)
    expect(main_process).to include("dataLossPromptShown")
  end

  it "adds the Backend menu only for local installs, with a confirmed stop" do
    expect(main_process).to include('if (getBackendMode() === "local") {')
    expect(main_process).to include('label: "Backend"')
    expect(main_process).to include("confirmStopBackend")
    expect(main_process).to match(/confirmStopBackend[\s\S]*?showMessageBox/)
    expect(main_process).to include('"Open Install Log"')
  end

  it "suppresses the watchdog after a deliberate stop" do
    # Backend -> Stop Syrus shows the "stopped" page; the next watchdog tick
    # must not overwrite it with a "containers-down" failure.
    stop_fn = lifecycle[/export const stopBackend[\s\S]*?\n\}/]
    expect(stop_fn).to include("lastHealthy = false")
  end

  it "makes restart honest and surfaces refused menu actions" do
    restart_fn = lifecycle[/export const restartBackend[\s\S]*?\n\}/]
    expect(restart_fn).to include("if (!stopped)")
    expect(main_process).to include("runBackendAction")
    expect(main_process).to include("reportBackendActionFailure")
  end

  it "retires superseded syrus images only after a healthy update, never on first install" do
    # Every backend update pulls a fresh multi-GB image; without cleanup the
    # Docker VM disk fills with dead syrus-backend images after a few updates.
    update_fn = lifecycle[/export const updateBackend[\s\S]*?\n\}/]
    expect(update_fn).to match(/ok && \(await backendHealthy\(\)\)[\s\S]{0,600}removeSupersededSyrusImages/)
    # The pin just applied is the one image that must survive.
    expect(update_fn).to include("pinnedRef: image")
    # Cleanup lives on the update path only — first installs go through the
    # onboarding driver and never call updateBackend.
    expect(lifecycle.scan(/removeSupersededSyrusImages\(/).length).to eq(1)
  end

  it "scopes image cleanup to same-repository siblings of the pin and stays polite" do
    expect(image_cleanup).to include('SYRUS_IMAGE_BASENAMES = ["syrus-backend", "syrus-local"]')
    # "Superseded" means the ref's full repository (registry + namespace +
    # name — the ref minus the tag) EQUALS the pinned ref's repository, under
    # a different tag. A basename-wide rule deleted a developer's freshly
    # built `syrus-backend:dev-abc` on a routine desktop update.
    expect(image_cleanup).to include("const pinnedRepository = splitRef(pinnedRef).repository")
    expect(image_cleanup).to include("splitRef(ref).repository === pinnedRepository")
    # Plain per-ref removal: an in-use image refuses politely and stays.
    expect(image_cleanup).to include('["image", "rm", ref]')
    expect(image_cleanup).not_to include("--force")
    # Never a blanket prune — that would nuke the user's unrelated images.
    expect(image_cleanup).not_to include('"prune"')
    # No pin (first install / pre-pin float) means nothing is removable.
    expect(image_cleanup).to match(/if \(!pinnedRef\) \{\s*return/)
  end

  it "never lets the pull progress bar freeze at a guessed 100%" do
    pull_progress = read("electron/installer/pullProgress.ts")
    # Layer-count fallback (no byte totals yet) is a guess: early cached
    # "Already exists" rows would compute ~100% before the real multi-GB
    # download even starts. The fallback caps below 100 until the
    # image-level terminal event, and the monotonic clamp resets on the
    # fallback→bytes mode switch so real byte data can correct downward.
    expect(pull_progress).to include("FALLBACK_MAX_PERCENT = 99")
    expect(pull_progress).to match(/if \(!this\.imagesAllDone\(\)\) \{\s*rawPercent = Math\.min\(rawPercent, FALLBACK_MAX_PERCENT\)/)
    expect(pull_progress).to match(/event\.text === "Pulled" \|\| event\.status === "Done"/)
    expect(pull_progress).to match(/mode === "bytes" && this\.mode === "fallback"[\s\S]{0,40}this\.maxPercent = null/)
  end

  it "bounds the daemon wait by wall clock with short probes" do
    # Iteration-counted polls with 10s docker-info timeouts stretched the
    # nominal 3-minute wait to ~18 minutes against a wedged daemon.
    expect(lifecycle).to include("DAEMON_WAIT_DEADLINE_MS")
    expect(lifecycle).to include("await daemonUp(2_000)")
    expect(lifecycle).not_to include("DAEMON_WAIT_POLLS")
  end

  it "starts supervision when a local install completes, not only on Open Syrus" do
    on_state = main_process[/onState: \(state\) => \{[\s\S]*?\n    \}/]
    expect(on_state).to include('state.phase === "done" && state.mode === "local"')
    expect(on_state).to include("startLocalBackendSupervision()")
  end

  it "rebuilds the menu and starts supervision when onboarding finishes" do
    finish = main_process[/const finishOnboarding = async \(\) => \{[\s\S]*?\n\}/]
    expect(finish).to include("createMenu()")
    expect(finish).to include("startLocalBackendSupervision()")
  end

  it "explains each unavailable state on the status page, with the setup escape hatch" do
    %w[daemon-down containers-down stopped remote data-gone].each do |detail|
      expect(backend_status).to include(%("#{detail}")).or include("#{detail}:")
    end
    expect(backend_status).to include("Run Setup Again")
  end
end
