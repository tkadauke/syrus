// Applies the persisted web-app theme preference (User#theme: "light" |
// "dark" | "system") to the desktop tray popover and onboarding windows by
// toggling the `dark` class on <html>, the same mechanism Tailwind v4's
// `@custom-variant dark` in styles.css keys off.
//
// This module intentionally does NOT add any desktop-local picker UI — it
// only mirrors whatever the web app's per-user preference already is. The
// localStorage cache exists purely so a cold launch (before any network
// round-trip resolves) can apply *something* close to correct immediately;
// see the blocking inline script in index.html, which reads the same key
// synchronously before React ever mounts.

export type SyrusTheme = "light" | "dark" | "system"

export const THEME_STORAGE_KEY = "syrus.desktop.theme"

const prefersDarkMediaQuery = () =>
  typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia("(prefers-color-scheme: dark)")
    : null

export const systemPrefersDark = (): boolean => prefersDarkMediaQuery()?.matches ?? false

// Explicit "dark"/"light" always win. "system", missing, or an unrecognized
// value all fall back to the OS-level media query.
export const resolveEffectiveDarkMode = (theme: SyrusTheme | string | undefined | null): boolean => {
  if (theme === "dark") return true
  if (theme === "light") return false
  return systemPrefersDark()
}

export const applyTheme = (theme: SyrusTheme | string | undefined | null): void => {
  if (typeof document === "undefined") {
    return
  }

  document.documentElement.classList.toggle("dark", resolveEffectiveDarkMode(theme))
}

// Best-effort cache of the last-known preference string ("light" | "dark" |
// "system"), read synchronously by index.html's blocking inline script and
// written here once the real bootstrap payload resolves.
export const readCachedTheme = (): SyrusTheme | null => {
  try {
    const cached = localStorage.getItem(THEME_STORAGE_KEY)
    return cached === "light" || cached === "dark" || cached === "system" ? cached : null
  } catch {
    return null
  }
}

export const writeCachedTheme = (theme: SyrusTheme | string | undefined | null): void => {
  try {
    if (theme === "light" || theme === "dark" || theme === "system") {
      localStorage.setItem(THEME_STORAGE_KEY, theme)
    }
  } catch {
    // Ignore unavailable storage, private mode, or quota errors — the
    // in-memory applyTheme() call this pairs with still takes effect for
    // the current session.
  }
}
