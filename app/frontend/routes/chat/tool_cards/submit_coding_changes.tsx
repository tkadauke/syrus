import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for submit_coding_changes. The result only carries
// the pending-action confirmation shape; handoff context (there is no Job
// yet at call time -- CodingHandoffCapture creates it once confirmed) comes
// from the tool call's own input arguments.
type SubmitCodingChangesResult = {
  pendingActionId: string
  state: string
  message: string | null
  repositoryId: string | null
  branch: string | null
  title: string | null
  description: string | null
  autoConfirmed: boolean
  resourceTitle: string | null
  resourceUrl: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "Submit coding changes",
  attempted: (context) => displayValue(context.input?.title) || "Create a coding handoff Job",
  retrySafety: "caution",
  recovery: "Correct the handoff details or repository access, then submit again."
}

function parseResult(context: ToolCardContext): SubmitCodingChangesResult | null {
  const pending = parsePendingActionResult(context)
  if (!pending || pending.kind === "dry_run_evidence") return null

  const input = context.input ?? {}
  const live = context.livePendingAction
  const liveMatch = live && displayValue(live.id) === pending.pendingActionId ? live : null

  return {
    pendingActionId: pending.pendingActionId,
    state: pending.state,
    message: pending.message,
    repositoryId: displayValue(input.repository_id),
    branch: displayValue(input.branch),
    title: displayValue(input.title),
    description: displayValue(input.description),
    autoConfirmed: /auto-confirmed/i.test(pending.message || ""),
    resourceTitle: displayValue(liveMatch?.resource_title),
    resourceUrl: displayValue(liveMatch?.resource_url)
  }
}

function WrappingDetail({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className={`${mono ? "font-mono" : ""} break-words text-xs text-text-secondary [overflow-wrap:anywhere]`}>{value}</div>
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null

  return result.message || `Submit coding changes${result.branch ? ` for ${result.branch}` : ""} (${result.state})`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {result.autoConfirmed ? <Badge>Auto-confirmed</Badge> : null}
        <Badge>#{result.pendingActionId}</Badge>
      </div>
      <dl className="grid gap-2 sm:grid-cols-2">
        {result.repositoryId ? (
          <div className="min-w-0">
            <SectionLabel>Repository</SectionLabel>
            <EntityReference kind="repository" repositoryId={result.repositoryId} label={`Repository #${result.repositoryId}`} wrap="break" />
          </div>
        ) : null}
        {result.title ? <WrappingDetail label="Title" value={result.title} /> : null}
        {result.branch ? <WrappingDetail label="Branch" mono value={result.branch} /> : null}
        {result.resourceUrl ? (
          <div className="min-w-0">
            <SectionLabel>Job</SectionLabel>
            <EntityReference href={result.resourceUrl} kind="job" label={result.resourceTitle || "View Job"} wrap="break" />
          </div>
        ) : null}
      </dl>
      {result.description ? <MarkdownPreview modalLabel="Full description" text={result.description} title="Description" /> : null}
      {result.message ? <MarkdownPreview modalLabel="Full status message" text={result.message} title="Status" /> : null}
    </CardShell>
  )
}

const submitCodingChangesToolCard: ToolCardRenderer = {
  toolName: "submit_coding_changes",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending confirmation",
    input: {
      repository_id: 7,
      branch: "feature/wrapping-mobile-branch",
      title: "Improve coding handoff card",
      description: "Show the **implementation summary** as Markdown."
    },
    parsedResult: { pending_action_id: 88, state: "pending", message: "Submit coding changes is pending operator confirmation." }
  },
  {
    id: "auto_confirmed",
    label: "Auto-confirmed by goal policy",
    input: {
      repository_id: 7,
      branch: "feature/automatic-handoff",
      title: "Automatically hand off changes",
      description: "Dispatch the handoff under the active goal policy."
    },
    parsedResult: { pending_action_id: 89, state: "confirming", message: "Submit coding changes was auto-confirmed by the active goal policy." }
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { repository_id: 7, branch: "feature/missing-title", title: "" },
    resultBody: "Error: title is required",
    resultError: true
  }
]

export default submitCodingChangesToolCard
