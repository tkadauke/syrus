import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, parseThemeResult, renderError, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary("Theme preview", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return `Previewed ${theme.name} (#${theme.id})`
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError("Theme preview", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action="Theme preview" />

  return <ThemeCard outcome="preview" theme={theme} />
}

const previewThemeToolCard: ToolCardRenderer = {
  toolName: "preview_theme",
  collapsedSummary,
  renderExpanded
}

export default previewThemeToolCard
