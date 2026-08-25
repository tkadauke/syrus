import { readFileSync } from "node:fs"
import { afterEach, beforeAll, describe, expect, it } from "vitest"

// app/assets/tailwind/application.css declares the semantic color design
// tokens as plain `:root`/`.dark` custom properties (see the comment block
// above them). jsdom can't run the Tailwind CLI, but it does parse plain CSS
// and resolve custom properties via getComputedStyle — it just silently
// ignores the `@theme inline` at-rule that re-exposes them as Tailwind
// utilities, which is exactly the part this test doesn't need to exercise.
// (Vite's `?raw` loader returns an empty string for `.css` files in this
// setup, so this reads the file directly instead.)
const APPLICATION_CSS_PATH = "app/assets/tailwind/application.css"

const LIGHT_TOKENS: Record<string, string> = {
  "--color-brand": "#b6492e",
  "--color-brand-emphasis": "#973b25",
  "--color-surface": "#ffffff",
  "--color-surface-raised": "#f9fafb",
  "--color-border": "#e5e7eb",
  "--color-text-primary": "#111827",
  "--color-text-secondary": "#6b7280",
  "--color-success": "#047857",
  "--color-warning": "#b45309",
  "--color-danger": "#b91c1c",
  "--color-info": "#1d4ed8",
  "--color-neutral": "#374151"
}

const DARK_TOKENS: Record<string, string> = {
  "--color-brand": "#b6492e",
  "--color-brand-emphasis": "#dba28b",
  "--color-surface": "#111827",
  "--color-surface-raised": "#1f2937",
  "--color-border": "#374151",
  "--color-text-primary": "#f3f4f6",
  "--color-text-secondary": "#9ca3af",
  "--color-success": "#a7f3d0",
  "--color-warning": "#fde68a",
  "--color-danger": "#fecaca",
  "--color-info": "#bfdbfe",
  "--color-neutral": "#e5e7eb"
}

beforeAll(() => {
  const style = document.createElement("style")
  style.textContent = readFileSync(APPLICATION_CSS_PATH, "utf-8")
  document.head.appendChild(style)
})

afterEach(() => {
  document.documentElement.classList.remove("dark")
})

describe("semantic color design tokens", () => {
  it.each(Object.entries(LIGHT_TOKENS))("resolves %s to its light value under :root", (token, expected) => {
    const value = getComputedStyle(document.documentElement).getPropertyValue(token).trim()
    expect(value).toBe(expected)
  })

  it.each(Object.entries(DARK_TOKENS))("resolves %s to its dark value under .dark", (token, expected) => {
    document.documentElement.classList.add("dark")
    const value = getComputedStyle(document.documentElement).getPropertyValue(token).trim()
    expect(value).toBe(expected)
  })

  it("keeps the same token set in both modes", () => {
    expect(Object.keys(DARK_TOKENS).sort()).toEqual(Object.keys(LIGHT_TOKENS).sort())
  })
})
