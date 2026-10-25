import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { ErrorCard, MalformedCard, successOrError } from "../chatHelperToolCard"
import { parsePinnedContextResult, pinnedContextIdentifiers, PinnedContextCard } from "../pinnedContextToolCard"
import { CardShell, StatePill } from "../toolCardUi"
import i18n from "@app/i18n"

function parseRemoval(context: ToolCardContext) {
  return successOrError(context, i18n.t("chat:mutation_pinned_removal_failed_period"), () => parsePinnedContextResult(context))
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseRemoval(context)
  if (parsed.kind === "error") return i18n.t("chat:mutation_pinned_removal_failed")
  if (parsed.kind === "malformed")
    return context.resultBody === "" ? i18n.t("chat:mutation_pinned_removing") : i18n.t("chat:mutation_pinned_removal_unexpected")
  return parsed.data.message || i18n.t("chat:mutation_pinned_removed")
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseRemoval(context)
  if (parsed.kind === "error") return <ErrorCard title={i18n.t("chat:mutation_pinned_context")} message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title={i18n.t("chat:mutation_pinned_context")} />

  const identifiers =
    typeof context.parsedResult === "object" && context.parsedResult ? pinnedContextIdentifiers(context.parsedResult as Record<string, unknown>) : {}
  return <PinnedContextCard {...identifiers} result={parsed.data} />
}

function renderPending() {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="pending" tone="info" />
        <span className="font-semibold text-text-primary">{i18n.t("chat:mutation_pinned_removing")}</span>
      </div>
    </CardShell>
  )
}

const removePinnedContextToolCard: ToolCardRenderer = {
  toolName: "remove_pinned_context",
  collapsedSummary,
  renderExpanded,
  renderPending
}

export default removePinnedContextToolCard

export const examples: ToolCardExample[] = [
  {
    id: "removed_markdown",
    get label() {
      return i18n.t("chat:mutation_example_removed_markdown")
    },
    parsedResult: {
      chat_id: 7,
      pinned_context: null,
      removed_pinned_context: "Remember **JOB-42** and https://example.test/runbook",
      message: "Pinned context removed."
    },
    sourceType: "generic"
  },
  {
    id: "nothing_pinned",
    get label() {
      return i18n.t("chat:mutation_example_nothing_pinned")
    },
    resultBody: "No pinned context exists for this chat.",
    resultError: true,
    sourceType: "codex"
  }
]
