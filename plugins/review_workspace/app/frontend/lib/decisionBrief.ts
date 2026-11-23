import type { JobDetailPayload, JobWorkflow } from "@app/api/jobs"

export type ChangeScope = { files_changed: number; additions: number; deletions: number; truncated?: boolean }

export type BriefTone = "success" | "warning" | "danger" | "neutral"

// Each row carries a translation key and interpolation values rather than
// prose so the component stays localized; rows exist only for signals that are
// actually present in the payload.
export type BriefRow = { id: string; tone: BriefTone; labelKey: string; valueKey: string; values?: Record<string, string | number> }

type ReviewIteration = { iteration?: number; verdict?: string; non_blocking_findings?: unknown[] }

const REVIEW_KINDS = [
  { id: "adversarial", artifact: "adversarial_review_iterations", labelKey: "brief_adversarial_review" },
  { id: "security", artifact: "security_review_iterations", labelKey: "brief_security_review" }
] as const

function latestIteration(workflows: JobWorkflow[], artifact: string): ReviewIteration | null {
  let best: { workflowId: number; iteration: ReviewIteration } | null = null
  for (const workflow of workflows) {
    const iterations = workflow.artifacts?.[artifact]
    if (!Array.isArray(iterations) || iterations.length === 0) continue
    const last = (iterations as ReviewIteration[]).reduce((a, b) => ((b.iteration ?? 0) >= (a.iteration ?? 0) ? b : a))
    if (!best || workflow.id >= best.workflowId) best = { workflowId: workflow.id, iteration: last }
  }
  return best?.iteration ?? null
}

function readinessRow(payload: JobDetailPayload, canApprove: boolean, dependencyBlocked: boolean): BriefRow {
  if (canApprove) return { id: "readiness", tone: "success", labelKey: "brief_readiness", valueKey: "brief_ready" }
  const state = payload.job.pr_checks?.state
  if (state === "failing") return { id: "readiness", tone: "danger", labelKey: "brief_readiness", valueKey: "brief_blocked_checks_failing" }
  if (state === "pending") return { id: "readiness", tone: "warning", labelKey: "brief_readiness", valueKey: "brief_blocked_checks_pending" }
  if (dependencyBlocked || (payload.unsatisfied_dependencies?.length ?? 0) > 0)
    return { id: "readiness", tone: "warning", labelKey: "brief_readiness", valueKey: "brief_blocked_dependencies" }
  return { id: "readiness", tone: "warning", labelKey: "brief_readiness", valueKey: "brief_blocked_generic" }
}

function checksRow(payload: JobDetailPayload): BriefRow | null {
  const checks = payload.job.pr_checks
  if (!checks) return null
  const known: Record<string, { tone: BriefTone; valueKey: string }> = {
    passing: { tone: "success", valueKey: "brief_checks_passing" },
    pending: { tone: "warning", valueKey: "brief_checks_pending" },
    failing: { tone: "danger", valueKey: "brief_checks_failing" }
  }
  const entry = known[checks.state] ?? { tone: "neutral" as BriefTone, valueKey: "brief_checks_unknown" }
  if (checks.state === "failing" && checks.attribution && ["inherited", "own"].includes(checks.attribution.verdict)) {
    const names = (checks.attribution.verdict === "own" ? checks.attribution.own_names : checks.attribution.failing_names) ?? []
    return {
      id: "checks",
      tone: entry.tone,
      labelKey: "brief_checks",
      valueKey: checks.attribution.verdict === "own" ? "brief_checks_failing_own" : "brief_checks_failing_inherited",
      values: { names: names.join(", ") }
    }
  }
  return { id: "checks", tone: entry.tone, labelKey: "brief_checks", valueKey: entry.valueKey }
}

function reviewRows(workflows: JobWorkflow[]): BriefRow[] {
  const rows: BriefRow[] = []
  for (const kind of REVIEW_KINDS) {
    const iteration = latestIteration(workflows, kind.artifact)
    if (!iteration) continue
    const nonBlocking = iteration.non_blocking_findings?.length ?? 0
    if (iteration.verdict === "needs_work") rows.push({ id: kind.id, tone: "danger", labelKey: kind.labelKey, valueKey: "brief_review_blocking" })
    else if (iteration.verdict === "approved" && nonBlocking > 0)
      rows.push({ id: kind.id, tone: "warning", labelKey: kind.labelKey, valueKey: "brief_review_non_blocking", values: { count: nonBlocking } })
    else if (iteration.verdict === "approved") rows.push({ id: kind.id, tone: "success", labelKey: kind.labelKey, valueKey: "brief_review_clear" })
    else if (iteration.verdict === "skipped") rows.push({ id: kind.id, tone: "neutral", labelKey: kind.labelKey, valueKey: "brief_review_skipped" })
  }
  if (rows.length === 0 && workflows.length > 0)
    rows.push({ id: "reviews", tone: "neutral", labelKey: "brief_reviews", valueKey: "brief_reviews_none_recorded" })
  return rows
}

export function buildDecisionBrief({
  canApprove,
  changeScope,
  dependencyBlocked,
  payload,
  screenshotCount
}: {
  canApprove: boolean
  changeScope: ChangeScope | null | undefined
  dependencyBlocked: boolean
  payload: JobDetailPayload
  screenshotCount: number
}): BriefRow[] {
  const rows: BriefRow[] = [readinessRow(payload, canApprove, dependencyBlocked)]
  if (changeScope)
    rows.push({
      id: "scope",
      tone: "neutral",
      labelKey: "brief_scope",
      valueKey: "brief_scope_value",
      values: { files: changeScope.files_changed, additions: changeScope.additions, deletions: changeScope.deletions }
    })
  const checks = checksRow(payload)
  if (checks) rows.push(checks)
  rows.push(...reviewRows(payload.workflows ?? []))
  const steps = payload.test_plan?.steps?.length ?? 0
  if (steps > 0) rows.push({ id: "tests", tone: "neutral", labelKey: "brief_tests", valueKey: "brief_tests_value", values: { count: steps } })
  if (screenshotCount > 0)
    rows.push({ id: "visual", tone: "neutral", labelKey: "brief_visual", valueKey: "brief_visual_value", values: { count: screenshotCount } })
  if (payload.epic)
    rows.push({
      id: "epic",
      tone: "neutral",
      labelKey: "brief_epic",
      valueKey: "brief_epic_value",
      values: { number: payload.epic.display_number, title: payload.epic.title }
    })
  const unsatisfied = payload.unsatisfied_dependencies?.length ?? 0
  if (unsatisfied > 0 && !rows.some((row) => row.valueKey === "brief_blocked_dependencies"))
    rows.push({ id: "dependencies", tone: "warning", labelKey: "brief_dependencies", valueKey: "brief_dependencies_value", values: { count: unsatisfied } })
  return rows
}
