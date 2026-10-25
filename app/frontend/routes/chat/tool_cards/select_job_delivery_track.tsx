import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EntityReference, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"
import i18n from "@app/i18n"

// Core-owned tool card for select_job_delivery_track (the tool-card work).
type SelectTrackResult = { jobId: string; previousTrack: string | null; storedTrack: string | null; resolvedTrack: string | null }

function failureConfig(): ToolFailureConfig {
  return {
    title: i18n.t("chat:mutation_delivery_track_selection"),
    attempted: (context) => {
      const jobId = stringFromInput(context, ["job_id"])
      const requestedTrack = displayValue(context.input?.track)
      const action = requestedTrack
        ? i18n.t("chat:mutation_set_delivery_track", { track: requestedTrack })
        : i18n.t("chat:mutation_clear_delivery_track_default")
      return jobId ? i18n.t("chat:mutation_action_for_job", { action, id: jobId }) : action
    },
    retrySafety: "caution",
    recovery: i18n.t("chat:mutation_delivery_track_recovery")
  }
}

function trackLabel(track: string | null) {
  return track ?? i18n.t("chat:mutation_default_not_stored")
}

function requestedTrackLabel(context: ToolCardContext) {
  return displayValue(context.input?.track) ?? i18n.t("chat:mutation_clear_to_default")
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
  if (toolFailureDetected(context)) return toolFailureCollapsedSummary(context, failureConfig())
  const result = parseResult(context)
  if (!result) return null
  return `JOB-${result.jobId}: ${trackLabel(result.previousTrack)} → ${trackLabel(result.storedTrack)}`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard context={context} config={failureConfig()} />
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.jobId} kind="job" />
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={i18n.t("chat:mutation_requested_track")} value={requestedTrackLabel(context)} />
        <Row label={i18n.t("chat:mutation_previously_stored")} value={trackLabel(result.previousTrack)} />
        <Row label={i18n.t("chat:mutation_stored_track")} value={trackLabel(result.storedTrack)} />
        <Row label={i18n.t("chat:mutation_resolved_track")} value={result.resolvedTrack ?? i18n.t("chat:mutation_unavailable")} />
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
    get label() {
      return i18n.t("chat:mutation_example_configured_track")
    },
    input: { job_id: 4225, track: "staging" },
    parsedResult: { job_id: 4225, previous_delivery_track: null, delivery_track: "staging", resolved_delivery_track: "staging" }
  },
  {
    id: "cleared_to_default",
    get label() {
      return i18n.t("chat:mutation_example_cleared_track")
    },
    input: { job_id: 4225, track: "" },
    parsedResult: { job_id: 4225, previous_delivery_track: "staging", delivery_track: null, resolved_delivery_track: "default" }
  },
  {
    id: "unconfigured_fallback",
    get label() {
      return i18n.t("chat:mutation_example_fallback_track")
    },
    input: { job_id: 4225, track: "canary" },
    parsedResult: { job_id: 4225, previous_delivery_track: "staging", delivery_track: "canary", resolved_delivery_track: "default" }
  },
  {
    id: "closed_job_error",
    get label() {
      return i18n.t("chat:mutation_example_closed_job_error")
    },
    input: { job_id: 4225, track: "staging" },
    resultBody: "Error: job is not open",
    resultError: true
  }
]

export default selectJobDeliveryTrackToolCard
