import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue } from "../toolCardUi"
import { ErrorCard, MalformedCard, successOrError } from "../chatHelperToolCard"
import { parsePinnedContextResult, PendingPinnedContextCard, pinnedContextIdentifiers, PinnedContextCard } from "../pinnedContextToolCard"
import i18n from "@app/i18n"

function parseUpdate(context: ToolCardContext) {
  return successOrError(context, i18n.t("chat:mutation_pinned_update_failed_period"), () => parsePinnedContextResult(context))
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseUpdate(context)
  if (parsed.kind === "error") return i18n.t("chat:mutation_pinned_update_failed")
  if (parsed.kind === "malformed") return context.resultBody === "" ? i18n.t("chat:mutation_pinned_updating") : i18n.t("chat:mutation_pinned_update_unexpected")
  return parsed.data.message || i18n.t("chat:mutation_pinned_updated")
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseUpdate(context)
  if (parsed.kind === "error") return <ErrorCard title={i18n.t("chat:mutation_pinned_context")} message={parsed.message} />
  if (parsed.kind === "malformed") {
    return <MalformedCard title={i18n.t("chat:mutation_pinned_context")} />
  }

  const identifiers =
    typeof context.parsedResult === "object" && context.parsedResult ? pinnedContextIdentifiers(context.parsedResult as Record<string, unknown>) : {}
  return <PinnedContextCard {...identifiers} inputContent={displayValue(context.input?.content)} result={parsed.data} />
}

function renderPending(context: ToolCardContext) {
  return <PendingPinnedContextCard content={displayValue(context.input?.content)} />
}

const updatePinnedContextToolCard: ToolCardRenderer = {
  toolName: "update_pinned_context",
  collapsedSummary,
  renderExpanded,
  renderPending
}

export default updatePinnedContextToolCard

export const examples: ToolCardExample[] = [
  {
    id: "updated_markdown",
    label: i18n.t("chat:mutation_example_updated_markdown"),
    input: { content: "Remember **JOB-42** and https://example.test/runbook" },
    parsedResult: { pinned_context: "Remember **JOB-42** and https://example.test/runbook", message: "Pinned context updated.", chat_id: 7 },
    sourceType: "generic"
  },
  {
    id: "validation_error",
    label: i18n.t("chat:tool_card_example_validation_error"),
    input: { content: " " },
    resultBody: "content is required",
    resultError: true,
    sourceType: "codex"
  }
]
