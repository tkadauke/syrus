import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, InternalLink, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"
import i18n from "@app/i18n"

// Core-owned tool card for submit_coding_changes. The result only carries
// the pending-action confirmation shape; branch/title context (there is no
// Job yet at call time -- CodingHandoffCapture creates it once confirmed)
// comes from the tool call's own input arguments.
type SubmitCodingChangesResult = {
  pendingActionId: string
  state: string
  message: string | null
  branch: string | null
  title: string | null
  description: string | null
  repositoryId: string | null
  resourceTitle: string | null
  resourceUrl: string | null
  autoConfirmed: boolean
}

const failureConfig: ToolFailureConfig = {
  title: i18n.t("chat:mutation_submit_coding_changes"),
  attempted: (context) => stringFromInput(context, ["title"]) || i18n.t("chat:mutation_submit_coding_changes"),
  retrySafety: "caution",
  recovery: i18n.t("chat:mutation_submit_coding_recovery")
}

function parseResult(context: ToolCardContext): SubmitCodingChangesResult | null {
  const pending = parsePendingActionResult(context)
  if (!pending || (pending.kind !== "standard" && pending.kind !== "bulk")) return null

  const input = context.input ?? {}
  const live = displayValue(context.livePendingAction?.id) === pending.pendingActionId ? context.livePendingAction : null

  return {
    pendingActionId: pending.pendingActionId,
    state: pending.state,
    message: pending.message,
    branch: displayValue(input.branch),
    title: displayValue(input.title),
    description: displayValue(input.description),
    repositoryId: displayValue(input.repository_id),
    resourceTitle: displayValue(live?.resource_title),
    resourceUrl: displayValue(live?.resource_url),
    autoConfirmed: pending.state === "confirming" || Boolean(pending.message?.toLowerCase().includes("auto-confirmed"))
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null

  return result.message
    ? markdownSummary(result.message)
    : i18n.t(result.branch ? "chat:mutation_submit_coding_summary_branch" : "chat:mutation_submit_coding_summary", {
        branch: result.branch,
        state: result.state
      })
}

function markdownSummary(text: string) {
  return text
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/(^|\s)#{1,6}\s+/gm, "$1")
    .replace(/(^|\n)\s*(?:>|[-+*]|\d+[.)])\s+/g, "$1")
    .replace(/(`{1,3}|\*\*|__|~~|[*_])/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

function WrappingValue({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className={`break-words text-xs text-text-secondary [overflow-wrap:anywhere]${mono ? " font-mono" : ""}`} title={value}>
        {value}
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  const repositoryUrl = result.repositoryId ? `/repositories/${result.repositoryId}` : null
  const resourceIsRepository = result.resourceUrl === repositoryUrl

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {result.autoConfirmed ? <Badge>{i18n.t("chat:mutation_auto_confirmed")}</Badge> : null}
        <Badge>#{result.pendingActionId}</Badge>
      </div>
      <dl className="grid gap-2 sm:grid-cols-2">
        {result.title ? <WrappingValue label={i18n.t("chat:shared.title")} value={result.title} /> : null}
        {result.branch ? <WrappingValue label={i18n.t("chat:shared.branch")} mono value={result.branch} /> : null}
        {result.repositoryId ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:shared.repository")}</SectionLabel>
            <InternalLink href={repositoryUrl!}>
              {resourceIsRepository && result.resourceTitle ? result.resourceTitle : i18n.t("chat:mutation_repository_number", { id: result.repositoryId })}
            </InternalLink>
          </div>
        ) : null}
        {result.resourceUrl && !resourceIsRepository ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:mutation_created_job")}</SectionLabel>
            <InternalLink href={result.resourceUrl}>{result.resourceTitle || i18n.t("chat:mutation_view_job")}</InternalLink>
          </div>
        ) : null}
      </dl>
      {result.description ? <MarkdownPreview maxLines={6} text={result.description} title={i18n.t("chat:shared.description")} /> : null}
      {result.message ? <MarkdownPreview maxLines={4} text={result.message} title={i18n.t("chat:mutation_status_message")} /> : null}
    </CardShell>
  )
}

const submitCodingChangesToolCard: ToolCardRenderer = {
  toolName: "submit_coding_changes",
  collapsedSummary,
  renderExpanded
}

export default submitCodingChangesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_markdown_submission",
    label: i18n.t("chat:mutation_example_pending_submission"),
    input: {
      repository_id: 12,
      branch: "syrus/chat-42-handoff-7",
      title: "Add dark mode",
      description: "Adds **theme controls** and documents the [setting](/settings)."
    },
    parsedResult: { pending_action_id: 88, state: "pending", message: "Pending **operator confirmation**." }
  },
  {
    id: "auto_confirmed_submission",
    label: i18n.t("chat:mutation_example_auto_confirmed_submission"),
    input: { repository_id: 12, branch: "syrus/chat-42-handoff-7", title: "Add dark mode", description: "Adds theme controls." },
    parsedResult: { pending_action_id: 89, state: "confirming", message: "Submit coding changes was auto-confirmed by the active goal policy." }
  },
  {
    id: "submission_error",
    label: i18n.t("chat:mutation_example_submission_error"),
    input: { repository_id: 12, branch: "main", title: "Invalid submission" },
    parsedResult: { error: { message: "Branch must contain committed changes." } },
    resultError: true
  }
]
