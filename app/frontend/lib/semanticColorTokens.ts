import type { ThemeTokens } from "../api/themes"

export const DERIVED_COLOR_TOKENS: Record<string, string> = {
  page: "var(--color-surface-raised)",
  "surface-subtle": "var(--color-surface-raised)",
  "surface-inset": "color-mix(in srgb, var(--color-surface) 70%, var(--color-border))",
  "border-strong": "color-mix(in srgb, var(--color-border) 70%, var(--color-text-primary))",
  text: "var(--color-text-primary)",
  "text-muted": "var(--color-text-secondary)",
  "text-subtle": "color-mix(in srgb, var(--color-text-secondary) 70%, var(--color-surface))",
  link: "var(--color-brand-emphasis)",
  "success-surface": "color-mix(in srgb, var(--color-surface) 94%, var(--color-success))",
  "success-border": "color-mix(in srgb, var(--color-surface) 70%, var(--color-success))",
  "success-text": "var(--color-success)",
  "warning-surface": "color-mix(in srgb, var(--color-surface) 94%, var(--color-warning))",
  "warning-border": "color-mix(in srgb, var(--color-surface) 70%, var(--color-warning))",
  "warning-text": "var(--color-warning)",
  "danger-surface": "color-mix(in srgb, var(--color-surface) 94%, var(--color-danger))",
  "danger-border": "color-mix(in srgb, var(--color-surface) 70%, var(--color-danger))",
  "danger-text": "var(--color-danger)",
  "info-surface": "color-mix(in srgb, var(--color-surface) 94%, var(--color-info))",
  "info-border": "color-mix(in srgb, var(--color-surface) 70%, var(--color-info))",
  "info-text": "var(--color-info)",
  "neutral-surface": "color-mix(in srgb, var(--color-surface) 94%, var(--color-neutral))",
  "neutral-border": "color-mix(in srgb, var(--color-surface) 70%, var(--color-neutral))",
  "neutral-text": "var(--color-neutral)"
}

export function semanticColorProperties(tokens: ThemeTokens): ThemeTokens {
  return { ...tokens, ...DERIVED_COLOR_TOKENS }
}
