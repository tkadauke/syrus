import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, displayValue, EntityReference, Row } from "../toolCardUi"

function optionLabel(value: unknown, defaultValue: boolean, inputAvailable: boolean) {
  if (value === true) return "Enabled"
  if (value === false) return "Disabled"
  if (!inputAvailable) return "Not provided"
  return defaultValue ? "Enabled" : "Disabled"
}

function RequestDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const reason = displayValue(context.input?.reason)
  const instructions = displayValue(context.input?.instructions)
  const provider = displayValue(context.input?.agent_provider)
  const inputAvailable = context.input != null

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Job" value={jobId ? <EntityReference id={jobId} kind="job" /> : "Not provided"} />
        <Row label="Agent provider" value={provider ? <Badge>{provider}</Badge> : "Not provided"} />
        <Row label="Clear handled SHA" value={<Badge>{optionLabel(context.input?.clear_handled_sha, true, inputAvailable)}</Badge>} />
        <Row label="Override repeated SHA" value={<Badge>{optionLabel(context.input?.override_repeated_sha, false, inputAvailable)}</Badge>} />
      </dl>
      {reason ? (
        <MarkdownPreview linkifyUrls maxLines={4} modalLabel="CI repair reason" text={reason} title="Reason" />
      ) : (
        <Row label="Reason" value="Not provided" />
      )}
      {instructions ? (
        <MarkdownPreview linkifyUrls maxLines={4} modalLabel="CI repair instructions" text={instructions} title="Instructions" />
      ) : (
        <Row label="Instructions" value="Not provided" />
      )}
    </div>
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? (
    <PendingActionResultCard
      details={<RequestDetails context={context} />}
      linkifyMessageUrls
      linkifyReasonUrls
      omitInstructions
      omitJob
      omitReason
      result={result}
    />
  ) : null
}

const rerunCiRepairToolCard: ToolCardRenderer = {
  toolName: "rerun_ci_repair",
  collapsedSummary,
  renderExpanded
}

export default rerunCiRepairToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_repair",
    label: "Pending CI repair rerun",
    description: "Shows the linked Job, provider, rerun options, Markdown guidance, and linked failing checks.",
    input: {
      job_id: 4201,
      reason: "Checks still fail after the **first repair**.",
      clear_handled_sha: true,
      instructions: "Focus on the [RSpec failure](https://ci.example.test/builds/4201) before changing implementation code.",
      override_repeated_sha: false,
      agent_provider: "codex"
    },
    parsedResult: {
      pending_action_id: 601,
      state: "pending",
      message: "Rerun CI repair for JOB-4201 at abc1234? Failing checks: RSpec (https://github.com/acme/widgets/actions/runs/123456789)."
    }
  },
  {
    id: "required_only",
    label: "CI repair with default options",
    description: "Shows the effective boolean defaults when the optional rerun arguments are omitted.",
    input: {
      job_id: 4201,
      reason: "Retry the failing checks after **manual review**."
    },
    parsedResult: {
      pending_action_id: 603,
      state: "pending",
      message: "Rerun CI repair for JOB-4201 at abc1234? Failing checks: RSpec."
    }
  },
  {
    id: "validation_error",
    label: "CI repair validation error",
    description: "Keeps every requested repair field visible when validation fails.",
    input: {
      job_id: 4201,
      reason: "Retry requested after **manual review**.",
      clear_handled_sha: false,
      instructions: "Preserve the existing approach.",
      override_repeated_sha: true,
      agent_provider: "claude"
    },
    parsedResult: {
      error: "invalid_request",
      message: "The Job no longer has a failed CI repair. See https://ci.example.test/help/repairs."
    },
    resultError: true
  },
  {
    id: "missing_input",
    label: "Missing CI repair input",
    description: "Exercises explicit unavailable labels for every request field.",
    parsedResult: {
      pending_action_id: 602,
      state: "pending",
      message: "Rerun CI repair?"
    }
  }
]
