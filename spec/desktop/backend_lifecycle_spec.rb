# frozen_string_literal: true

require "spec_helper"

# The app manages the local Docker stack it installed: ensure-on-launch, a
# transition-only watchdog, and explicit Backend-menu controls. Quitting the
# app must leave the stack running (jobs keep flowing), so the normal lifecycle
# never tears containers down or touches volumes. The ONE exception is
# wipeBackendStack — the explicit, test-channel-guarded "Reset Test Setup" — so
# the "no down" assertion below exempts exactly that helper.
RSpec.describe "desktop backend lifecycle" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  def desktop_i18n
    read("src/i18n.ts")
  end

  let(:lifecycle) { read("electron/installer/backendLifecycle.ts") }
  let(:image_cleanup) { read("electron/installer/imageCleanup.ts") }
  let(:main_process) { read("electron/main.ts") }
  let(:backend_status) { read("src/BackendStatus.tsx") }

  it "runs compose from the state dir with the channel's project name and augmented PATH" do
    # The project name is per-channel (syrus / syrus-test) so a side-by-side
    # test stack drives its own containers and volumes.
    expect(lifecycle).to include('[...prefixArgs, "-p", currentStackIdentity().project, ...args]')
    expect(lifecycle).to include("cwd: stateDir()")
    expect(lifecycle).to include("env: execEnv()")
  end

  it "stops with `compose stop` and never destroys containers or volumes (outside the test-only wipe)" do
    expect(lifecycle).to include('compose(["stop"])')
    # The only `down` in the module is the explicit, test-channel-guarded
    # wipeBackendStack (Reset Test Setup). Exempt exactly that helper, then
    # assert the rest of the lifecycle never tears containers down.
    wipe = lifecycle[/export const wipeBackendStack[\s\S]*?\n\}/]
    expect(wipe).to include('compose(["down", "-v", "--remove-orphans"])')
    expect(lifecycle.sub(wipe, "")).not_to include('"down"')
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
    expect(lifecycle).to match(/volumeExists\(currentStackIdentity\(\)\.dataVolume\)[\s\S]{0,80}"data-gone"/)
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

  it "reports update phases from the installer's own NDJSON, and always clears them" do
    update_fn = lifecycle[/export const updateBackend[\s\S]*?\n\}/]
    # The update path parses the same --json protocol the onboarding driver
    # consumes (step markers + wrapped compose pull progress) instead of
    # blind-piping stdout — every raw line still lands in install.log.
    expect(update_fn).to include("new BackendUpdateProgressTracker()")
    # The whole delivery wire, not just the parse: observing a line must feed
    # report(), and report() must feed deps.onProgress — deleting either link
    # silently kills the sidebar progress.
    expect(update_fn).to match(/readline\.createInterface\(\{ input: child\.stdout \}\)\.on\("line", \(line\) => \{\s*\n\s*log\.write\(`\$\{line\}\\n`\)\s*\n\s*const progress = tracker\.observeLine\(line\)\s*\n\s*if \(progress\) \{\s*\n\s*report\(progress\)/)
    # Progress is cosmetic: a throwing callback must never fail the update...
    expect(update_fn).to match(/const report = [\s\S]{0,200}try \{\s*\n\s*deps\.onProgress\?\.\(progress\)\s*\n\s*\} catch \{/)
    # ...and the notice must disappear on EVERY exit — success, failure, throw.
    expect(update_fn).to match(/\} finally \{[\s\S]{0,120}report\(null\)\s*\n\s*busy = false/)
    # The sidebar covers the whole outage window: "starting" is reported
    # before the daemon wait, not first when the installer prints something.
    expect(update_fn).to match(/report\(tracker\.snapshot\(\)\)\s*\n\s*if \(!\(await ensureDaemon\(\)\)\)/)
  end

  it "bounds the update by wall clock and kills the whole installer tree at the deadline" do
    # install.sh has no overall timeout of its own (its health curl has no
    # --max-time; a wedged pull can sit forever). Without this bound a hung
    # installer leaves `busy` true and the backendUpdate state non-null
    # FOREVER: the watchdog starves on the busy short-circuit, Backend menu
    # actions refuse, and the web app's gated surfaces stay suppressed.
    expect(lifecycle).to include("UPDATE_DEADLINE_MS = 30 * 60_000")
    update_fn = lifecycle[/export const updateBackend[\s\S]*?\n\}/]
    expect(update_fn).to match(/const deadline = setTimeout\(\(\) => \{[\s\S]{0,300}killUpdateChild\(\)\s*\n\s*\}, UPDATE_DEADLINE_MS\)/)
    # Every exit path clears the deadline and the child registration; a spawn
    # error may never be followed by "close".
    expect(update_fn).to match(/const settle = \(ok: boolean\) => \{\s*\n\s*clearTimeout\(deadline\)\s*\n\s*updateChild = null\s*\n\s*resolve\(ok\)/)
    # POSIX spawns detached so the deadline kill reaches docker/compose
    # grandchildren via the process group; Windows uses taskkill /T.
    expect(update_fn).to match(/spawn\(command, args, \{ env, detached: true \}\)/)
    kill_fn = lifecycle[/export const killUpdateChild[\s\S]*?\n\}/]
    expect(kill_fn).to match(/execFile\("taskkill", \["\/pid", String\(child\.pid\), "\/T", "\/F"\]/)
    expect(kill_fn).to match(/process\.kill\(-child\.pid, "SIGTERM"\)/)
  end

  it "never lets a relaunch or quit orphan the in-flight installer" do
    # quitAndInstall while updateBackend runs would orphan the (detached)
    # installer mid-pin-rewrite, and the relaunched app would boot with
    # backendUpdate null while containers are still churning — resurrecting
    # the masked "GitHub not connected" failure.
    expect(lifecycle).to include("export const backendBusy = () => busy")
    guard = main_process[/const deferRelaunchWhileBackendBusy[\s\S]{0,900}/]
    expect(guard).to include("backendLifecycle.backendBusy()")
    expect(guard).to include("Finishing backend update…")
    # Both relaunch entry points run the guard: the sidebar bridge handler
    # and the shared app/tray "Restart to update" menu item.
    relaunch_handler = main_process[/ipcMain\.handle\("shell:relaunch-to-update"[\s\S]{0,900}/]
    expect(relaunch_handler).to include("if (deferRelaunchWhileBackendBusy())")
    menu_item = main_process[/const updateMenuItems[\s\S]{0,900}/]
    expect(menu_item).to include("if (deferRelaunchWhileBackendBusy())")
    # A genuine quit kills the installer tree instead of orphaning it.
    before_quit = main_process[/app\.on\("before-quit", \(\) => \{[\s\S]{0,600}\n\}\)/]
    expect(before_quit).to include("backendLifecycle.killUpdateChild()")
  end

  it "maps installer steps onto the coarse sidebar phases" do
    update_progress = read("electron/installer/updateProgress.ts")
    expect(update_progress).to include('image_pull: "downloading"')
    expect(update_progress).to include('stack_up: "starting"')
    expect(update_progress).to include('health: "migrating"')
    # Step ids come from a parsed external stream — a plain object literal
    # would resolve "constructor"/"toString"/"__proto__" through the
    # prototype chain into functions adopted as the phase.
    expect(update_progress).to match(/STEP_PHASES[\s\S]{0,120}Object\.assign\(Object\.create\(null\)/)
    # The outage flag (what the web app's gating keys off) flips at stack_up —
    # container recreation — never during the pull, and rides every snapshot.
    expect(update_progress).to match(/id === "stack_up" && !this\.outage/)
    expect(update_progress).to include("outage: this.outage")
    # The percent belongs to the pull — a later phase must not show a stale bar.
    expect(update_progress).to match(/if \(phase !== "downloading"\) \{\s*\n\s*this\.percent = null/)
    # Pure module: renderer-side vitest exercises it directly, like pullProgress.
    expect(update_progress).not_to match(/require\("node:|from "node:|from "electron"/)
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
    expect(backend_status).to include('t("backend.reset_hint")')
    expect(desktop_i18n).to include("Run Setup Again")
  end
end
