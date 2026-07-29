import type { JobRun, JobStep } from "../../api/jobs"
import type { useT } from "../../hooks/useT"

// Pure step/run/grade model extracted from JobDetail.tsx: grouping a Workflow's
// flat Step list into the display tree (unlooped steps, grade groups, loop
// iterations), deriving grade summaries and effective statuses, and the small
// value-coercion helpers the render tree leans on. No JSX and no hooks live here,
// so the workflow/step/run components can import this substrate from a leaf module
// instead of reaching back into the route file.

export type PrepareFailure = {
  command?: string
  workdir?: string
  exit_status?: number | null
  timed_out?: boolean
  stopped?: boolean
  operator_killed?: boolean
  aliveness_failed?: boolean
  duration_s?: number | null
  output_tail?: string | null
  // Set when the failed command was auto-detected (guessed) rather than
  // from .syrus.yml. Syrus skips it and runs the agent anyway.
  soft?: boolean
}

export type GradeSummary = {
  name: string
  status: "passed" | "failed" | "error" | "running" | "queued" | "cancelled" | "unknown"
  required: boolean | null
  exitCode: number | null
  duration: number | null
  logBytes: number | null
}

export type WorkflowStepItem =
  | DisplayStepItem
  | LoopStepItem

export type DisplayStepItem =
  | { type: "step"; step: JobStep }
  | GradeStepItem

export type GradeStepItem = {
  type: "grade"
  key: string
  steps: JobStep[]
  graders: JobStep[]
  preflight: boolean
}

export type LoopStepItem = {
  type: "loop"
  loopId: string
  iterations: Array<{ iteration: number; steps: JobStep[]; items: DisplayStepItem[] }>
}

export function workflowStepItems(steps: JobStep[]): WorkflowStepItem[] {
  const items: WorkflowStepItem[] = []
  const consumedLoopIds = new Set<string>()

  for (let index = 0; index < steps.length;) {
    const step = steps[index]
    if (!step.loop_id) {
      const unloopedSteps: JobStep[] = []
      while (index < steps.length && !steps[index].loop_id) {
        unloopedSteps.push(steps[index])
        index += 1
      }
      items.push(...displayStepItems(unloopedSteps))
      continue
    }

    index += 1
    if (consumedLoopIds.has(step.loop_id)) continue
    consumedLoopIds.add(step.loop_id)

    const loopSteps = steps.filter((candidate) => candidate.loop_id === step.loop_id)
    const iterations = loopIterations(loopSteps)
    if (iterations.length <= 1) {
      items.push(...displayStepItems(loopSteps))
      continue
    }

    items.push({ type: "loop", loopId: step.loop_id, iterations })
  }

  return items
}

export function displayStepItems(steps: JobStep[]): DisplayStepItem[] {
  const items: DisplayStepItem[] = []
  const sortedSteps = [...steps].sort((left, right) => left.position - right.position)

  for (let index = 0; index < sortedSteps.length;) {
    const step = sortedSteps[index]
    if (!isGradeDisplayStep(step)) {
      items.push({ type: "step", step })
      index += 1
      continue
    }

    const gradeSteps: JobStep[] = []
    while (index < sortedSteps.length && isGradeDisplayStep(sortedSteps[index])) {
      gradeSteps.push(sortedSteps[index])
      index += 1
    }
    items.push({
      type: "grade",
      key: `grade-${gradeSteps.map((gradeStep) => gradeStep.id).join("-")}`,
      steps: gradeSteps,
      graders: gradeSteps.filter((gradeStep) => gradeStep.kind === "grader" || gradeStep.kind === "grade" || gradeStep.kind === "preflight_grader"),
      preflight: gradeSteps.some((gradeStep) => gradeStep.kind === "preflight_grader_fanout" || gradeStep.kind === "preflight_grader" || gradeStep.kind === "preflight_grader_collect")
    })
  }

  return items
}

export function loopIterations(steps: JobStep[]) {
  const groups = new Map<number, JobStep[]>()
  steps.forEach((step) => {
    const iteration = step.iteration ?? 1
    groups.set(iteration, [...(groups.get(iteration) ?? []), step])
  })

  return Array.from(groups.entries())
    .sort(([left], [right]) => left - right)
    .map(([iteration, iterationSteps]) => ({
      iteration,
      steps: iterationSteps.sort((left, right) => left.position - right.position),
      items: displayStepItems(iterationSteps)
    }))
}

export function isGradeDisplayStep(step: JobStep) {
  return step.kind === "grader_fanout" || step.kind === "grader" || step.kind === "grader_collect" || step.kind === "grade"
    || step.kind === "preflight_grader_fanout" || step.kind === "preflight_grader" || step.kind === "preflight_grader_collect"
}

export function displayStepItemKey(item: DisplayStepItem) {
  return item.type === "grade" ? item.key : `step-${item.step.id}`
}

export function gradePhases(item: GradeStepItem, t: ReturnType<typeof useT>["t"]) {
  return item.steps.map((step) => {
    if (step.kind === "grader_fanout" || step.kind === "preflight_grader_fanout") return { step, displayName: t("grade_setup"), metadataLabel: "grade setup" }
    if (step.kind === "grader_collect" || step.kind === "preflight_grader_collect") return { step, displayName: t("grade_result"), metadataLabel: "grade result" }
    if (step.kind === "grade") return { step, displayName: step.display_name || t("grade_label"), metadataLabel: "grade" }
    if (step.kind === "preflight_grader") return { step, displayName: stringValue(objectDetails(step.details).name) || step.display_name, metadataLabel: "grader" }
    return { step, displayName: step.display_name, metadataLabel: "grader" }
  })
}

export function gradeDisplayStatus(item: GradeStepItem) {
  const statuses = item.steps.map((step) => effectiveStepStatus(step)).filter((status): status is string => Boolean(status))
  if (statuses.includes("running")) return "running"
  if (statuses.includes("queued")) return "queued"
  if (statuses.includes("failed")) return "failed"
  if (statuses.includes("cancelled")) return "cancelled"
  if (item.steps.length > 0 && item.steps.every((step) => effectiveStepStatus(step) === "succeeded")) return "succeeded"
  return null
}

export function gradeSummaries(item: GradeStepItem): GradeSummary[] {
  return item.graders.map((step) => {
    const details = objectDetails(step.details)
    const status = gradeSummaryStatus(step, details)
    return {
      name: stringValue(details.name) || step.display_name || "grader",
      status,
      required: booleanValue(details.required),
      exitCode: numberValue(details.exit_code),
      duration: numberValue(details.duration_s),
      logBytes: numberValue(details.log_bytes)
    }
  })
}

export function gradeSummaryStatus(step: JobStep, details: Record<string, unknown>): GradeSummary["status"] {
  const status = stringValue(details.status)
  if (status === "passed" || status === "failed" || status === "error" || status === "cancelled") return status
  if (step.state === "succeeded") return "passed"
  if (step.state === "failed") return numberValue(details.exit_code) === null ? "error" : "failed"
  if (step.state === "running") return "running"
  if (step.state === "queued") return "queued"
  if (step.state === "cancelled") return "cancelled"
  return "unknown"
}

export function gradeSummaryCounts(summaries: GradeSummary[]) {
  return summaries.reduce((counts, summary) => {
    if (summary.status === "passed") counts.passed += 1
    else if (summary.status === "failed") counts.failed += 1
    else if (summary.status === "error") counts.error += 1
    return counts
  }, { passed: 0, failed: 0, error: 0 })
}

export function loopDisplayName(item: LoopStepItem, t: ReturnType<typeof useT>["t"]) {
  const kinds = item.iterations.flatMap((iteration) => iteration.steps.map((step) => step.kind))
  if (kinds.some((kind) => kind === "grade" || kind === "grader" || kind.startsWith("grader_"))) return t("loop_grade_name")
  return t("loop_name")
}

export function loopDisplayStatus(item: LoopStepItem) {
  const latestIteration = item.iterations[item.iterations.length - 1]
  if (!latestIteration) return null

  const statuses = latestIteration.steps.map((step) => effectiveLoopStepStatus(step))
  if (statuses.includes("running")) return "running"
  if (statuses.includes("queued")) return "queued"
  if (statuses.includes("failed")) return "failed"
  if (statuses.includes("cancelled")) return "cancelled"
  if (statuses.length > 0 && statuses.every((status) => status === "succeeded")) return "succeeded"
  return null
}

export function effectiveStepStatus(step: JobStep) {
  const activeRun = sortedRunsNewestFirst(step.runs).find((run) => isActiveState(run.state))
  return activeRun?.state ?? step.display_status
}

export function effectiveLoopStepStatus(step: JobStep) {
  return effectiveStepStatus(step) ?? step.state
}

export function sortedRunsNewestFirst(runs: JobRun[]) {
  return [...runs].sort((left, right) => {
    const leftTime = runSortTime(left)
    const rightTime = runSortTime(right)
    if (leftTime !== rightTime) return rightTime - leftTime
    return right.id - left.id
  })
}

export function runSortTime(run: JobRun) {
  return new Date(run.started_at || run.created_at || run.updated_at || 0).getTime()
}

export function isActiveState(state: string) {
  return state === "queued" || state === "running"
}

export function formatElapsed(seconds: number) {
  const total = Math.max(0, Math.floor(seconds))
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  if (minutes < 60) return `${minutes}m ${total % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

export function prepareFailureDetails(step: JobStep): PrepareFailure | null {
  if (step.kind !== "prepare" || !isRecord(step.details)) return null
  const failure = step.details.prepare_failure
  return isRecord(failure) ? failure as PrepareFailure : null
}

export function prepareFailureStatus(failure: PrepareFailure, t: ReturnType<typeof useT>["t"]) {
  if (failure.timed_out) return t("prepare_failure_timed_out")
  if (failure.operator_killed) return t("prepare_failure_operator_killed")
  if (failure.stopped) return t("prepare_failure_stopped")
  if (failure.aliveness_failed) return t("prepare_failure_aliveness_failed")
  if (failure.exit_status != null) return t("prepare_failure_exit", { code: failure.exit_status })
  return t("prepare_failure_failed")
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

export function stringify(value: unknown) {
  return typeof value === "string" ? value : JSON.stringify(value, null, 2)
}

export function humanize(value: string) {
  return value.replaceAll("_", " ")
}

export function objectDetails(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}

export function stringValue(value: unknown) {
  return typeof value === "string" ? value : null
}

export function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

export function booleanValue(value: unknown) {
  return typeof value === "boolean" ? value : null
}
