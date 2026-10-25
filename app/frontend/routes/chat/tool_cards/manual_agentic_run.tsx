import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import i18n from "../../../i18n"
import { MarkdownPreview } from "../toolCardMarkdown"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { Badge, CardShell, displayValue, EntityReference, Row, StatePill } from "../toolCardUi"

function inputBoolean(value: unknown) {
  return value === false ? i18n.t("chat:manual_agentic_run.false") : i18n.t("chat:manual_agentic_run.true")
}

function ManualAgenticRunDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const workflowId = displayValue(context.input?.failed_workflow_id)
  const base = displayValue(context.input?.base)
  const instructions = displayValue(context.input?.instructions)
  const reason = displayValue(context.input?.reason)

  return (
    <>
      {jobId ? <Row label={i18n.t("chat:manual_agentic_run.job")} value={<EntityReference id={jobId} kind="job" />} /> : null}
      {base ? <Row label={i18n.t("chat:manual_agentic_run.base")} value={<Badge>{base}</Badge>} /> : null}
      <Row label={i18n.t("chat:manual_agentic_run.push")} value={<Badge>{inputBoolean(context.input?.push)}</Badge>} />
      {workflowId ? (
        <Row label={i18n.t("chat:manual_agentic_run.failed_workflow")} value={<EntityReference id={workflowId} jobId={jobId} kind="workflow" />} />
      ) : null}
      {instructions ? (
        <MarkdownPreview
          maxLines={4}
          modalLabel={i18n.t("chat:manual_agentic_run.full_instructions")}
          text={instructions}
          title={i18n.t("chat:manual_agentic_run.instructions")}
        />
      ) : null}
      {reason ? (
        <MarkdownPreview
          maxLines={4}
          modalLabel={i18n.t("chat:manual_agentic_run.full_reason")}
          text={reason}
          title={i18n.t("chat:manual_agentic_run.reason")}
        />
      ) : null}
      {context.input?.push === false ? <div className="text-xs text-text-secondary">{i18n.t("chat:manual_agentic_run.no_push_hint")}</div> : null}
    </>
  )
}

function structuredError(context: ToolCardContext) {
  if (!context.resultError || !isPlainObject(context.parsedResult)) return null
  const code = displayValue(context.parsedResult.error)
  const message = displayValue(context.parsedResult.message)
  if (!code || !message) return null
  const validBases = Array.isArray(context.parsedResult.valid_bases)
    ? context.parsedResult.valid_bases.map(displayValue).filter((value): value is string => Boolean(value))
    : []
  return { code, message, validBases }
}

function collapsedSummary(context: ToolCardContext) {
  const error = structuredError(context)
  if (error) return i18n.t("chat:manual_agentic_run.failed_summary", { message: error.message })
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const error = structuredError(context)
  if (error)
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="failed" />
          <span className="font-mono font-semibold text-danger-text">{error.code}</span>
        </div>
        <ManualAgenticRunDetails context={context} />
        <MarkdownPreview maxLines={4} modalLabel={i18n.t("chat:manual_agentic_run.error_details")} text={error.message} />
        {error.validBases.length ? (
          <Row
            label={i18n.t("chat:manual_agentic_run.valid_bases")}
            value={
              <span className="flex flex-wrap gap-1">
                {error.validBases.map((base) => (
                  <Badge key={base}>{base}</Badge>
                ))}
              </span>
            }
          />
        ) : null}
      </CardShell>
    )

  const result = parsePendingActionResult(context, true)
  return result ? <PendingActionResultCard details={<ManualAgenticRunDetails context={context} />} omitInstructions omitJob omitReason result={result} /> : null
}

const manualAgenticRunToolCard: ToolCardRenderer = {
  toolName: "manual_agentic_run",
  collapsedSummary,
  renderExpanded
}

export default manualAgenticRunToolCard

const commonInput = {
  job_id: 4222,
  base: "failed_workflow_workspace",
  failed_workflow_id: 61270,
  instructions: "Inspect the failed workflow and repair the implementation.\n\nPreserve the existing public API.",
  reason: "The workflow failed after producing a useful partial implementation.",
  push: false
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:manual_agentic_run.example_pending"),
    input: commonInput,
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: "Start a manual agentic run for repair-ci from failed workflow workspace; push=false?"
    }
  },
  ...[
    ["missing_reason", "reason is required"],
    ["fresh_checkout_push_not_supported", "fresh_checkout cannot push to the existing PR branch; use current_pr_branch or set push=false."],
    ["missing_pr_branch", "push requires an existing PR branch."],
    ["missing_pr", "push requires an existing PR."]
  ].map(([error, message]) => ({
    id: error,
    label: error.replace(/_/g, " "),
    input: { ...commonInput, base: error === "fresh_checkout_push_not_supported" ? "fresh_checkout" : "current_pr_branch", push: true },
    parsedResult: {
      error,
      message,
      ...(error === "fresh_checkout_push_not_supported" ? { valid_bases: ["current_pr_branch", "fresh_checkout", "failed_workflow_workspace"] } : {})
    },
    resultError: true
  }))
]
