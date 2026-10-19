import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EntityReference, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for select_job_delivery_track (the tool-card work).
type SelectTrackResult = { jobId: string; previousTrack: string | null; storedTrack: string | null; resolvedTrack: string | null }

const failureConfig: ToolFailureConfig = {
  title: "Delivery track selection",
  attempted: (context) => {
    const jobId = stringFromInput(context, ["job_id"])
    const requestedTrack = displayValue(context.input?.track)
    const action = requestedTrack ? `Set delivery track to ${requestedTrack}` : "Clear delivery track to default"
    return jobId ? `${action} for JOB-${jobId}` : action
  },
  retrySafety: "caution",
  recovery: "Check that the Job is still open and has not been approved or started landing, then retry if appropriate."
}

function trackLabel(track: string | null) {
  return track ?? "Default (not stored)"
}

function requestedTrackLabel(context: ToolCardContext) {
  return displayValue(context.input?.track) ?? "Clear to default"
}

function parseResult(context: ToolCardContext): SelectTrackResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const jobId = displayValue(parsed.job_id)
  if (!jobId) return null

  return {
    jobId,
    previousTrack: displayValue(parsed.previous_delivery_track),
    storedTrack: displayValue(parsed.delivery_track),
    resolvedTrack: displayValue(parsed.resolved_delivery_track)
  }
}

function collapsedSummary(context: ToolCardContext) {
  if (toolFailureDetected(context)) return toolFailureCollapsedSummary(context, failureConfig)
  const result = parseResult(context)
  if (!result) return null
  return `JOB-${result.jobId}: ${trackLabel(result.previousTrack)} → ${trackLabel(result.storedTrack)}`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard context={context} config={failureConfig} />
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.jobId} kind="job" />
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Requested track" value={requestedTrackLabel(context)} />
        <Row label="Previously stored" value={trackLabel(result.previousTrack)} />
        <Row label="Stored track" value={trackLabel(result.storedTrack)} />
        <Row label="Resolved track" value={result.resolvedTrack ?? "Unavailable"} />
      </dl>
    </CardShell>
  )
}

const selectJobDeliveryTrackToolCard: ToolCardRenderer = {
  toolName: "select_job_delivery_track",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "configured_track",
    label: "Configured delivery track",
    input: { job_id: 4225, track: "staging" },
    parsedResult: { job_id: 4225, previous_delivery_track: null, delivery_track: "staging", resolved_delivery_track: "staging" }
  },
  {
    id: "cleared_to_default",
    label: "Cleared to default",
    input: { job_id: 4225, track: "" },
    parsedResult: { job_id: 4225, previous_delivery_track: "staging", delivery_track: null, resolved_delivery_track: "default" }
  },
  {
    id: "unconfigured_fallback",
    label: "Unconfigured track falls back",
    input: { job_id: 4225, track: "canary" },
    parsedResult: { job_id: 4225, previous_delivery_track: "staging", delivery_track: "canary", resolved_delivery_track: "default" }
  },
  {
    id: "closed_job_error",
    label: "Closed Job error",
    input: { job_id: 4225, track: "staging" },
    resultBody: "Error: job is not open",
    resultError: true
  }
]

export default selectJobDeliveryTrackToolCard
