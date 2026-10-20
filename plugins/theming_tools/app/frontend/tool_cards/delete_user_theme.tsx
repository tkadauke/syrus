import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "@app/routes/chat/toolFailureSummaryCard"
import { DeleteThemeCard, MalformedThemeCard, parseDeleteOutcome, t } from "../themeToolCard"

const failureConfig: ToolFailureConfig = {
  title: t("action_delete"),
  attempted: (context) => {
    const id = context.input?.theme_id
    return id == null ? t("delete_theme") : t("delete_theme_ref", { id: String(id) })
  },
  retrySafety: "caution",
  recovery: t("delete_recovery")
}

function collapsedSummary(context: ToolCardContext) {
  const error = toolFailureCollapsedSummary(context, failureConfig)
  if (error) return error

  const outcome = parseDeleteOutcome(context)
  if (!outcome) return null

  return t("summary_deleted", { id: outcome.deletedThemeId })
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const outcome = parseDeleteOutcome(context)
  if (!outcome) return <MalformedThemeCard action={t("action_delete")} />

  return <DeleteThemeCard outcome={outcome} />
}

const deleteUserThemeToolCard: ToolCardRenderer = {
  toolName: "delete_user_theme",
  collapsedSummary,
  renderExpanded
}

export default deleteUserThemeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "deleted_with_fallback",
    label: "Deleted active theme with fallback",
    input: { theme_id: 12 },
    parsedResult: { deleted_theme_id: 12, deleted_theme_name: "Sunset Console", fallback_theme_id: 1, fallback_theme_name: "Terracotta" }
  },
  {
    id: "deleted_without_fallback",
    label: "Deleted inactive theme",
    input: { theme_id: 12 },
    parsedResult: { deleted_theme_id: 12, deleted_theme_name: "Sunset Console", fallback_theme_id: null, fallback_theme_name: null }
  },
  { id: "built_in_error", label: "Built-in theme error", input: { theme_id: 1 }, resultError: true, resultBody: "Built-in themes can't be deleted." },
  {
    id: "ownership_error",
    label: "Theme ownership error",
    input: { theme_id: 24 },
    resultError: true,
    parsedResult: { error: { message: "You can only delete your own themes.", retryable: false } }
  },
  { id: "pending", label: "Pending / empty result", input: { theme_id: 12 }, resultBody: "" }
]
