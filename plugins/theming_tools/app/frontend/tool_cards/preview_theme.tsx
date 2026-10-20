import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, inputTokenOverrides, MalformedThemeCard, parseThemeResult, renderError, t, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary(t("action_preview"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return t("summary_previewed", { name: theme.name, id: theme.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError(t("action_preview"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action={t("action_preview")} />

  return <ThemeCard draft outcome={t("state_preview")} overrides={inputTokenOverrides(context.input)} theme={theme} />
}

const previewThemeToolCard: ToolCardRenderer = {
  toolName: "preview_theme",
  collapsedSummary,
  renderExpanded
}

export default previewThemeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "draft_with_warning",
    label: "Draft with contrast warning",
    input: { name: "Draft Mint", light: { brand: "#b6492e" }, shape: { "radius-control": "0.375rem" } },
    parsedResult: {
      theme_id: 8,
      name: "Draft Mint",
      tokens: {
        light: { brand: "#b6492e", surface: "#ffffff", "text-primary": "#111827" },
        dark: { brand: "#f59e0b" },
        shape: { "radius-control": "0.375rem" }
      },
      contrast_warnings: ["light text-primary (#777777) on surface (#ffffff) has contrast 4.1:1, needs at least 4.5:1 for WCAG AA"]
    }
  },
  { id: "pending", label: "Pending / empty result", resultBody: "" },
  {
    id: "contrast_error",
    label: "Contrast validation error",
    resultError: true,
    resultBody:
      "Contrast check failed -- fix these before installing: light text-primary (#fefefe) on surface (#ffffff) has contrast 1.01:1, needs at least 4.5:1 for WCAG AA."
  }
]
