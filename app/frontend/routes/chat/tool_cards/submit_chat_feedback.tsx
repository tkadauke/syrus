import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { JobRefLink } from "../adminToolCard"
import { Badge, CardShell, displayValue, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for submit_chat_feedback. The tool result only
// carries the pending-action confirmation shape (pending_action_id, state,
// message, and -- for a job that's still running/queued -- a "queued"
// status), so the job id and media refs are read back from the tool call's
// own input arguments.
type SubmitChatFeedbackResult = {
  jobId: string | null
  media: string[]
  pendingActionId: string | null
  state: string
  queued: boolean
  message: string | null
}

function mediaRefs(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const ref = displayValue(item)
    return ref ? [ref] : []
  })
}

function parseResult(context: ToolCardContext): SubmitChatFeedbackResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const state = displayValue(parsed.state)
  if (!state) return null

  const input = isPlainObject(context.input) ? context.input : {}

  return {
    jobId: displayValue(input.job_id),
    media: mediaRefs(input.media),
    pendingActionId: displayValue(parsed.pending_action_id) ?? displayValue(parsed.pending_confirmation_id),
    state,
    queued: displayValue(parsed.status) === "queued",
    message: displayValue(parsed.message)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return result.message || `Chat feedback ${result.queued ? "queued" : "pending confirmation"}${result.jobId ? ` for JOB-${result.jobId}` : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {result.jobId ? <JobRefLink jobId={result.jobId} /> : null}
        {result.pendingActionId ? <Badge>#{result.pendingActionId}</Badge> : null}
      </div>
      {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
      <div className="text-gray-500 dark:text-gray-400">
        {result.queued
          ? "Queued until the job becomes actionable; a chat_feedback workflow starts once it is confirmed."
          : "Confirming this will start a new chat_feedback workflow."}
      </div>
      {result.media.length > 0 ? (
        <div>
          <SectionLabel>Media</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {result.media.map((ref) => <Badge key={ref}>{ref}</Badge>)}
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

const submitChatFeedbackToolCard: ToolCardRenderer = {
  toolName: "submit_chat_feedback",
  collapsedSummary,
  renderExpanded
}

export default submitChatFeedbackToolCard
