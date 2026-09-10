import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "../toolCardUi"

// Core-owned tool card for select_job_delivery_track (the tool-card work).
type SelectTrackResult = { jobId: string; previousTrack: string; track: string; resolvedTrack: string | null }

function parseResult(context: ToolCardContext): SelectTrackResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const jobId = displayValue(parsed.job_id)
  if (!jobId) return null

  return {
    jobId,
    previousTrack: displayValue(parsed.previous_delivery_track) || "default",
    track: displayValue(parsed.delivery_track) || "default",
    resolvedTrack: displayValue(parsed.resolved_delivery_track)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return `JOB-${result.jobId}: ${result.previousTrack} → ${result.track}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">JOB-{result.jobId}</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Previous track" value={result.previousTrack} />
        <Row label="New track" value={result.track} />
        {result.resolvedTrack ? <Row label="Resolved track" value={result.resolvedTrack} /> : null}
      </dl>
    </CardShell>
  )
}

const selectJobDeliveryTrackToolCard: ToolCardRenderer = {
  toolName: "select_job_delivery_track",
  collapsedSummary,
  renderExpanded
}

export default selectJobDeliveryTrackToolCard
