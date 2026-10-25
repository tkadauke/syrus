import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"
import i18n from "@app/i18n"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const wakeProviderAdmissionToolCard = pendingActionToolCard("wake_provider_admission", {
  inputFields: [
    { key: "provider", format: "badge" },
    {
      key: "user_id",
      label: () => i18n.t("chat:wake_provider_admission.user_scope"),
      format: "entity",
      hrefPrefix: "/admin/users",
      emptyLabel: () => i18n.t("chat:wake_provider_admission.all_users")
    },
    { key: "reason", format: "markdown" }
  ],
  resultFields: [
    { path: "observed_preview.workflow_count", label: () => i18n.t("chat:wake_provider_admission.queued_workflows"), format: "number" },
    { path: "observed_preview.auto_retry_count", label: () => i18n.t("chat:wake_provider_admission.delayed_retries"), format: "number" }
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
    label: i18n.t("chat:wake_provider_admission.example_pending"),
    description: i18n.t("chat:wake_provider_admission.example_pending_description"),
    input: SCOPED_INPUT,
    parsedResult: actionResult("pending")
  },
  {
    id: "confirmed_scoped_wake",
    label: i18n.t("chat:wake_provider_admission.example_confirmed"),
    description: i18n.t("chat:wake_provider_admission.example_confirmed_description"),
    input: SCOPED_INPUT,
    parsedResult: actionResult("confirmed")
  },
  {
    id: "rejected_all_users_wake",
    label: i18n.t("chat:wake_provider_admission.example_rejected"),
    description: i18n.t("chat:wake_provider_admission.example_rejected_description"),
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
    label: i18n.t("chat:wake_provider_admission.example_error"),
    description: i18n.t("chat:wake_provider_admission.example_error_description"),
    input: SCOPED_INPUT,
    resultBody: JSON.stringify({ content: [{ type: "text", text: "Provider admission preview failed" }] }),
    resultError: true
  }
]

export default wakeProviderAdmissionToolCard
