import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { type BootstrapPayload } from "../api/bootstrap"
import { patchJson } from "../api/client"
import { type ColorTheme } from "../api/themes"
import { updateBootstrapColorTheme, updateBootstrapTheme } from "../routes/appChromeV2/helpers"

export type Theme = "light" | "dark" | "system"
export type ResolvedTheme = "light" | "dark"

type ThemeContextValue = {
  // The persisted preference (what the user picked: light, dark, or system).
  theme: Theme
  // What's actually applied right now — "system" resolved against the OS preference.
  resolvedTheme: ResolvedTheme
  setTheme: (theme: Theme) => void
  // The user's selected color theme (built-in or their own custom theme); null
  // falls back to the unscoped default (Terracotta) CSS values.
  colorTheme: ColorTheme | null
  setColorTheme: (colorTheme: ColorTheme) => void
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

// Built-in themes ship compiled `[data-theme="slug"]` CSS (no flash, no JS
// needed beyond the attribute). Custom themes aren't known at build time, so
// their token values are applied at runtime as inline custom properties on
// the same property names — components consume `--color-*` either way and
// don't need to know which path produced the value. `appliedCustomPropertyKeys`
// tracks what we last set so switching away from a custom theme (to a
// built-in theme, or to none) clears the inline overrides instead of letting
// them keep winning the cascade over the newly-selected built-in CSS block.
function applyColorTheme(colorTheme: ColorTheme | null, resolvedTheme: ResolvedTheme, appliedCustomPropertyKeys: Set<string>) {
  const root = document.documentElement
  const isCustom = colorTheme != null && !colorTheme.built_in
  const nextTokens = isCustom ? (colorTheme.tokens[resolvedTheme] ?? {}) : {}
  const nextKeys = new Set(Object.keys(nextTokens))

  appliedCustomPropertyKeys.forEach((key) => {
    if (!nextKeys.has(key)) root.style.removeProperty(`--color-${key}`)
  })

  Object.entries(nextTokens).forEach(([key, value]) => {
    root.style.setProperty(`--color-${key}`, value)
  })

  appliedCustomPropertyKeys.clear()
  nextKeys.forEach((key) => appliedCustomPropertyKeys.add(key))

  if (colorTheme && colorTheme.built_in) {
    root.setAttribute("data-theme", colorTheme.slug)
  } else {
    root.removeAttribute("data-theme")
  }
}

// Controlled by whichever chrome component knows the signed-in user (AppChromeV2)
// rather than fetching its own bootstrap data — that keeps this a plain
// derived-state provider with no independent network/cache lifecycle to
// coordinate with the page's real bootstrap query.
export function ThemeProvider({ children, theme, colorTheme = null }: { children: ReactNode; theme: Theme; colorTheme?: ColorTheme | null }) {
  const queryClient = useQueryClient()
  const [resolvedTheme, setResolvedTheme] = useState<ResolvedTheme>(() => resolveTheme(theme))
  const appliedCustomPropertyKeys = useRef<Set<string>>(new Set())

  // Keep the applied theme in sync with the persisted preference, and — only
  // while "system" is in effect — with live OS color-scheme changes, so a
  // toggle flipped in the OS settings while the app is open takes effect
  // immediately instead of waiting for the next reload.
  useEffect(() => {
    const next = resolveTheme(theme)
    setResolvedTheme(next)
    applyResolvedTheme(next)
    applyColorTheme(colorTheme, next, appliedCustomPropertyKeys.current)

    if (theme !== "system" || typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia("(prefers-color-scheme: dark)")
    const onChange = () => {
      const nextResolved = resolveTheme(theme)
      setResolvedTheme(nextResolved)
      applyResolvedTheme(nextResolved)
      applyColorTheme(colorTheme, nextResolved, appliedCustomPropertyKeys.current)
    }
    media.addEventListener("change", onChange)
    return () => media.removeEventListener("change", onChange)
  }, [theme, colorTheme])

  async function setTheme(nextTheme: Theme) {
    const previousTheme = theme
    const previousResolved = resolvedTheme
    const optimisticResolved = resolveTheme(nextTheme)

    applyResolvedTheme(optimisticResolved)
    applyColorTheme(colorTheme, optimisticResolved, appliedCustomPropertyKeys.current)
    setResolvedTheme(optimisticResolved)
    queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, nextTheme))

    try {
      const payload = await patchJson<{ theme: Theme }>("/api/v1/app/theme", { theme: nextTheme })
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, payload.theme))
    } catch {
      applyResolvedTheme(previousResolved)
      applyColorTheme(colorTheme, previousResolved, appliedCustomPropertyKeys.current)
      setResolvedTheme(previousResolved)
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, previousTheme))
    }
  }

  async function setColorTheme(nextColorTheme: ColorTheme) {
    const previousColorTheme = colorTheme

    applyColorTheme(nextColorTheme, resolvedTheme, appliedCustomPropertyKeys.current)
    queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapColorTheme(current, nextColorTheme))

    try {
      const payload = await patchJson<{ color_theme: ColorTheme | null }>("/api/v1/app/theme", { color_theme_id: nextColorTheme.id })
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapColorTheme(current, payload.color_theme))
    } catch {
      applyColorTheme(previousColorTheme, resolvedTheme, appliedCustomPropertyKeys.current)
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapColorTheme(current, previousColorTheme))
    }
  }

  return <ThemeContext.Provider value={{ theme, resolvedTheme, setTheme, colorTheme, setColorTheme }}>{children}</ThemeContext.Provider>
}

export function useTheme() {
  const context = useContext(ThemeContext)
  if (!context) throw new Error("useTheme must be used within a ThemeProvider")
  return context
}
