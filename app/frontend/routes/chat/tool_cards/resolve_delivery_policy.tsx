import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EntityReference, Row, SectionLabel } from "../toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for resolve_delivery_policy (the tool-card work).
// Summarizes the resolved track/branch/grade-phase answers plus the
// approval and promotion/hotfix-sync/upstream-export/ref-movement toggles;
// the full ref_movement_actions map stays behind a disclosure.
type ToggleRow = { enabled: boolean; mode: string | null }
type UpstreamExportRow = ToggleRow & { afterLocalApproval: boolean | null }

type ResolvePolicyResult = {
  repository: string
  jobId: string | null
  deliveryTrack: string | null
  jobLandingBranch: string | null
  reviewGradePhase: string | null
  landingGradePhase: string | null
  approvalConfigured: boolean | null
  jobApprovalSatisfied: boolean | null
  requiresOperatorApprovalForPromotion: boolean | null
  promotion: ToggleRow | null
  hotfixSync: ToggleRow | null
  upstreamExport: UpstreamExportRow | null
  refMovementActions: Array<{ name: string; enabled: boolean; mode: string | null; gradePhases: string[] }>
}

const failureConfig: ToolFailureConfig = {
  title: "Delivery policy resolution",
  attempted: (context) =>
    displayValue(context.input?.job_id) ? `Resolve policy for JOB-${displayValue(context.input?.job_id)}` : "Resolve repository delivery policy",
  retrySafety: "unknown",
  recovery: "Check that a repository is attached and that the Job belongs to it, then retry."
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

function upstreamExportRow(value: unknown): UpstreamExportRow | null {
  const toggle = toggleRow(value)
  if (!toggle || !isPlainObject(value)) return null
  return {
    ...toggle,
    afterLocalApproval: typeof value.after_local_approval === "boolean" ? value.after_local_approval : null
  }
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
    requiresOperatorApprovalForPromotion:
      typeof approval.requires_operator_approval_for_promotion === "boolean" ? approval.requires_operator_approval_for_promotion : null,
    promotion: toggleRow(parsed.promotion),
    hotfixSync: toggleRow(parsed.hotfix_sync),
    upstreamExport: upstreamExportRow(parsed.upstream_export),
    refMovementActions: refMovementActions(parsed.ref_movement_actions)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  const track = result.deliveryTrack || "default"
  return result.jobId ? `Track: ${track} for JOB-${result.jobId}` : `Track: ${track}`
}

function ToggleBadge({ label, toggle }: { label: string; toggle: ToggleRow | null }) {
  if (!toggle) return null
  return (
    <Badge>
      {label}: {toggle.enabled ? (toggle.mode ? `on (${toggle.mode})` : "on") : "off"}
    </Badge>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference href={`https://github.com/${result.repository}`} kind="repository" repositorySlug={result.repository} />
        {result.jobId ? (
          <Badge>
            <EntityReference id={result.jobId} kind="job" />
          </Badge>
        ) : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Delivery track" value={result.deliveryTrack || "default"} />
        {result.jobLandingBranch ? <Row label="Landing branch" value={result.jobLandingBranch} wrap /> : null}
        {result.reviewGradePhase ? <Row label="Review phase" value={result.reviewGradePhase} /> : null}
        {result.landingGradePhase ? <Row label="Landing phase" value={result.landingGradePhase} /> : null}
      </dl>
      {result.approvalConfigured != null ? (
        <div className="flex flex-wrap items-center gap-2">
          <Badge>approval: {result.approvalConfigured ? "configured" : "not configured"}</Badge>
          {result.jobApprovalSatisfied != null ? <Badge>job approval: {result.jobApprovalSatisfied ? "satisfied" : "pending"}</Badge> : null}
          {result.requiresOperatorApprovalForPromotion != null ? (
            <Badge>promotion approval: {result.requiresOperatorApprovalForPromotion ? "operator required" : "not required"}</Badge>
          ) : null}
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        <ToggleBadge label="promotion" toggle={result.promotion} />
        <ToggleBadge label="hotfix sync" toggle={result.hotfixSync} />
        <ToggleBadge label="upstream export" toggle={result.upstreamExport} />
        {result.upstreamExport?.afterLocalApproval != null ? (
          <Badge>export after local approval: {result.upstreamExport.afterLocalApproval ? "yes" : "no"}</Badge>
        ) : null}
      </div>
      {result.refMovementActions.length > 0 ? (
        <Disclosure label={`${result.refMovementActions.length} ref movement ${result.refMovementActions.length === 1 ? "action" : "actions"}`}>
          <div className="space-y-1">
            <div className="text-xs text-text-secondary">
              Dispatch enabled actions with <span className="font-mono">dispatch_ref_movement_action</span>.
            </div>
            {result.refMovementActions.map((action) => (
              <div key={action.name}>
                <SectionLabel>{action.name}</SectionLabel>
                <div>
                  {action.enabled ? (action.mode ? `enabled (${action.mode})` : "enabled") : "disabled"}
                  {action.gradePhases.length > 0 ? ` · ${action.gradePhases.join(", ")}` : ""}
                </div>
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

export const examples: ToolCardExample[] = [
  {
    id: "job_policy",
    label: "Job-specific delivery policy",
    input: { job_id: 42 },
    parsedResult: {
      repository: "acme/widgets",
      job_id: 42,
      delivery_track: "staging",
      job_landing_branch: "release/a-very-long-mobile-branch-name",
      review_grade_phase: "review",
      landing_grade_phase: "landing",
      approval: { configured: true, job_approval_satisfied: true, requires_operator_approval_for_promotion: true },
      promotion: { enabled: true, mode: "auto" },
      hotfix_sync: { enabled: false, mode: null },
      upstream_export: { enabled: true, mode: "manual", after_local_approval: true },
      ref_movement_actions: { send_job_upstream: { enabled: true, mode: "manual", grade_phases: ["review"] } }
    }
  },
  {
    id: "default_repository_policy",
    label: "Repository policy without optional actions",
    parsedResult: {
      repository: "acme/widgets",
      delivery_track: "default",
      approval: { configured: false, requires_operator_approval_for_promotion: false },
      promotion: { enabled: false, mode: null },
      hotfix_sync: { enabled: false, mode: null },
      upstream_export: { enabled: false, mode: null, after_local_approval: false },
      ref_movement_actions: {}
    }
  },
  {
    id: "missing_repository",
    label: "No repository attached",
    resultBody: "Error: no repository attached",
    resultError: true
  }
]
