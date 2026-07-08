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

export type SyrusShellState = {
  updateReadyVersion: string | null
  claudeDetected: boolean
  skillInstalled: boolean
  skillOfferDismissed: boolean
}

export type SyrusShellBridge = {
  getState(): Promise<SyrusShellState>
  onStateChanged(callback: (state: SyrusShellState) => void): () => void
  relaunchToUpdate(): void
  installSkill(): Promise<{ ok: boolean; message: string }>
  dismissSkillOffer(): void
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
