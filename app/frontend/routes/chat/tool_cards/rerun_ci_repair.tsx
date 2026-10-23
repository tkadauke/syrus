import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"

const inputFields: PendingActionInputField[] = [
  { key: "job_id", label: "Job", format: "entity", entityKind: "job", emptyLabel: "Not provided" },
  { key: "agent_provider", label: "Agent provider", format: "badge", emptyLabel: "Not provided" },
  { key: "clear_handled_sha", label: "Clear handled SHA", format: "badge", emptyLabel: "Not provided" },
  { key: "override_repeated_sha", label: "Override repeated SHA", format: "badge", emptyLabel: "Not provided" },
  { key: "reason", label: "Reason", format: "markdown", emptyLabel: "Not provided" },
  { key: "instructions", label: "Instructions", format: "markdown", emptyLabel: "Not provided" }
]

function effectiveInput(input?: Record<string, unknown>) {
  if (!input || Object.keys(input).length === 0) return input
  return {
    ...input,
    clear_handled_sha: input.clear_handled_sha === false ? "Disabled" : "Enabled",
    override_repeated_sha: input.override_repeated_sha === true ? "Enabled" : "Disabled"
  }
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
  const input = effectiveInput(context.input)
  return result ? <PendingActionResultCard input={input} inputFields={inputFields} omitInstructions omitJob omitReason result={result} /> : null
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
      instructions: `${"Inspect the failing check carefully. ".repeat(30)}See https://ci.example.test/builds/4201.`,
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
    input: { job_id: 4201, reason: "Retry the failing checks after **manual review**." },
    parsedResult: { pending_action_id: 603, state: "pending", message: "Rerun CI repair for JOB-4201 at abc1234? Failing checks: RSpec." }
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
    parsedResult: { error: "invalid_request", message: "The Job no longer has a failed CI repair. See https://ci.example.test/help/repairs." },
    resultError: true
  },
  {
    id: "missing_input",
    label: "Missing CI repair input",
    description: "Exercises explicit unavailable labels for every request field.",
    input: {},
    parsedResult: { pending_action_id: 602, state: "pending", message: "Rerun CI repair?" }
  }
]
