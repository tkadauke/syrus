import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, OptionalReason, StatusCard, successOrError } from "../chatHelperToolCard"

type GoalResult = { goalId: string; status: string; reason: string | null }

function parseGoalResult(context: ToolCardContext) {
  return successOrError<GoalResult>(context, "Goal completion failed.", (parsed) => {
    const goalId = displayValue(parsed.goal_id)
    const status = displayValue(parsed.status)
    if (!goalId || !status) return null
    return { goalId, status, reason: displayValue(parsed.reason) }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  if (parsed.kind === "error") return "Goal completion failed"
  if (parsed.kind === "malformed") return "Goal completion returned an unexpected response"
  return `Goal #${parsed.data.goalId} -> ${parsed.data.status}`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  if (parsed.kind === "error") return <ErrorCard title="Goal completion" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Goal completion" />

  return (
    <StatusCard title="Goal completion" status={parsed.data.status}>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Goal" value={`#${parsed.data.goalId}`} />
        <Row label="Transition" value={`active -> ${parsed.data.status}`} />
        <OptionalReason reason={parsed.data.reason} />
      </dl>
    </StatusCard>
  )
}

const markGoalCompletedToolCard: ToolCardRenderer = {
  toolName: "mark_goal_completed",
  collapsedSummary,
  renderExpanded
}

export default markGoalCompletedToolCard
