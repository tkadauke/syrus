import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeToolCard, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"
import i18n from "@app/i18n"

function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return i18n.t("chat:mutation_open_coding_mode_failed")
  return model.result ? localModeJobOutcomeSummary(model.result) : null
}

function renderExpanded(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  return model.error || model.result ? <LocalModeJobOutcomeToolCard context={context} /> : null
}

export const examples: ToolCardExample[] = [
  {
    id: "opened",
    get label() {
      return i18n.t("chat:mutation_example_opened_coding_mode")
    },
    input: { job_id: 4225 },
    parsedResult: {
      job_id: 4225,
      job_state: "coding",
      branch_name: "syrus/direct-4225-improve-coding-mode-card",
      checkout_branch: "coding/chat-98",
      repository_slug: "tkadauke/syrus",
      message: "JOB-4225 is now open in Coding Mode on checkout branch `coding/chat-98`."
    }
  },
  {
    id: "error",
    get label() {
      return i18n.t("chat:mutation_example_open_failed")
    },
    input: { job_id: 4225 },
    resultBody: "The job cannot be opened in Coding Mode.",
    resultError: true
  }
]

const openInCodingModeToolCard: ToolCardRenderer = { toolName: "open_in_coding_mode", collapsedSummary, renderExpanded }

export default openInCodingModeToolCard
