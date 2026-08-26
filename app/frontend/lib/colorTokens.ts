import { useEffect, useState } from "react"

// Reads a semantic color design token (declared as a `:root`/`.dark` custom
// property in app/assets/tailwind/application.css) as a resolved color
// string. For the rare spots that can't use a Tailwind class and need a raw
// color value instead — SVG/canvas attributes, or a third-party component's
// inline style/options object (e.g. react-joyride) — this keeps that value
// tied to the token layer instead of a hand-copied hex literal that can
// drift from it.
export function readColorToken(name: string, fallback = ""): string {
  if (typeof document === "undefined") return fallback
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

function resolveAll(names: string[]): string[] {
  return names.map((name) => readColorToken(name))
}

// Re-resolves a set of color tokens whenever the document's theme class
// changes, so callers that need raw color values stay in sync with
// light/dark without depending on ThemeContext directly (some of these
// callers — admin/diagnostic pages, third-party widgets — are tested in
// isolation without a ThemeProvider ancestor).
export function useColorTokens(names: string[]): string[] {
  const key = names.join(",")
  const [values, setValues] = useState(() => resolveAll(names))

  useEffect(() => {
    setValues(resolveAll(key.split(",").filter(Boolean)))

    if (typeof MutationObserver === "undefined") return

    const observer = new MutationObserver(() => setValues(resolveAll(key.split(",").filter(Boolean))))
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
    return () => observer.disconnect()
  }, [key])

  return values
}
