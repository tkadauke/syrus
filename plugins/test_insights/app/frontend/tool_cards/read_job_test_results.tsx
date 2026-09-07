import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRunResultsPayload, RunResultsBody, runResultsSummary } from "../testRunResultsToolCard"

// Plugin-owned tool card for read_job_test_results (EPIC-292). Lives
// entirely inside the test_insights plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  const payload = parseRunResultsPayload(context)
  if (!payload) return null

  return payload.jobSlug ? `${payload.jobSlug}: ${runResultsSummary(payload)}` : runResultsSummary(payload)
}

function renderExpanded(context: ToolCardContext) {
  const payload = parseRunResultsPayload(context)
  if (!payload) return null

  return <RunResultsBody payload={payload} />
}

const readJobTestResultsToolCard: ToolCardRenderer = {
  toolName: "read_job_test_results",
  collapsedSummary,
  renderExpanded
}

export default readJobTestResultsToolCard
