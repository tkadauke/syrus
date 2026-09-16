import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, StatePill } from "../toolCardUi"

// Core-owned tool card for submit_coding_changes. The result only carries
// the pending-action confirmation shape; branch/title context (there is no
// Job yet at call time -- CodingHandoffCapture creates it once confirmed)
// comes from the tool call's own input arguments.
type SubmitCodingChangesResult = {
  pendingActionId: string | null
  state: string
  message: string | null
  branch: string | null
  title: string | null
}

function parseResult(context: ToolCardContext): SubmitCodingChangesResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const state = displayValue(parsed.state)
  if (!state) return null

  const input = isPlainObject(context.input) ? context.input : {}

  return {
    pendingActionId: displayValue(parsed.pending_action_id),
    state,
    message: displayValue(parsed.message),
    branch: displayValue(input.branch),
    title: displayValue(input.title)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return result.message || `Submit coding changes${result.branch ? ` for ${result.branch}` : ""} (${result.state})`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {result.pendingActionId ? <Badge>#{result.pendingActionId}</Badge> : null}
      </div>
      {result.title ? <Row label="Title" value={result.title} /> : null}
      {result.branch ? <Row label="Branch" value={result.branch} /> : null}
      {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
    </CardShell>
  )
}

const submitCodingChangesToolCard: ToolCardRenderer = {
  toolName: "submit_coding_changes",
  collapsedSummary,
  renderExpanded
}

export default submitCodingChangesToolCard
