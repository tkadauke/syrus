import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const wakeProviderAdmissionToolCard = pendingActionToolCard("wake_provider_admission", {
  inputFields: [
    { key: "provider", format: "badge" },
    { key: "user_id", label: "User scope", format: "entity", hrefPrefix: "/admin/users", emptyLabel: "All users" },
    { key: "reason", format: "markdown" }
  ],
  resultFields: [
    { path: "observed_preview.workflow_count", label: "Queued workflows", format: "number" },
    { path: "observed_preview.auto_retry_count", label: "Delayed auto-retries", format: "number" }
  ]
})

const SCOPED_INPUT = {
  provider: "codex",
  user_id: 9,
  reason:
    "**Capacity recovered** after reviewing the latest provider evidence. Resume the scoped queue while preserving normal admission checks and retry guards."
}

const PREVIEW = {
  provider: "codex",
  workflow_ids: [4101, 4102, 4103, 4104, 4105, 4106, 4107, 4108, 4109, 4110, 4111, 4112],
  workflow_count: 12,
  auto_retry_attempt_ids: [71, 72, 73],
  auto_retry_count: 3
}

function actionResult(state: "pending" | "confirmed" | "rejected") {
  return {
    pending_confirmation_id: 501,
    pending_action_id: 501,
    state,
    reason: SCOPED_INPUT.reason,
    message: "Wake 12 queued codex workflows and 3 delayed auto-retries?",
    observed_preview: PREVIEW
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_scoped_wake",
    label: "Pending scoped wake",
    description: "Shows the provider badge, linked user scope, Markdown reason, and previewed impact before confirmation.",
    input: SCOPED_INPUT,
    parsedResult: actionResult("pending")
  },
  {
    id: "confirmed_scoped_wake",
    label: "Confirmed scoped wake",
    description: "Shows the same preview after the pending action has been confirmed.",
    input: SCOPED_INPUT,
    parsedResult: actionResult("confirmed")
  },
  {
    id: "rejected_all_users_wake",
    label: "Rejected all-users wake",
    description: "Shows a rejected request with an explicit all-users scope and zero delayed retries.",
    input: {
      provider: "claude",
      reason: "The broader wake was rejected while provider recovery evidence was still being reviewed."
    },
    parsedResult: {
      ...actionResult("rejected"),
      reason: "The broader wake was rejected while provider recovery evidence was still being reviewed.",
      message: "Wake 4 queued claude workflows and 0 delayed auto-retries?",
      observed_preview: {
        provider: "claude",
        workflow_ids: [4201, 4202, 4203, 4204],
        workflow_count: 4,
        auto_retry_attempt_ids: [],
        auto_retry_count: 0
      }
    }
  },
  {
    id: "preview_error",
    label: "Preview error",
    description: "Shows the requested inputs alongside a provider-admission preview failure.",
    input: SCOPED_INPUT,
    resultBody: JSON.stringify({ content: [{ type: "text", text: "Provider admission preview failed" }] }),
    resultError: true
  }
]

export default wakeProviderAdmissionToolCard
