import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, parseThemeResult, renderError, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary("Theme update", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return `Updated ${theme.name} (#${theme.id})`
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError("Theme update", context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action="Theme update" />

  return <ThemeCard outcome="updated" theme={theme} />
}

const updateUserThemeToolCard: ToolCardRenderer = {
  toolName: "update_user_theme",
  collapsedSummary,
  renderExpanded
}

export default updateUserThemeToolCard
