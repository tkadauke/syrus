import i18n from "../../../i18n"
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
  title: i18n.t("chat:ops_delivery_policy_resolution_311cfb"),
  attempted: (context) =>
    displayValue(context.input?.job_id)
      ? `Resolve policy for JOB-${displayValue(context.input?.job_id)}`
      : i18n.t("chat:ops_resolve_repository_delivery_policy_5b97b2"),
  retrySafety: "unknown",
  recovery: i18n.t("chat:ops_check_that_a_repository_is_attached_and_that_the_job_bel_fb3f39")
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
  return result.jobId ? i18n.t("chat:delivery_track_for_job", { track, id: result.jobId }) : i18n.t("chat:delivery_track_summary", { track })
}

function ToggleBadge({ label, toggle }: { label: string; toggle: ToggleRow | null }) {
  if (!toggle) return null
  return (
    <Badge>
      {label}: {toggle.enabled ? (toggle.mode ? i18n.t("chat:enabled_with_mode", { mode: toggle.mode }) : i18n.t("chat:enabled")) : i18n.t("chat:disabled")}
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
        <Row label={i18n.t("chat:ops_delivery_track_cf2fab")} value={result.deliveryTrack || "default"} />
        {result.jobLandingBranch ? <Row label={i18n.t("chat:ops_landing_branch_0e503e")} value={result.jobLandingBranch} wrap /> : null}
        {result.reviewGradePhase ? <Row label={i18n.t("chat:ops_review_phase_507ec1")} value={result.reviewGradePhase} /> : null}
        {result.landingGradePhase ? <Row label={i18n.t("chat:ops_landing_phase_987d16")} value={result.landingGradePhase} /> : null}
      </dl>
      {result.approvalConfigured != null ? (
        <div className="flex flex-wrap items-center gap-2">
          <Badge>approval: {result.approvalConfigured ? "configured" : i18n.t("chat:ops_not_configured_67f214")}</Badge>
          {result.jobApprovalSatisfied != null ? (
            <Badge>{i18n.t("chat:job_approval_state", { state: result.jobApprovalSatisfied ? i18n.t("chat:satisfied") : i18n.t("chat:pending") })}</Badge>
          ) : null}
          {result.requiresOperatorApprovalForPromotion != null ? (
            <Badge>
              promotion approval:{" "}
              {result.requiresOperatorApprovalForPromotion ? i18n.t("chat:ops_operator_required_a4b75a") : i18n.t("chat:ops_not_required_c64105")}
            </Badge>
          ) : null}
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        <ToggleBadge label="promotion" toggle={result.promotion} />
        <ToggleBadge label={i18n.t("chat:ops_hotfix_sync_b202ff")} toggle={result.hotfixSync} />
        <ToggleBadge label={i18n.t("chat:ops_upstream_export_4d9da1")} toggle={result.upstreamExport} />
        {result.upstreamExport?.afterLocalApproval != null ? (
          <Badge>
            {i18n.t("chat:export_after_local_approval", { value: result.upstreamExport.afterLocalApproval ? i18n.t("chat:yes") : i18n.t("chat:no") })}
          </Badge>
        ) : null}
      </div>
      {result.refMovementActions.length > 0 ? (
        <Disclosure label={i18n.t("chat:ref_movement_action_count", { count: result.refMovementActions.length })}>
          <div className="space-y-1">
            <div className="text-xs text-text-secondary">
              Dispatch enabled actions with <span className="font-mono">dispatch_ref_movement_action</span>.
            </div>
            {result.refMovementActions.map((action) => (
              <div key={action.name}>
                <SectionLabel>{action.name}</SectionLabel>
                <div>
                  {action.enabled ? (action.mode ? i18n.t("chat:enabled_with_mode", { mode: action.mode }) : i18n.t("chat:enabled")) : i18n.t("chat:disabled")}
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
    label: i18n.t("chat:ops_job_specific_delivery_policy_8ad031"),
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
    label: i18n.t("chat:ops_repository_policy_without_optional_actions_6dd73b"),
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
    label: i18n.t("chat:ops_no_repository_attached_b11206"),
    resultBody: i18n.t("chat:ops_error_no_repository_attached_e14fd9"),
    resultError: true
  }
]
