import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, Row, SectionLabel } from "../toolCardUi"

// Core-owned tool card for resolve_delivery_policy (EPIC-293 / JOB-4225).
// Summarizes the resolved track/branch/grade-phase answers plus the
// approval and promotion/hotfix-sync/upstream-export/ref-movement toggles;
// the full ref_movement_actions map stays behind a disclosure.
type ToggleRow = { enabled: boolean; mode: string | null }

type ResolvePolicyResult = {
  repository: string
  jobId: string | null
  deliveryTrack: string | null
  jobLandingBranch: string | null
  reviewGradePhase: string | null
  landingGradePhase: string | null
  approvalConfigured: boolean | null
  jobApprovalSatisfied: boolean | null
  promotion: ToggleRow | null
  hotfixSync: ToggleRow | null
  upstreamExport: ToggleRow | null
  refMovementActions: Array<{ name: string; enabled: boolean; mode: string | null; gradePhases: string[] }>
}

function toggleRow(value: unknown): ToggleRow | null {
  if (!isPlainObject(value)) return null
  return { enabled: value.enabled === true, mode: displayValue(value.mode) }
}

function refMovementActions(value: unknown): ResolvePolicyResult["refMovementActions"] {
  if (!isPlainObject(value)) return []

  return Object.entries(value).flatMap(([name, config]) => {
    if (!isPlainObject(config)) return []
    const gradePhases = Array.isArray(config.grade_phases) ? config.grade_phases.flatMap((phase) => (typeof phase === "string" && phase ? [phase] : [])) : []
    return [{ name, enabled: config.enabled === true, mode: displayValue(config.mode), gradePhases }]
  })
}

function parseResult(context: ToolCardContext): ResolvePolicyResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const repository = displayValue(parsed.repository)
  if (!repository) return null

  const approval = isPlainObject(parsed.approval) ? parsed.approval : {}

  return {
    repository,
    jobId: displayValue(parsed.job_id),
    deliveryTrack: displayValue(parsed.delivery_track),
    jobLandingBranch: displayValue(parsed.job_landing_branch),
    reviewGradePhase: displayValue(parsed.review_grade_phase),
    landingGradePhase: displayValue(parsed.landing_grade_phase),
    approvalConfigured: typeof approval.configured === "boolean" ? approval.configured : null,
    jobApprovalSatisfied: typeof approval.job_approval_satisfied === "boolean" ? approval.job_approval_satisfied : null,
    promotion: toggleRow(parsed.promotion),
    hotfixSync: toggleRow(parsed.hotfix_sync),
    upstreamExport: toggleRow(parsed.upstream_export),
    refMovementActions: refMovementActions(parsed.ref_movement_actions)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const track = result.deliveryTrack || "default"
  return result.jobId ? `Track: ${track} for JOB-${result.jobId}` : `Track: ${track}`
}

function ToggleBadge({ label, toggle }: { label: string; toggle: ToggleRow | null }) {
  if (!toggle) return null
  return (
    <Badge>{label}: {toggle.enabled ? (toggle.mode ? `on (${toggle.mode})` : "on") : "off"}</Badge>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{result.repository}</span>
        {result.jobId ? <Badge>JOB-{result.jobId}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Delivery track" value={result.deliveryTrack || "default"} />
        {result.jobLandingBranch ? <Row label="Landing branch" value={result.jobLandingBranch} /> : null}
        {result.reviewGradePhase ? <Row label="Review phase" value={result.reviewGradePhase} /> : null}
        {result.landingGradePhase ? <Row label="Landing phase" value={result.landingGradePhase} /> : null}
      </dl>
      {result.approvalConfigured != null ? (
        <div className="flex flex-wrap items-center gap-2">
          <Badge>approval: {result.approvalConfigured ? "configured" : "not configured"}</Badge>
          {result.jobApprovalSatisfied != null ? <Badge>job approval: {result.jobApprovalSatisfied ? "satisfied" : "pending"}</Badge> : null}
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        <ToggleBadge label="promotion" toggle={result.promotion} />
        <ToggleBadge label="hotfix sync" toggle={result.hotfixSync} />
        <ToggleBadge label="upstream export" toggle={result.upstreamExport} />
      </div>
      {result.refMovementActions.length > 0 ? (
        <Disclosure label={`${result.refMovementActions.length} ref movement ${result.refMovementActions.length === 1 ? "action" : "actions"}`}>
          <div className="space-y-1">
            {result.refMovementActions.map((action) => (
              <div key={action.name}>
                <SectionLabel>{action.name}</SectionLabel>
                <div>{action.enabled ? (action.mode ? `enabled (${action.mode})` : "enabled") : "disabled"}{action.gradePhases.length > 0 ? ` · ${action.gradePhases.join(", ")}` : ""}</div>
              </div>
            ))}
          </div>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const resolveDeliveryPolicyToolCard: ToolCardRenderer = {
  toolName: "resolve_delivery_policy",
  collapsedSummary,
  renderExpanded
}

export default resolveDeliveryPolicyToolCard
