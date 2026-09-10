import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { DeleteThemeCard, errorSummary, parseDeleteOutcome, renderError } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary("Theme delete", context)
  if (error) return error

  const outcome = parseDeleteOutcome(context)
  if (!outcome) return null

  return `Deleted theme #${outcome.deletedThemeId}`
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError("Theme delete", context)
  if (error) return error

  const outcome = parseDeleteOutcome(context)
  if (!outcome) return null

  return <DeleteThemeCard outcome={outcome} />
}

const deleteUserThemeToolCard: ToolCardRenderer = {
  toolName: "delete_user_theme",
  collapsedSummary,
  renderExpanded
}

export default deleteUserThemeToolCard
