import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { displayValue, EntityReference, Row } from "../toolCardUi"

function RequestDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const blockerKey = displayValue(context.input?.blocker_key)
  const reason = displayValue(context.input?.reason)

  return (
    <div className="space-y-2">
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Job" value={jobId ? <EntityReference id={jobId} kind="job" /> : "Not provided"} />
        <Row label="Blocker key" value={blockerKey ? <span className="break-all font-mono">{blockerKey}</span> : "Not provided"} />
      </dl>
      {reason ? (
        <MarkdownPreview maxLines={4} modalLabel="Audit reason" text={reason} title="Audit reason" />
      ) : (
        <Row label="Audit reason" value="Not provided" />
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
  return result ? <PendingActionResultCard details={<RequestDetails context={context} />} omitBlocker omitJob omitReason result={result} /> : null
}

const overrideLandingBlockerOnceToolCard: ToolCardRenderer = {
  toolName: "override_landing_blocker_once",
  collapsedSummary,
  renderExpanded
}

export default overrideLandingBlockerOnceToolCard

const longBlockerKey = "dependency_blocked_by_an_exceptionally_long_upstream_job_identifier"

export const examples: ToolCardExample[] = [
  {
    id: "pending_override",
    label: "Pending blocker override",
    description: "Shows the linked Job, long wrapping blocker key, and Markdown audit reason before confirmation.",
    input: {
      job_id: 4222,
      blocker_key: longBlockerKey,
      reason: "**Reviewed** the upstream dependency and approved this one-time override."
    },
    parsedResult: {
      pending_confirmation_id: 501,
      pending_action_id: 501,
      state: "pending",
      message: `Override ${longBlockerKey} once for JOB-4222? Refreshed state is included in the pending action.`
    }
  },
  {
    id: "applied_override",
    label: "Applied blocker override",
    description: "Shows the completed live pending-action state while retaining the original audit fields.",
    input: {
      job_id: 4222,
      blocker_key: "landing_paused",
      reason: "The queue pause was confirmed stale after **manual review**."
    },
    parsedResult: {
      pending_confirmation_id: 502,
      pending_action_id: 502,
      state: "pending",
      message: "Override landing_paused once for JOB-4222? Refreshed state is included in the pending action."
    },
    livePendingAction: {
      id: 502,
      action: "override_landing_blocker_once",
      state: "confirmed",
      label: "Override landing blocker once",
      detail: "The one-time override was recorded and the landing queue was re-enqueued.",
      execution_status: "applied",
      execution_step: "Applied.",
      reason: "The queue pause was confirmed stale after **manual review**.",
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/502/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/502/reject"
    }
  },
  {
    id: "validation_error",
    label: "Blocker changed validation error",
    description: "Keeps the requested Job, blocker key, and audit reason visible when validation fails.",
    input: {
      job_id: 4222,
      blocker_key: "dependencies",
      reason: "Override approved after **manual review** of the dependency graph."
    },
    parsedResult: {
      error: "invalid_request",
      message: "The landing blocker changed before confirmation."
    },
    resultError: true
  },
  {
    id: "missing_input",
    label: "Missing request input",
    description: "Exercises unavailable labels for every audit-critical request field.",
    parsedResult: {
      pending_confirmation_id: 503,
      pending_action_id: 503,
      state: "pending",
      message: "Override landing_paused once for JOB-4222?"
    }
  }
]
