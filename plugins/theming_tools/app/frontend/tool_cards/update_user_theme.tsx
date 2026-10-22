import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, parseThemeResult, renderError, t, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary(t("action_update"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return t("summary_updated", { name: theme.name, id: theme.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError(t("action_update"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action={t("action_update")} />

  return <ThemeCard outcome={t("state_updated")} theme={theme} />
}

const updateUserThemeToolCard: ToolCardRenderer = {
  toolName: "update_user_theme",
  collapsedSummary,
  renderExpanded
}

export default updateUserThemeToolCard
