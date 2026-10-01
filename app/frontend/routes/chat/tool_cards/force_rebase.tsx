import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type RebasePlan = {
  jobId: string | null
  slug: string | null
  state: string | null
  branchName: string | null
  currentBase: string | null
  targetBase: string | null
  prNumber: string | null
  commitsBehind: string | null
  checksState: string | null
  mergeableState: string | null
  landingQueuePosition: string | null
  landingQueueEntryPosition: string | null
  workflowTriggerKind: string | null
  bypassFrontOfQueue: boolean | null
  expectedLandingImpact: string | null
  warnings: string[]
}

type ForceRebaseCard = {
  kind: "plan" | "pending"
  state: string
  pendingActionId: string | null
  pendingGroupId: string | null
  memberCount: number | null
  message: string | null
  reason: string | null
  plans: RebasePlan[]
}

const failureConfig: ToolFailureConfig = {
  title: "Force rebase",
  attempted: (context) => {
    const jobId = stringFromInput(context, ["job_id"])
    const jobIds = Array.isArray(context.input?.job_ids) ? context.input.job_ids.map(displayValue).filter(Boolean) : []
    if (jobId) return `Force rebase JOB-${jobId}`
    if (jobIds.length > 0) return `Force rebase ${jobIds.map((id) => `JOB-${id}`).join(", ")}`
    return "Force rebase"
  },
  retrySafety: "caution",
  recovery:
    "Check whether a rebase or merge-train workflow is already active. Retry only after the blocking workflow, permission issue, or branch conflict is resolved."
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const label = displayValue(item)
    return label ? [label] : []
  })
}

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null
}

function parsePlan(value: unknown): RebasePlan | null {
  if (!isPlainObject(value)) return null

  const jobId = displayValue(value.job_id)
  if (!jobId) return null

  return {
    jobId,
    slug: displayValue(value.slug),
    state: displayValue(value.state),
    branchName: displayValue(value.branch_name),
    currentBase: displayValue(value.current_base),
    targetBase: displayValue(value.target_base),
    prNumber: displayValue(value.pr_number),
    commitsBehind: displayValue(value.commits_behind),
    checksState: displayValue(value.checks_state),
    mergeableState: displayValue(value.mergeable_state),
    landingQueuePosition: displayValue(value.landing_queue_position),
    landingQueueEntryPosition: displayValue(value.landing_queue_entry_position),
    workflowTriggerKind: displayValue(value.workflow_trigger_kind),
    bypassFrontOfQueue: booleanValue(value.bypass_front_of_queue),
    expectedLandingImpact: displayValue(value.expected_landing_impact),
    warnings: stringList(value.warnings)
  }
}

function parsePlans(value: unknown): RebasePlan[] {
  if (Array.isArray(value))
    return value.flatMap((item) => {
      const plan = parsePlan(item)
      return plan ? [plan] : []
    })

  const plan = parsePlan(value)
  return plan ? [plan] : []
}

function parseForceRebase(context: ToolCardContext): ForceRebaseCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const plans = parsePlans(parsed.plan).concat(parsePlans(parsed.plans))
  const pendingActionId = displayValue(parsed.pending_action_id) || displayValue(parsed.pending_confirmation_id)
  const pendingGroupId = displayValue(parsed.pending_action_group_id)
  const live = pendingActionId && displayValue(context.livePendingAction?.id) === pendingActionId ? context.livePendingAction : null
  const state = live?.state || displayValue(parsed.state) || (plans.length > 0 ? "planned" : null)
  if (!state || (plans.length === 0 && !pendingActionId && !pendingGroupId)) return null

  return {
    kind: pendingActionId || pendingGroupId ? "pending" : "plan",
    state,
    pendingActionId,
    pendingGroupId,
    memberCount: typeof parsed.member_count === "number" ? parsed.member_count : null,
    message: displayValue(parsed.message),
    reason: live?.reason || displayValue(parsed.reason),
    plans
  }
}

function targetLabel(plan: RebasePlan) {
  const job = plan.slug ? `JOB-${plan.jobId} (${plan.slug})` : `JOB-${plan.jobId}`
  return plan.prNumber ? `${job} PR #${plan.prNumber}` : job
}

function collapsedTargetLabel(plan: RebasePlan) {
  const target = targetLabel(plan)
  return plan.branchName ? `${target} · ${plan.branchName}` : target
}

function stateVerb(card: ForceRebaseCard) {
  const normalized = card.state.toLowerCase()
  if (normalized === "pending") return "pending confirmation"
  if (["confirmed", "completed", "succeeded", "success"].includes(normalized)) return "workflow queued"
  if (normalized === "rejected") return "request rejected"
  if (normalized === "cancelled" || normalized === "canceled") return "request cancelled"
  if (card.kind === "plan") return "plan reviewed"
  return card.state.replace(/_/g, " ")
}

function noOpLabel(plan: RebasePlan) {
  const behind = Number(plan.commitsBehind ?? "0")
  const alreadyCurrent = Number.isFinite(behind) && behind === 0 && plan.currentBase && plan.targetBase && plan.currentBase === plan.targetBase
  return alreadyCurrent ? "already current" : null
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const card = parseForceRebase(context)
  if (!card) return null

  const primary = card.plans[0]
  const target = primary ? collapsedTargetLabel(primary) : card.memberCount ? `${card.memberCount} Jobs` : "Job"
  const noOp = primary ? noOpLabel(primary) : null
  return [`Force rebase ${stateVerb(card)}`, target, noOp].filter(Boolean).join(" · ")
}

function PlanSummary({ plan }: { plan: RebasePlan }) {
  return (
    <div className="rounded border border-border bg-surface px-2 py-1">
      <div className="flex min-w-0 flex-wrap items-center gap-1">
        <span className="font-mono font-semibold text-text-primary">{targetLabel(plan)}</span>
        {plan.workflowTriggerKind ? <Badge>{plan.workflowTriggerKind}</Badge> : null}
        {noOpLabel(plan) ? <Badge>{noOpLabel(plan)}</Badge> : null}
      </div>
      <dl className="mt-2 grid gap-1 sm:grid-cols-2">
        {plan.branchName ? <Row label="Branch" value={plan.branchName} /> : null}
        {plan.currentBase ? <Row label="Current base" value={plan.currentBase} /> : null}
        {plan.targetBase ? <Row label="Target base" value={plan.targetBase} /> : null}
        {plan.commitsBehind ? <Row label="Commits behind" value={plan.commitsBehind} /> : null}
        {plan.checksState ? <Row label="Checks" value={plan.checksState} /> : null}
        {plan.mergeableState ? <Row label="Mergeability" value={plan.mergeableState} /> : null}
        {plan.landingQueueEntryPosition || plan.landingQueuePosition ? (
          <Row label="Landing queue" value={plan.landingQueueEntryPosition || plan.landingQueuePosition || ""} />
        ) : null}
        {plan.bypassFrontOfQueue != null ? <Row label="Bypass front of queue" value={plan.bypassFrontOfQueue ? "yes" : "no"} /> : null}
      </dl>
      {plan.expectedLandingImpact ? (
        <div className="mt-2">
          <SectionLabel>Expected downstream workflow</SectionLabel>
          <div className="mt-0.5 text-text-secondary">{plan.expectedLandingImpact}</div>
        </div>
      ) : null}
      {plan.warnings.length > 0 ? (
        <div className="mt-2">
          <SectionLabel>Audit warnings</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {plan.warnings.map((warning) => (
              <Badge key={warning}>{warning}</Badge>
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

function RetryGuidance({ card }: { card: ForceRebaseCard }) {
  if (card.state === "rejected")
    return <div className="text-text-secondary">Rejected by the operator. Re-request only with a clearer audit reason or after the target changes.</div>
  if (["failed", "failure", "error"].includes(card.state))
    return <div className="text-text-secondary">Resolve the reported branch, permission, or active-workflow blocker, then request the force rebase again.</div>
  if (card.state === "pending")
    return <div className="text-text-secondary">Waiting for operator confirmation. This will enqueue a repair rebase workflow when approved.</div>
  if (["confirmed", "completed", "succeeded", "success"].includes(card.state))
    return <div className="text-text-secondary">Confirmed. Watch the created rebase or stack-rebase workflow and retry only if that workflow fails.</div>
  return <div className="text-text-secondary">Review the plan before confirming; this is a side-effecting control action that can move the PR branch.</div>
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const card = parseForceRebase(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.state} />
        <span className="font-mono font-semibold text-text-primary">Force rebase</span>
        {card.pendingGroupId ? <Badge>group #{card.pendingGroupId}</Badge> : null}
        {card.pendingActionId ? <Badge>pending #{card.pendingActionId}</Badge> : null}
        {card.memberCount != null ? (
          <Badge>
            {card.memberCount} {card.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>

      {card.message ? <div className="text-text-secondary">{card.message}</div> : null}

      {card.reason ? (
        <div>
          <SectionLabel>Audit reason</SectionLabel>
          <div className="mt-0.5 text-text-secondary">{card.reason}</div>
        </div>
      ) : null}

      {card.plans.length > 0 ? (
        <div className="space-y-2">
          <SectionLabel>Targets</SectionLabel>
          {card.plans.map((plan) => (
            <PlanSummary key={plan.jobId || targetLabel(plan)} plan={plan} />
          ))}
        </div>
      ) : (
        <EmptyState>No rebase plan was returned. Use Raw details to inspect the pending action id and message.</EmptyState>
      )}

      <div>
        <SectionLabel>Failure and retry guidance</SectionLabel>
        <RetryGuidance card={card} />
      </div>
    </CardShell>
  )
}

const forceRebaseToolCard: ToolCardRenderer = {
  toolName: "force_rebase",
  collapsedSummary,
  renderExpanded
}

export default forceRebaseToolCard

const requestedPlan = {
  job_id: 4222,
  slug: "repair-ci",
  state: "approved",
  branch_name: "syrus/direct-4222",
  current_base: "main",
  target_base: "main",
  pr_number: 314,
  commits_behind: 3,
  checks_state: "failure",
  mergeable_state: "dirty",
  landing_queue_position: 4,
  workflow_trigger_kind: "rebase",
  bypass_front_of_queue: true,
  expected_landing_impact: "successful rebase will retry landing immediately",
  warnings: ["failing_or_pending_checks", "dirty_mergeability", "behind_base", "not_front_of_queue"]
}

export const examples: ToolCardExample[] = [
  {
    id: "requested",
    label: "Requested and pending confirmation",
    input: { job_id: 4222, reason: "Bypass queue position." },
    parsedResult: {
      pending_confirmation_id: 77,
      pending_action_id: 77,
      state: "pending",
      reason: "Bypass queue position.",
      message: "Force rebase for repair-ci? Target base: main.",
      plan: requestedPlan
    }
  },
  {
    id: "already_current_noop",
    label: "Already current / no-op plan",
    input: { job_id: 4223, dry_run: true },
    parsedResult: {
      plan: {
        ...requestedPlan,
        job_id: 4223,
        slug: "already-current",
        branch_name: "syrus/direct-4223",
        pr_number: 315,
        commits_behind: 0,
        checks_state: "success",
        mergeable_state: "clean",
        landing_queue_position: 1,
        expected_landing_impact: "successful rebase will retry landing immediately",
        warnings: []
      }
    }
  },
  {
    id: "conflict_failure",
    label: "Conflict or active workflow failure",
    input: { job_id: 4224, reason: "Repair branch drift." },
    resultBody: "A rebase is already in progress - wait for it to finish.",
    resultError: true
  },
  {
    id: "permission_pending_action",
    label: "Permission / pending operator action",
    input: { job_ids: [4225, 4226], reason: "Both branches drifted behind the same base rewrite." },
    parsedResult: {
      pending_action_group_id: 15,
      pending_action_id: 81,
      pending_confirmation_id: 81,
      state: "pending",
      member_count: 2,
      message: "Force rebase for 2 Jobs?",
      plans: [
        { ...requestedPlan, job_id: 4225, slug: "first-branch", branch_name: "syrus/direct-4225", pr_number: 316 },
        { ...requestedPlan, job_id: 4226, slug: "second-branch", branch_name: "syrus/direct-4226", pr_number: 317, warnings: ["not_front_of_queue"] }
      ]
    }
  }
]
