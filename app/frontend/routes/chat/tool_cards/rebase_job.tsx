import type { ToolCardExample } from "@app/pluginToolCards"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

const rebaseJobCard = maintenanceToolCard("rebase_job")

export default {
  ...rebaseJobCard,
  toolName: "rebase_job",
  // The structured card owns the reason as Markdown. Repeating the generic
  // input summary here exposes raw Markdown and crowds narrow layouts.
  argumentSummary: (_input?: Record<string, unknown>) => ""
}

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: "Pending Job rebase",
    input: { job_id: 48, reason: "Refresh the branch after **main** changed." },
    parsedResult: {
      pending_confirmation_id: 32,
      pending_action_id: 32,
      state: "pending",
      reason: "Refresh the branch after **main** changed.",
      message: "Job rebase requires operator confirmation."
    }
  },
  {
    id: "failed_request",
    label: "Failed Job rebase request",
    input: { job_id: 49, reason: "Retry after the dependency landed." },
    parsedResult: { error: "A rebase is already in progress." },
    resultError: true,
    resultBody: "Error: A rebase is already in progress."
  },
  {
    id: "long_reason",
    label: "Long rebase reason",
    description: "Exercises the expandable Markdown reason on narrow and wide layouts.",
    input: {
      job_id: 50,
      reason: `Rebase after **main** changed. ${"Preserve the dependency updates and rerun affected checks. ".repeat(10)}`
    },
    parsedResult: {
      pending_confirmation_id: 33,
      pending_action_id: 33,
      state: "pending",
      message: "Job rebase requires operator confirmation."
    }
  }
]
