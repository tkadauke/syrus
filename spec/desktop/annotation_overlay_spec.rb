# frozen_string_literal: true

require "spec_helper"

# The red-pen annotation overlay for the walkthrough recorder: a frameless,
# transparent, always-on-top Electron window spanning EVERY display. The
# recorder's full-screen getDisplayMedia captures it INCIDENTALLY, so marks the
# user draws are burned into the recorded video with no change to the capture
# pipeline.
#
# Interaction model: HOLD-to-draw (native global-key hook via globalKeyHook.ts /
# uiohook-napi) arms draw mode while Ctrl is physically DOWN and releases on
# key-up. When the native hook or macOS Accessibility permission is unavailable,
# enable() FALLS BACK to TAP mode: the global shortcut (CommandOrControl+Shift+A)
# arms and the overlay AUTO-RELEASES on idle (ARM_IDLE_RELEASE_MS) with a hard
# MAX_ARMED_MS cap. enable() reports { available, hold } so the recorder HUD shows
# the matching hint. Esc releases immediately in either mode.
#
# The overriding safety rules are: the overlay must NEVER steal keyboard focus
# when armed, must NEVER stay stuck capturing the screen (idle auto-release +
# hard cap + instant release on disable all guarantee this), and must NEVER
# advertise a shortcut it did not actually register.
#
# The bridges are stringly typed (see ipc_channel_parity_spec.rb) and the
# overlay module talks to Electron APIs that can't run under vitest, so this
# static scan pins the window flags, focus discipline, shortcut lifecycle, IPC
# wiring, teardown-on-crash/reload, and the fade constants the standalone
# overlay HTML mirrors from the tested TS module.
RSpec.describe "desktop annotation overlay" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:overlay) { read("electron/windows/annotationOverlay.ts") }
  let(:main) { read("electron/main.ts") }
  let(:preload) { read("electron/windows/webAppPreload.cts") }
  let(:overlay_html) { read("assets/annotationOverlay.html") }
  let(:fade_module) { read("src/annotationFade.ts") }
  let(:builder_config) { read("electron-builder.yml") }

  describe "the overlay window" do
    it "is a frameless, transparent, always-on-top, click-through-by-default surface" do
      expect(overlay).to include("frame: false")
      expect(overlay).to include("transparent: true")
      expect(overlay).to include("hasShadow: false")
      expect(overlay).to include("skipTaskbar: true")
      expect(overlay).to include("alwaysOnTop: true")
      # Highest practical level so it floats above other apps.
      expect(overlay).to include('setAlwaysOnTop(true, "screen-saver")')
      # Visible over fullscreen spaces on macOS.
      expect(overlay).to include("setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })")
      # Starts click-through: never blocks the app under test until draw mode.
      expect(overlay).to include("setIgnoreMouseEvents(true, { forward: true })")
      # No remote content — a local sandboxed canvas page.
      expect(overlay).to match(/contextIsolation: true[\s\S]{0,120}sandbox: true/)
    end

    it "is created NON-ACTIVATING so arming it never steals the narrator's focus" do
      # Created hidden + non-focusable, then shown WITHOUT activating. enable()
      # must not move focus off the app the narrator is demonstrating.
      expect(overlay).to include("show: false")
      expect(overlay).to include("focusable: false")
      expect(overlay).to include("showInactive()")
      # The old bug created a focusable window on enable(); guard the regression.
      expect(overlay).not_to include("focusable: true")
      # enable() itself must not grab focus (focus is a draw-mode-only action).
      enable = overlay[/const enable[\s\S]{0,6600}/]
      expect(enable).not_to include("overlay.focus()")
    end

    it "spans the union of every display, not just the primary one" do
      # Multi-monitor fix: cover the whole virtual desktop so drawing shows up
      # on whichever monitor is shared. The primary-only MVP is gone.
      expect(overlay).to include("screen.getAllDisplays()")
      expect(overlay).not_to include("getPrimaryDisplay()")
      # Union bounding box drives the window geometry.
      expect(overlay).to include("const virtualDesktopBounds")
      expect(overlay).to match(/Math\.min\([\s\S]{0,120}bounds\.x/)
      expect(overlay).to match(/Math\.max\([\s\S]{0,160}bounds\.x \+ d\.bounds\.width/)
    end

    it "grants focus ONLY in draw mode and drops it the instant draw mode ends" do
      set_armed = overlay[/const setArmed[\s\S]{0,2000}/]
      # Armed → capture (ignore=false) + take focus so the canvas + Esc work.
      expect(set_armed).to include("setIgnoreMouseEvents(!next, { forward: true })")
      expect(set_armed).to match(/setFocusable\(true\)[\s\S]{0,80}focus\(\)/)
      # Released → blur + drop focusability so no keystroke is ever swallowed.
      expect(set_armed).to match(/blur\(\)[\s\S]{0,80}setFocusable\(false\)/)
      # Mirror the transition to the web HUD.
      expect(set_armed).to include("onModeChanged(next)")
    end

    it "leaves draw mode on Escape (which draw-mode focus now makes reachable)" do
      expect(overlay).to include("before-input-event")
      expect(overlay).to match(/input\.key === "Escape"[\s\S]{0,80}setArmed\(false\)/)
    end
  end

  describe "the draw-mode global shortcut" do
    it "is a normal accelerator, registered on enable and unregistered on disable" do
      expect(overlay).to include('export const ANNOTATION_SHORTCUT = "CommandOrControl+Shift+A"')
      # enable() registers the arm/release handler...
      enable = overlay[/const enable[\s\S]{0,6600}/]
      expect(enable).to include("globalShortcut.register(ANNOTATION_SHORTCUT, toggleArm)")
      # ...disable() unregisters it.
      disable = overlay[/const disable[\s\S]{0,2400}/]
      expect(disable).to include("globalShortcut.unregister(ANNOTATION_SHORTCUT)")
    end

    it "taps to arm and taps again to release (press-to-arm, not a sticky toggle)" do
      # The accelerator flips armed state: tap arms, tap again releases. The
      # NEW behavior is that draw mode also auto-releases on idle, so the tap is
      # a shortcut in, not a persistent on/off the user must remember to undo.
      # (Guarded: a fading overlay — disable() ran, destroy scheduled — is not
      # armable; see the dedicated fade-guard example.)
      expect(overlay).to match(/const toggleArm = \(\) => \{[\s\S]{0,300}setArmed\(!armed\)/)
    end

    it "reports unavailable when the tap accelerator is already owned" do
      # register() returns false without throwing when the accelerator is taken.
      # In the TAP fallback a registered-but-false shortcut would advertise a dead
      # shortcut, so enable() tears the overlay down and reports unavailable.
      enable = overlay[/const enable[\s\S]{0,6600}/]
      expect(enable).to match(/if \(!globalShortcut\.register\(ANNOTATION_SHORTCUT, toggleArm\)\) \{[\s\S]{0,140}destroyOverlayNow\(\)[\s\S]{0,80}return \{ available: false, hold: false \}/)
    end

    it "never lets overlay creation crash the recording — enable() try/catch returns unavailable" do
      # enable() has a try that returns an available result and a catch that
      # returns { available: false } (create failure → unavailable, not a crash).
      expect(overlay).to match(/const enable[\s\S]*?try \{[\s\S]*?return \{ available: true[\s\S]*?\} catch \{[\s\S]*?return \{ available: false, hold: false \}/)
      # A failed create/registration tears down the partial window + shortcut
      # through the shared destroy helper.
      expect(overlay).to match(/const destroyOverlayNow[\s\S]{0,260}overlay!\.destroy\(\)/)
    end

    it "reports available only when the overlay exists AND a mode came up" do
      # The tap-mode success path returns available:true,hold:false after
      # showInactive() — carrying WHY hold couldn't start so the HUD can say so;
      # the hold path returns hold:true.
      expect(overlay).to match(/showInactive\(\)[\s\S]{0,80}return \{ available: true, hold: false, reason: holdStart\.reason \}/)
      expect(overlay).to include("return { available: true, hold: true }")
    end
  end

  describe "hold-to-draw (native global-key hook) with a tap fallback" do
    let(:hook) { read("electron/windows/globalKeyHook.ts") }

    it "tries the HOLD hook first and only falls back to the tap shortcut" do
      enable = overlay[/const enable[\s\S]{0,6600}/]
      # Mode is set to hold BEFORE starting the hook so its arm/release don't
      # start the tap auto-release watchers.
      expect(enable).to match(/mode = "hold"\n\s*const holdStart = holdHookFactory\(\{/)
      # A physical Ctrl hold takes ownership from a pen-armed session: the tap
      # watchers stand down so the idle poll / cap can't release mid-hold.
      expect(enable).to match(/onHold: \(\) => \{[\s\S]{0,400}stopArmWatch\(\)[\s\S]{0,80}setArmed\(true\)/)
      expect(enable).to include("onRelease: () => setArmed(false)")
      # A live hook short-circuits before the tap shortcut is registered.
      expect(enable).to match(/if \(holdHook\)[\s\S]{0,160}return \{ available: true, hold: true \}/)
      # Only after the hook reports no hook does it register the tap accelerator.
      expect(enable).to match(/mode = "tap"[\s\S]{0,140}globalShortcut\.register\(ANNOTATION_SHORTCUT/)
    end

    it "re-derives the reported mode from the LIVE hook when the overlay is already up" do
      # A second enable() on a live overlay must not parrot a stale mode flag:
      # hold is reported only when the hook object is actually alive, and a
      # tap-mode (or dead-hook) surface RETRIES the hook — permission or the
      # native module may have arrived since — upgrading in place on success.
      enable = overlay[/const enable[\s\S]{0,6600}/]
      expect(enable).to match(/if \(mode === "hold" && holdHook\) \{[\s\S]{0,60}return \{ available: true, hold: true \}/)
      # The retry disarms any tap-mode arm FIRST (the release path depends on
      # the current mode), then swaps the hook + mode and drops the now-unneeded
      # tap accelerator.
      upgrade = enable[/setArmed\(false\)\n\s*const upgrade = holdHookFactory[\s\S]{0,1600}/]
      expect(upgrade).to include("stopHoldHook()")
      expect(upgrade).to match(/holdHook = upgrade\.hook[\s\S]{0,40}mode = "hold"/)
      expect(upgrade).to include("globalShortcut.unregister(ANNOTATION_SHORTCUT)")
      # A failed retry still reports the live tap surface, with the reason.
      expect(upgrade).to include("return { available: true, hold: false, reason: upgrade.reason }")
    end

    it "arms the auto-release watchers ONLY in tap mode (hold releases on key-up)" do
      # startArmWatch() lives inside the arm branch's tap-only block.
      set_armed = overlay[/const setArmed[\s\S]{0,2400}/]
      expect(set_armed).to match(/if \(mode === "tap"\) \{[\s\S]{0,200}startArmWatch\(\)/)
    end

    it "does NOT take keyboard focus in hold mode, so a physical Ctrl never hijacks the app's shortcuts" do
      # The focus grab lives inside the tap-only branch. In hold mode arming
      # captures pointer (for drawing) but leaves keyboard focus with the app —
      # otherwise every physical Ctrl key-down would steal the keystream and
      # break the user's Ctrl+C / Ctrl+Tab / … for the whole recording.
      set_armed = overlay[/const setArmed[\s\S]{0,2400}/]
      expect(set_armed).to match(/if \(mode === "tap"\) \{[\s\S]{0,140}setFocusable\(true\)[\s\S]{0,60}focus\(\)/)
    end

    it "stops the native hook on every teardown path" do
      expect(overlay).to include("const stopHoldHook")
      expect(overlay[/const destroyOverlayNow[\s\S]{0,480}/]).to include("stopHoldHook()")
      expect(overlay[/const disable[\s\S]{0,2400}/]).to include("stopHoldHook()")
      expect(overlay[/overlay\.on\("closed"[\s\S]{0,200}/]).to include("stopHoldHook()")
    end

    it "the hook soft-loads uiohook, watches Ctrl, and fails to a null hook (never crashes)" do
      # Soft require: a load failure reports a null hook, not a throw.
      expect(hook).to include('require("uiohook-napi")')
      # Watches BOTH Ctrl keys; fires onHold on down, onRelease on up.
      expect(hook).to include("UiohookKey.Ctrl")
      expect(hook).to include("UiohookKey.CtrlRight")
      expect(hook).to include("onHold()")
      expect(hook).to include("onRelease()")
      # macOS Accessibility gate: prompt at most once per gate window, else a
      # null hook → fallback.
      expect(hook).to include("isTrustedAccessibilityClient")
      expect(hook).to match(/\{ hook: null/)
    end

    it "caches the uiohook module ONLY on a successful load, so a transient failure retries" do
      # The old cache stored null forever after one failed require, permanently
      # degrading the whole process to tap mode. Now only success is cached and
      # the failure path returns without poisoning the cache.
      expect(hook).to match(/if \(cachedModule\) return cachedModule/)
      expect(hook).not_to match(/cachedModule = null/)
      load_fn = hook[/const loadUiohook[\s\S]{0,500}/]
      expect(load_fn).to match(/catch \(error\) \{[\s\S]{0,160}return null/)
    end

    it "LOGS every silent-degrade point (console + a hold-to-draw.log under userData)" do
      # "I held Ctrl and nothing happened" was undiagnosable on a packaged DMG:
      # the three failure points (module load, Accessibility, uIOhook.start)
      # degraded with zero logging. Each now logs a reason, and the logger
      # writes both console.warn and an append-only file — and never throws.
      expect(hook).to include("console.warn")
      expect(hook).to include('HOLD_TO_DRAW_LOG_BASENAME = "hold-to-draw.log"')
      expect(hook).to match(/appendFileSync\(path\.join\(app\.getPath\("userData"\), HOLD_TO_DRAW_LOG_BASENAME\)/)
      expect(hook).to include("uiohook-napi failed to load")
      expect(hook).to include("macOS Accessibility permission not granted")
      expect(hook).to include("uIOhook.start() failed")
      # The known uiohook quirk — a failed stop() wedges is_worker_running and a
      # later start() silently no-ops — is the one way hold:true can be
      # advertised while Ctrl does nothing. Both stop() sites log the failure.
      expect(hook.scan("uIOhook.stop() failed").length).to be >= 2
      # The logger itself fails soft: both sinks are wrapped so diagnostics can
      # never take down the feature they diagnose.
      logger = hook[/const logHoldToDrawFailure[\s\S]{0,900}/]
      expect(logger.scan(/\} catch \{/).length).to be >= 2
    end

    it "reports WHY the hook could not start, for the HUD hint" do
      expect(hook).to include('export type HoldHookFailureReason = "no-module" | "no-accessibility" | "start-failed"')
      expect(hook).to include('return { hook: null, reason: "no-accessibility" }')
      expect(hook).to include('return { hook: null, reason: "no-module" }')
      expect(hook).to include('return { hook: null, reason: "start-failed" }')
    end

    it "re-checks (and may re-prompt for) Accessibility once per RECORDING, not once per app run" do
      # disable() re-opens the prompt gate, so a user who grants the permission
      # mid-session gets hold mode on the NEXT recording without relaunching —
      # while a recording still triggers at most one OS prompt.
      expect(hook).to include("export const resetAccessibilityPromptGate")
      expect(hook[/export const resetAccessibilityPromptGate[\s\S]{0,120}/]).to include("promptedAccessibility = false")
      disable = overlay[/const disable[\s\S]{0,2600}/]
      expect(disable).to include("resetAccessibilityPromptGate()")
    end

    it "bundles the native module unpacked from the asar in the packaged app" do
      expect(builder_config).to include("node_modules/uiohook-napi/**")
      expect(File.read(File.join(desktop_root, "package.json"))).to include("uiohook-napi")
    end
  end

  describe "disable(): instant input release, graceful fade, real teardown" do
    it "stops capturing input INSTANTLY so it can never stay stuck over the screen" do
      disable = overlay[/const disable[\s\S]{0,2400}/]
      # Click-through + non-focusable immediately, before any deferred destroy.
      expect(disable).to include("setIgnoreMouseEvents(true, { forward: true })")
      expect(disable).to match(/blur\(\)[\s\S]{0,80}setFocusable\(false\)/)
      # The auto-release watchers (idle poll + hard cap) are killed on disable so
      # neither can fire after teardown.
      expect(disable).to include("stopArmWatch()")
    end

    it "wires the previously-dead clear() so lingering marks fade on stop" do
      disable = overlay[/const disable[\s\S]{0,2400}/]
      # clear() is invoked over the executeJavaScript control surface on stop.
      expect(disable).to include("__syrusAnnotation.clear()")
      # The overlay HTML still defines clear() as that control surface.
      expect(overlay_html).to match(/clear: function \(\)/)
    end

    it "destroys the overlay so it never outlives a recording, and is idempotent" do
      # The shared teardown helper destroys + nulls the window and kills timers...
      destroy = overlay[/const destroyOverlayNow[\s\S]{0,480}/]
      expect(destroy).to include("overlay!.destroy()")
      expect(destroy).to include("overlay = null")
      expect(destroy).to include("stopArmWatch()")
      # ...and disable() schedules it after the fade window (single timer).
      disable = overlay[/const disable[\s\S]{0,2400}/]
      expect(disable).to match(/if \(!teardownTimer\)[\s\S]{0,120}setTimeout\(destroyOverlayNow/)
      # Calling disable() when already down is a safe no-op.
      expect(disable).to include("if (!overlayAlive())")
    end

    it "re-enabling before the fade completes finishes the pending teardown first" do
      enable = overlay[/const enable[\s\S]{0,600}/]
      expect(enable).to match(/if \(teardownTimer\)[\s\S]{0,80}destroyOverlayNow\(\)/)
    end
  end

  describe "press-to-arm / auto-release draw mode" do
    it "mirrors the tested idle/cap timing constants from src/annotationFade.ts" do
      # The tested source of truth (desktop/src/annotationFade.ts).
      expect(fade_module).to include("export const ARM_IDLE_RELEASE_MS = 1200")
      expect(fade_module).to include("export const ARM_POLL_MS = 200")
      expect(fade_module).to include("export const MAX_ARMED_MS = 15_000")
      # The overlay module can't import across the electron/src rootDir split, so
      # it re-declares the same numbers as local literals — pin them together so
      # a drift can't silently change the feel of one and not the other.
      expect(overlay).to include("const ARM_IDLE_RELEASE_MS = 1200")
      expect(overlay).to include("const ARM_POLL_MS = 200")
      expect(overlay).to include("const MAX_ARMED_MS = 15000")
    end

    it "arms/releases through a single setArmed that flips input capture + focus" do
      # setArmed is the one place draw mode transitions: capture toggles with the
      # armed flag, and it is idempotent per state.
      set_armed = overlay[/const setArmed[\s\S]{0,2000}/]
      expect(set_armed).to include("next === armed")
      expect(set_armed).to include("setIgnoreMouseEvents(!next, { forward: true })")
      # Arming starts the auto-release watchers; releasing stops them. The arm
      # branch (startArmWatch) precedes the release branch (stopArmWatch).
      expect(set_armed).to include("startArmWatch()")
      expect(set_armed).to include("stopArmWatch()")
      expect(set_armed.index("startArmWatch()")).to be < set_armed.index("stopArmWatch()")
    end

    it "auto-releases when the pointer pauses (idle poll), never mid-stroke" do
      # A poll samples the renderer's idle snapshot on an interval while armed and
      # releases once the pointer has been quiet for the whole idle window with
      # NO stroke in progress. A mid-stroke pointer (snap.active) is never cut off.
      poll = overlay[/const pollIdle[\s\S]{0,700}/]
      expect(poll).to include("__syrusAnnotation.idleSnapshot()")
      expect(poll).to match(/!snap\.active && \(snap\.idleMs \?\? 0\) >= ARM_IDLE_RELEASE_MS/)
      expect(poll).to include("setArmed(false)")
      # The watcher runs the poll on ARM_POLL_MS.
      expect(overlay).to include("setInterval(pollIdle, ARM_POLL_MS)")
    end

    it "ignores a stale idle snapshot from a previous arm session (generation guard)" do
      # A release→re-arm while a poll's renderer round-trip is in flight must not
      # let the stale reply auto-release the freshly re-armed session. Each poll
      # captures armGeneration and the continuation bails when it no longer matches.
      expect(overlay).to include("armGeneration += 1")
      poll = overlay[/const pollIdle[\s\S]{0,700}/]
      expect(poll).to include("const generation = armGeneration")
      expect(poll).to match(/armGeneration !== generation/)
    end

    it "force-releases at the max-armed cap without cutting an in-flight stroke" do
      # After MAX_ARMED_MS the overlay releases — but a stroke in progress gets
      # grace re-checks until it ends, bounded by the absolute
      # MAX_ARMED_HARD_MS ceiling (a wedged renderer never keeps the screen
      # captured).
      start = overlay[/const startArmWatch[\s\S]{0,1600}/]
      expect(start).to match(/setTimeout\(releaseAtCap, MAX_ARMED_MS\)/)
      expect(start).to include("MAX_ARMED_HARD_MS")
      expect(start).to match(/snap\?\.active[\s\S]{0,120}setTimeout\(releaseAtCap, MAX_ARMED_GRACE_MS\)/)
    end

    it "refuses to arm a fading overlay (disable ran; destroy scheduled)" do
      toggle_arm = overlay[/const toggleArm = \(\) => \{[\s\S]{0,300}?\n  \}/]
      expect(toggle_arm).to include("if (teardownTimer) return")
      toggle_draw = overlay[/const toggleDraw = \(\) => \{[\s\S]{0,500}?\n  \}/]
      expect(toggle_draw).to include("if (teardownTimer) return")
    end

    it "kills both auto-release watchers on every release / teardown path" do
      # stopArmWatch clears the idle poll AND the max-armed cap; it must run on
      # release (setArmed false), disable, destroy, and window close so no stray
      # timer outlives draw mode.
      stop = overlay[/const stopArmWatch[\s\S]{0,320}/]
      expect(stop).to include("clearInterval(idlePollTimer)")
      expect(stop).to include("clearTimeout(maxArmedTimer)")
      # The window's own `closed` handler also drops the watchers.
      closed = overlay[/overlay\.on\("closed"[\s\S]{0,160}/]
      expect(closed).to include("stopArmWatch()")
    end

    it "exposes the renderer idle snapshot the poll reads and resets it on arm" do
      # The overlay HTML tracks the last pointer activity and reports a read-only
      # snapshot { active, idleMs } that the main process polls.
      expect(overlay_html).to include("var lastPointerAt")
      expect(overlay_html).to match(/idleSnapshot: function \(\)/)
      expect(overlay_html).to include("active: active != null, idleMs: performance.now() - lastPointerAt")
      # Arming resets the idle clock (fresh full idle window); releasing ends the
      # in-flight stroke so it fades.
      set_armed = overlay_html[/setArmed: function \(armed\)[\s\S]{0,220}/]
      expect(set_armed).to include("noteActivity()")
      expect(set_armed).to include("endStroke()")
      # Any pointer activity (down/move/up) refreshes the idle clock so an active
      # user isn't dropped to click-through mid-gesture.
      expect(overlay_html).to include("function noteActivity()")
    end
  end

  describe "the main-process wiring" do
    it "lazily builds the controller with the packaged overlay HTML and a HUD bridge" do
      expect(main).to include('import { createAnnotationController, type AnnotationController } from "./windows/annotationOverlay.js"')
      factory = main[/const ensureAnnotationController[\s\S]{0,700}/]
      # HTML ships in assets/ (electron-builder assets/**/* glob) under getAppPath().
      expect(factory).to include('path.join(app.getAppPath(), "assets", "annotationOverlay.html")')
      # Draw-mode transitions reach the web recorder's HUD.
      expect(factory).to include('webAppWindow?.window.webContents.send("annotation:mode-changed", drawing)')
    end

    it "guards annotation:enable / annotation:disable with the same sender validation as shell:*" do
      %w[annotation:enable annotation:disable].each do |channel|
        handler = main[/ipcMain\.handle\("#{Regexp.escape(channel)}", \(event\) => \{[\s\S]{0,300}/]
        expect(handler).to include("if (!shellSenderAllowed(event, \"#{channel}\"))"),
          "#{channel} must validate the sender first"
      end
      # enable spins the controller up; disable tears it down.
      enable = main[/ipcMain\.handle\("annotation:enable"[\s\S]{0,700}/]
      expect(enable).to include("ensureAnnotationController().enable()")
      disable = main[/ipcMain\.handle\("annotation:disable"[\s\S]{0,300}/]
      expect(disable).to include("annotationController?.disable()")
    end

    it "PROPAGATES enable()'s { available, hold } result back through the IPC channel" do
      # The renderer needs the real availability + mode, not a discarded value:
      # return enable()'s result, and reject a disallowed sender as unavailable.
      enable = main[/ipcMain\.handle\("annotation:enable"[\s\S]{0,700}/]
      expect(enable).to include("return ensureAnnotationController().enable()")
      expect(enable).to match(/shellSenderAllowed[\s\S]{0,80}return \{ available: false, hold: false \}/)
    end

    it "tears the overlay down when the app window closes and when the app quits" do
      # Closing the web window mid-recording can't run the renderer's disable.
      on_closed = main[/onClosed: \(\) => \{[\s\S]{0,360}webAppWindow = null[\s\S]{0,450}/]
      expect(on_closed).to include("annotationController?.disable()")
      # And a transparent always-on-top window must never survive quit.
      before_quit = main[/app\.on\("before-quit"[\s\S]{0,500}/]
      expect(before_quit).to include("annotationController?.disable()")
    end

    it "tears the overlay down on a renderer crash or a full main-frame reload/navigation" do
      # A Cmd+R reload or a render-process crash reuses the SAME webContents
      # WITHOUT running the React unmount's annotation:disable — an overlay left
      # in draw mode would keep capturing the whole screen. Disable on both.
      gone = main[/webContents\.on\("render-process-gone"[\s\S]{0,120}/]
      expect(gone).to include("annotationController?.disable()")
      nav = main[/webContents\.on\("did-start-navigation"[\s\S]{0,700}/]
      # Only full (non-same-document) main-frame navigations tear down; in-place
      # SPA route changes are left to the React unmount.
      expect(nav).to include("if (isMainFrame && !isInPlace)")
      expect(nav).to include("annotationController?.disable()")
    end
  end

  describe "the preload bridge" do
    it "exposes window.syrusShell.annotation as the web app's feature gate" do
      annotation = preload[/annotation: \{[\s\S]{0,1400}/]
      # available:true is the desktop-only STATIC signal — a plain browser has none.
      expect(annotation).to include("available: true")
      # enable() resolves { available, hold, reason? } — the recorder gates its
      # HUD hint on available, picks the hold-vs-tap wording from hold, and
      # surfaces the grant-Accessibility nudge from reason.
      expect(annotation).to include('ipcRenderer.invoke("annotation:enable")')
      expect(annotation).to match(/annotation:enable"\) as Promise<\{[\s\S]{0,120}reason\?: "no-module" \| "no-accessibility" \| "start-failed"/)
      expect(annotation).to include('disable: () => ipcRenderer.invoke("annotation:disable")')
      # onModeChanged subscribes + returns an unsubscribe, mirroring onStateChanged.
      expect(annotation).to include('ipcRenderer.on("annotation:mode-changed", listener)')
      expect(annotation).to include('ipcRenderer.removeListener("annotation:mode-changed", listener)')
      # Still exactly one exposeInMainWorld — annotation nests inside syrusShell.
      expect(preload.scan("exposeInMainWorld").length).to eq(1)
    end
  end

  describe "the overlay canvas + shared fade constants" do
    it "renders a self-contained pointer-driven red-pen canvas" do
      expect(overlay_html).to include('<canvas id="pen">')
      expect(overlay_html).to include('addEventListener("pointerdown"')
      expect(overlay_html).to include('addEventListener("pointermove"')
      # Main-process control surface (executeJavaScript target).
      expect(overlay_html).to include("window.__syrusAnnotation")
      # A strict CSP: no remote anything, only the inline canvas script.
      expect(overlay_html).to include("Content-Security-Policy")
    end

    it "mirrors the tested fade constants from src/annotationFade.ts" do
      # The tested source of truth.
      expect(fade_module).to include("export function strokeAlpha(")
      expect(fade_module).to include("export const FADE_DURATION_MS = 2500")
      expect(fade_module).to include("export const STROKE_WIDTH = 6")
      # The standalone HTML re-implements the same numbers (it can't import at
      # runtime) — a drift here means the video looks different from the tests.
      expect(overlay_html).to include("FADE_DURATION_MS = 2500")
      expect(overlay_html).to include("STROKE_WIDTH = 6")
      # The overlay module's graceful-teardown delay uses the same fade window,
      # so the destroy fires only after marks have fully faded.
      expect(overlay).to include("const FADE_DURATION_MS = 2500")
    end
  end

  it "ships the overlay HTML in the packaged app (electron-builder assets glob)" do
    expect(File.exist?(File.join(desktop_root, "assets", "annotationOverlay.html"))).to be(true)
    # The top-level files list bundles assets/**/*, which app.getAppPath()
    # resolves in both dev and the packaged asar.
    expect(builder_config).to match(/files:\s*(?:\n\s*-[^\n]*)*\n\s*-\s*assets\/\*\*\/\*/)
  end
end
