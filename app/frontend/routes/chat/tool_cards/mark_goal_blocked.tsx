import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, OptionalReason, StatusCard, successOrError } from "../chatHelperToolCard"

type GoalResult = { goalId: string; status: string; reason: string | null }

function parseGoalResult(context: ToolCardContext) {
  return successOrError<GoalResult>(context, "Goal blocked transition failed.", (parsed) => {
    const goalId = displayValue(parsed.goal_id)
    const status = displayValue(parsed.status)
    if (!goalId || !status) return null
    return { goalId, status, reason: displayValue(parsed.reason) }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  if (parsed.kind === "error") return "Goal blocked transition failed"
  if (parsed.kind === "malformed") return "Goal blocked transition returned an unexpected response"
  return `Goal #${parsed.data.goalId} -> ${parsed.data.status}`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  if (parsed.kind === "error") return <ErrorCard title="Goal blocked transition" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Goal blocked transition" />

  return (
    <StatusCard title="Goal blocked transition" status={parsed.data.status}>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Goal" value={`#${parsed.data.goalId}`} />
        <Row label="Transition" value={`active -> ${parsed.data.status}`} />
        <OptionalReason reason={parsed.data.reason} />
      </dl>
    </StatusCard>
  )
}

const markGoalBlockedToolCard: ToolCardRenderer = {
  toolName: "mark_goal_blocked",
  collapsedSummary,
  renderExpanded
}

export default markGoalBlockedToolCard
