import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, parseThemeResult, renderError, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary("Theme install", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return `Installed ${theme.name} (#${theme.id})`
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError("Theme install", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action="Theme install" />

  return <ThemeCard outcome="installed" theme={theme} />
}

const installThemeToolCard: ToolCardRenderer = {
  toolName: "install_theme",
  collapsedSummary,
  renderExpanded
}

export default installThemeToolCard
