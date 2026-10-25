import type { ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

const rebaseJobCard: ToolCardRenderer = {
  ...maintenanceToolCard("rebase_job"),
  toolName: "rebase_job",
  // The structured card owns the reason as Markdown. Repeating the generic
  // input summary here exposes raw Markdown and crowds narrow layouts.
  argumentSummary: () => ""
}

export default rebaseJobCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:tool_card_examples.pending_job_rebase"),
    input: { job_id: 48, reason: "Refresh the branch after **main** changed." },
    parsedResult: {
      pending_confirmation_id: 32,
      pending_action_id: 32,
      state: "pending",
      reason: "Refresh the branch after **main** changed.",
      message: i18n.t("chat:tool_card_examples.rebase_confirmation_required")
    }
  },
  {
    id: "failed_request",
    label: i18n.t("chat:tool_card_examples.failed_job_rebase"),
    input: { job_id: 49, reason: "Retry after the dependency landed." },
    parsedResult: { error: "A rebase is already in progress." },
    resultError: true,
    resultBody: "Error: A rebase is already in progress."
  },
  {
    id: "long_reason",
    label: i18n.t("chat:tool_card_examples.long_rebase_reason"),
    description: i18n.t("chat:tool_card_examples.long_rebase_reason_description"),
    input: {
      job_id: 50,
      reason: `Rebase after **main** changed. ${"Preserve the dependency updates and rerun affected checks. ".repeat(10)}`
    },
    parsedResult: {
      pending_confirmation_id: 33,
      pending_action_id: 33,
      state: "pending",
      message: i18n.t("chat:tool_card_examples.rebase_confirmation_required")
    }
  }
]
