import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseRunResultsPayload, RunResultsBody, runResultsSummary } from "../testRunResultsToolCard"

// Plugin-owned tool card for read_run_test_results (the pending-action tool-card work). Lives
// entirely inside the test_insights plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  const payload = parseRunResultsPayload(context)
  if (!payload) return null

  return payload.runId ? `RUN-${payload.runId}: ${runResultsSummary(payload)}` : runResultsSummary(payload)
}

function renderExpanded(context: ToolCardContext) {
  const payload = parseRunResultsPayload(context)
  if (!payload) return null

  return <RunResultsBody payload={payload} />
}

const readRunTestResultsToolCard: ToolCardRenderer = {
  toolName: "read_run_test_results",
  collapsedSummary,
  renderExpanded
}

export default readRunTestResultsToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "run_with_passing_tests",
    label: "Run with passing tests",
    input: { run_id: 200 },
    parsedResult: {
      job_id: 10,
      job_slug: "JOB-10",
      workflow_id: 30,
      run_id: 200,
      grader_name: "vitest",
      test_runs: [
        {
          id: 1,
          grader_name: "vitest",
          total_count: 4,
          passed_count: 4,
          failed_count: 0,
          skipped_count: 0,
          error_count: 0,
          duration_ms: 900,
          failed_error_cases: [],
          failed_error_case_count: 0,
          failed_error_cases_omitted: 0,
          slow_cases: [],
          slow_case_count: 0,
          slow_cases_omitted: 0
        }
      ]
    }
  },
  {
    id: "run_without_results",
    label: "Run without results",
    parsedResult: { job_id: 10, job_slug: "JOB-10", workflow_id: 30, run_id: 201, grader_name: null, test_runs: [] }
  }
]
