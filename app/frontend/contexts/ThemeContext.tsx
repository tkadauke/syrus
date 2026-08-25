import { createContext, useContext, useEffect, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { type BootstrapPayload } from "../api/bootstrap"
import { patchJson } from "../api/client"
import { updateBootstrapTheme } from "../routes/appChromeV2/helpers"

export type Theme = "light" | "dark" | "system"
export type ResolvedTheme = "light" | "dark"

type ThemeContextValue = {
  // The persisted preference (what the user picked: light, dark, or system).
  theme: Theme
  // What's actually applied right now — "system" resolved against the OS preference.
  resolvedTheme: ResolvedTheme
  setTheme: (theme: Theme) => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

function prefersDarkColorScheme() {
  return typeof window !== "undefined" && typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
}

function resolveTheme(theme: Theme): ResolvedTheme {
  return theme === "system" ? (prefersDarkColorScheme() ? "dark" : "light") : theme
}

function applyResolvedTheme(resolvedTheme: ResolvedTheme) {
  document.documentElement.classList.toggle("dark", resolvedTheme === "dark")
}

// Controlled by whichever chrome component knows the signed-in user (AppChromeV2)
// rather than fetching its own bootstrap data — that keeps this a plain
// derived-state provider with no independent network/cache lifecycle to
// coordinate with the page's real bootstrap query.
export function ThemeProvider({ children, theme }: { children: ReactNode; theme: Theme }) {
  const queryClient = useQueryClient()
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(() => resolveTheme(theme))

  // Keep the applied theme in sync with the persisted preference, and — only
  // while "system" is in effect — with live OS color-scheme changes, so a
  // toggle flipped in the OS settings while the app is open takes effect
  // immediately instead of waiting for the next reload.
  useEffect(() => {
    const next = resolveTheme(theme)
    setResolvedTheme(next)
    applyResolvedTheme(next)

    if (theme !== "system" || typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia("(prefers-color-scheme: dark)")
    const onChange = () => {
      const nextResolved = resolveTheme(theme)
      setResolvedTheme(nextResolved)
      applyResolvedTheme(nextResolved)
    }
    media.addEventListener("change", onChange)
    return () => media.removeEventListener("change", onChange)
  }, [theme])

  async function setTheme(nextTheme: Theme) {
    const previousTheme = theme
    const previousResolved = resolvedTheme
    const optimisticResolved = resolveTheme(nextTheme)

    applyResolvedTheme(optimisticResolved)
    setResolvedTheme(optimisticResolved)
    queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, nextTheme))

    try {
      const payload = await patchJson<{ theme: Theme }>("/api/v1/app/theme", { theme: nextTheme })
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, payload.theme))
    } catch {
      applyResolvedTheme(previousResolved)
      setResolvedTheme(previousResolved)
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, previousTheme))
    }
  }

  return <ThemeContext.Provider value={{ theme, resolvedTheme, setTheme }}>{children}</ThemeContext.Provider>
}

export function useTheme() {
  const context = useContext(ThemeContext)
  if (!context) throw new Error("useTheme must be used within a ThemeProvider")
  return context
}
