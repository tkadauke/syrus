// Helpers for running inside the Syrus desktop app's web container.
//
// The desktop shell intercepts window.open and either loads the URL in the
// main window (same-origin) or hands it to the OS default browser. Both
// paths make window.open return null — the same signal a browser popup
// blocker produces. openInNewTab tells the two apart so callers don't show
// "popup blocked" warnings for links that opened fine in the user's browser.

export function isDesktopShell(): boolean {
  return /\bSyrusDesktop\//.test(navigator.userAgent)
}

// The desktop shell announces its build channel as a UA token
// (SyrusDesktopChannel/test) only for a side-by-side test build; its absence
// means the default (stable) channel. The web UI uses this to show a TEST
// badge next to the brand so a test build is unmistakable in-app.
export function isDesktopTestChannel(): boolean {
  return /\bSyrusDesktopChannel\/test\b/.test(navigator.userAgent)
}

// The desktop app announces its build as a UA token
// (SyrusDesktopBuild/<value>) so the web UI can show which app build is
// hosting it — see BuildBadge. The value is the release version ("0.1.2")
// for release builds and the git short sha for dev builds; the pattern
// deliberately matches both.
export function desktopBuildSha(): string | null {
  const match = navigator.userAgent.match(/\bSyrusDesktopBuild\/([0-9a-zA-Z._-]+)/)
  return match?.[1] ?? null
}

// The desktop app also announces WHEN it was built, as a second UA token
// (SyrusDesktopBuiltAt/<timestamp>) feeding the BuildBadge's hover tooltip.
// Colons are not valid in UA product-version tokens, so the shell emits
// ISO-8601 basic format ("20260707T143200Z" — see webAppWindow.ts) and this
// parser restores the extended form. Returns a full ISO string, or null when
// the token is missing (older shells, plain browsers) or malformed.
export function desktopBuiltAt(): string | null {
  const match = navigator.userAgent.match(/\bSyrusDesktopBuiltAt\/(\d{8})T(\d{6})Z/)
  if (!match) return null

  const [, date, time] = match
  return (
    `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}` +
    `T${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4, 6)}Z`
  )
}

// --- window.syrusShell bridge -------------------------------------------
//
// The desktop app's preload script exposes an imperative bridge on the
// web-app window for shell-level concerns the web UI can't see on its own:
// a downloaded update waiting for a relaunch, and whether Claude Code is
// installed on the host machine (for offering the Syrus skill). Plain
// browsers (and older shells) have no window.syrusShell — always
// feature-detect through syrusShellBridge() and render nothing without it.

// A local backend update in flight, driven by the desktop shell (it runs the
// installer that pulls the new image, recreates the containers, and waits
// through the migrations). `percent` is the overall docker-pull percentage —
// non-null only during "downloading", and only when compose streamed
// parseable progress; without it the sidebar shows an indeterminate bar.
// `outage` is the tri-state gating signal: containers are only recreated
// from the stack_up step on, so during the (long) image pull the OLD backend
// still serves requests. The sidebar notice shows for the WHOLE update, but
// surfaces that read failed connectivity/credential checks gate on `outage`
// only (see useBackendOutage) — never presenting the unconfigured default
// ("GitHub not connected") while the backend is deliberately unreachable.
export type SyrusBackendUpdate = {
  phase: "starting" | "downloading" | "migrating"
  percent: number | null
  outage: boolean
}

export type SyrusShellState = {
  updateReadyVersion: string | null
  claudeDetected: boolean
  skillInstalled: boolean
  skillOfferDismissed: boolean
  // Absent on older shells — always read through `?? null`.
  backendUpdate?: SyrusBackendUpdate | null
}

// Red-pen screen annotation for the walkthrough recorder — a desktop-only
// surface on the shell bridge. In the Electron shell, enable() (called on
// record start) spins up a transparent always-on-top overlay plus a global
// draw-mode toggle (⌘/Ctrl+Shift+A); the recorder's full-screen capture picks
// up the strokes incidentally. disable() (on stop/discard) tears both down.
// `available` is the STATIC desktop-shell presence gate — true only in the
// desktop shell; a plain browser has no `annotation` surface at all, so the
// recorder shows no annotation UI. enable() RESOLVES a runtime boolean — true
// only when the overlay AND the shortcut actually came up — so the recorder
// can withhold the ⌘⇧A hint when the overlay couldn't run. See
// desktop/electron/windows/annotationOverlay.ts.
// What annotation enable() resolves: whether a surface came up, and if so
// whether it's the native HOLD-to-draw hook (Ctrl held → armed) or the TAP
// fallback (⌘⇧A). The recorder shows the matching hint. When hold could NOT
// start, `reason` names the obstacle — most usefully "no-accessibility",
// where the hint can tell the user that granting macOS Accessibility brings
// hold mode back (the tap fallback keeps working meanwhile).
export type AnnotationHoldFailureReason = "no-module" | "no-accessibility" | "start-failed"

export type AnnotationEnableResult = { available: boolean; hold: boolean; reason?: AnnotationHoldFailureReason }

export type SyrusAnnotationBridge = {
  available: boolean
  enable(): Promise<AnnotationEnableResult>
  disable(): Promise<void>
  // Fires on every draw-mode transition (true when the pen is armed). Returns
  // an unsubscribe, mirroring onStateChanged.
  onModeChanged(callback: (drawing: boolean) => void): () => void
}

export type SyrusDictationBridge = {
  prewarmMicrophone(): Promise<{ granted: boolean }>
}

export type SyrusShellBridge = {
  getState(): Promise<SyrusShellState>
  onStateChanged(callback: (state: SyrusShellState) => void): () => void
  relaunchToUpdate(): void
  installSkill(): Promise<{ ok: boolean; message: string }>
  dismissSkillOffer(): void
  dictation?: SyrusDictationBridge
  // Absent on older shells and in plain browsers — always feature-detect via
  // annotationBridge().
  annotation?: SyrusAnnotationBridge
  // Absent on older shells and in plain browsers — always feature-detect via
  // recorderHudBridge().
  recorderHud?: SyrusRecorderHudBridge
}

// The floating recording HUD — a separate always-on-top, DRAGGABLE window
// carrying the recording controls, so they live OUTSIDE the Syrus web-app
// window and stay reachable while the user demonstrates another app. show() at
// record start, update() each tick, hide() on stop/discard; onAction fires when
// the user clicks the HUD's Stop / Discard. `available` is the static
// desktop-shell presence gate — a plain browser has none and keeps the in-page
// HUD. See desktop/electron/windows/recorderHud.ts.
export type SyrusRecorderHudState = {
  clock?: string
  remaining?: string
  remainingWarn?: boolean
  noMic?: string
  hint?: string
  drawing?: boolean
  stopLabel?: string
  penLabel?: string
  discardLabel?: string
}

export type SyrusRecorderHudBridge = {
  available: boolean
  show(state: SyrusRecorderHudState): Promise<void>
  update(state: SyrusRecorderHudState): Promise<void>
  hide(): Promise<void>
  onAction(callback: (kind: "stop" | "discard") => void): () => void
}

declare global {
  interface Window {
    syrusShell?: SyrusShellBridge
  }
}

export function syrusShellBridge(): SyrusShellBridge | null {
  if (typeof window === "undefined") return null
  return window.syrusShell ?? null
}

// The annotation surface, or null when it's unavailable (plain browser, older
// shell, or a shell that reported the overlay can't run — `available: false`).
// Callers gate all annotation UI on a non-null return.
export function annotationBridge(): SyrusAnnotationBridge | null {
  const annotation = syrusShellBridge()?.annotation
  return annotation?.available ? annotation : null
}

// The floating-HUD surface, or null in a plain browser / older shell. Callers
// use the native HUD when present and fall back to the in-page HUD otherwise.
export function recorderHudBridge(): SyrusRecorderHudBridge | null {
  const recorderHud = syrusShellBridge()?.recorderHud
  return recorderHud?.available ? recorderHud : null
}

// Opens a URL in a new tab (or, in the desktop shell, wherever the shell
// routes it). Returns false only when a browser popup blocker genuinely
// swallowed the open. Deliberately not passing the `noopener` feature:
// per spec it forces window.open to return null, which is indistinguishable
// from a blocked popup — the opener is severed manually instead.
export function openInNewTab(url: string): boolean {
  const tab = window.open(url, "_blank")
  if (tab) {
    try {
      tab.opener = null
    } catch {
      // Cross-origin handle that refuses — nothing to do.
    }
    return true
  }

  return isDesktopShell()
}
