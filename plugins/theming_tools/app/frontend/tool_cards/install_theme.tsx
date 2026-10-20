import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, parseThemeResult, renderError, t, ThemeCard } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary(t("action_install"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return t("summary_installed", { name: theme.name, id: theme.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError(t("action_install"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action={t("action_install")} />

  return <ThemeCard outcome={t("state_installed")} theme={theme} />
}

const installThemeToolCard: ToolCardRenderer = {
  toolName: "install_theme",
  collapsedSummary,
  renderExpanded
}

export default installThemeToolCard
