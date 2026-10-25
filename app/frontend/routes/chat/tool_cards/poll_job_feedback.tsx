import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { maintenanceToolCard } from "../jobEpicMaintenanceToolCard"

export default maintenanceToolCard("poll_job_feedback")

export const examples: ToolCardExample[] = [
  {
    id: "pending_confirmation",
    label: i18n.t("chat:tool_card_examples.pending_feedback_poll"),
    input: { job_id: 46 },
    parsedResult: {
      pending_confirmation_id: 29,
      pending_action_id: 29,
      state: "pending",
      message: "Poll PR feedback for JOB-46?"
    }
  },
  {
    id: "pending_without_input",
    label: i18n.t("chat:tool_card_examples.pending_feedback_poll_without_input"),
    parsedResult: {
      pending_confirmation_id: 30,
      pending_action_id: 30,
      state: "pending",
      message: "Poll PR feedback for JOB-47?"
    }
  },
  {
    id: "confirmed_with_pr",
    label: i18n.t("chat:tool_card_examples.confirmed_feedback_poll"),
    description: i18n.t("chat:tool_card_examples.confirmed_feedback_poll_description"),
    input: { job_id: 46 },
    parsedResult: {
      pending_confirmation_id: 31,
      pending_action_id: 31,
      state: "pending",
      message: "Poll PR feedback for JOB-46?"
    },
    livePendingAction: {
      id: 31,
      action: "poll_job_feedback",
      state: "confirmed",
      label: i18n.t("chat:tool_card_examples.poll_feedback_job_label", { job: "JOB-46" }),
      detail: "job_id: 46",
      execution_status: "succeeded",
      execution_step: "Queueing PR feedback poll...",
      resource_title: "Improve feedback polling",
      resource_url: "/jobs/46",
      outcome: {
        pr_number: 321,
        pr_url: "https://github.com/acme/widgets/pull/321"
      },
      app_confirm_path: "/api/v1/app/chats/1/pending_actions/31/confirm",
      app_reject_path: "/api/v1/app/chats/1/pending_actions/31/reject"
    }
  }
]
