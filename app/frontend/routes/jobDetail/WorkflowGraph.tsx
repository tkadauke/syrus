import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { createTerminalSession } from "../../api/terminal"
import { AnsiText } from "../../components/AnsiText"
import { CloseIcon } from "../../components/CloseIcon"
import { StatusPill } from "../../components/StatusPill"
import { Markdown } from "../../lib/Markdown"
import { workflowSlug } from "../../lib/slugs"
import { buttonClass } from "../../lib/buttonClasses"
import { fetchJobGradeLog, fetchJobRunArtifacts, type JobAdversarialReviewIteration, type JobDetailPayload, type JobRun, type JobStep, type JobWorkflow } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { CommandButton, useJobCommand } from "./command"
import { booleanValue, displayStepItemKey, gradeDisplayStatus, gradePhases, gradeSummaries, gradeSummaryCounts, humanize, isActiveState, loopDisplayName, loopDisplayStatus, objectDetails, prepareFailureDetails, prepareFailureStatus, sortedRunsNewestFirst, stringify, stringValue, workflowStepItems, type DisplayStepItem, type GradeStepItem, type GradeSummary, type LoopStepItem, type PrepareFailure } from "./stepModel"
import { AgentDiff, ActiveRunBanner, PanelMessage, RunTranscriptLogs, SmallPill } from "./components"
import { artifactPanelClass, disabledPaginationClass, formatCurrency, formatDuration, paginationLinkClass, shortSha, withRoutePrefix } from "./formatting"
import { stepArtifactAdversarialReview, stepArtifactTestPlan } from "./stepArtifacts"
import type { BranchDivergence } from "./branchDivergence"
import { workflowBranchDivergence } from "./branchDivergence"


// Workflow / step / run execution-graph rendering extracted from JobDetail.tsx.
//
// The WorkflowsTab entry point and its whole subtree (workflow cards, loop/grade
// groups, step and run rows, and the artifact/grade-log panels). Depends only on
// leaf modules (command spine, step/grade model, format helpers, shared
// micro-components) and shared UI imports, so it carries no circular edge back to
// the route file. Unused header imports were trimmed after the move.

export function WorkflowsTab({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  if (payload.workflows.length === 0) return <PanelMessage>{t("section_no_workflows")}</PanelMessage>

  return (
    <div className="space-y-4">
      <WorkflowsPagination payload={payload} prefix={prefix} />
      {payload.workflows.map((workflow) => <WorkflowCard command={command} key={workflow.id} payload={payload} prefix={prefix} workflow={workflow} />)}
      <WorkflowsPagination payload={payload} prefix={prefix} />
    </div>
  )
}

function WorkflowsPagination({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const pagination = payload.workflows_pagination
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label={t("aria_workflow_pagination")} className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>{t("workflows_showing", { first: pagination.first_item, last: pagination.last_item, total: pagination.total_workflows })}</span>
      <div className="flex gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("workflows_previous")}</Link> : <span className={disabledPaginationClass()}>{t("workflows_previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("workflows_next")}</Link> : <span className={disabledPaginationClass()}>{t("workflows_next")}</span>}
      </div>
    </nav>
  )
}

function WorkflowCard({ workflow, payload, command, prefix }: { workflow: JobWorkflow; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const { t } = useT("jobs")
  const stepItems = workflowStepItems(workflow.steps)
  const branchDivergence = workflowBranchDivergence(workflow)
  const navigate = useNavigate()
  const [terminalOpening, setTerminalOpening] = useState(false)

  async function openTerminal() {
    setTerminalOpening(true)
    try {
      const { session } = await createTerminalSession({
        workflow_id: workflow.id,
        name: `${workflow.slug || workflowSlug(workflow.id)} workspace`
      })
      setTerminalOpening(false)
      navigate(`${prefix}/terminal?session=${session.id}`)
    } catch (error) {
      setTerminalOpening(false)
      throw error
    }
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" id={`workflow-${workflow.id}`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            <Link className="hover:underline" to={withRoutePrefix(workflow.path, prefix)}>{workflow.slug || workflowSlug(workflow.id)}</Link>
          </h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">{workflow.trigger_kind} · {workflow.agent_provider || t("workflow_default_agent")} · {t("workflow_created")} <RelativeTimestamp value={workflow.created_at} /></p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {workflow.state === "running" ? null : <StatusPill state={workflow.state} />}
          {payload.feature_flags?.terminal ? (
            <button className={buttonClass("secondary")} disabled={terminalOpening} onClick={openTerminal} type="button">
              {t("open_terminal_in_workspace")}
            </button>
          ) : null}
          {workflow.retry_available ? <CommandButton command={command} input={{ method: "post", path: workflow.app_retry_step_path }} tone="secondary">{t("retry_failed_step")}</CommandButton> : null}
          {workflow.state === "failed" && !workflow.cleaned_up_at ? <CommandButton command={command} input={{ method: "post", path: workflow.app_push_commits_path }} tone="secondary">{t("push_commits")}</CommandButton> : null}
        </div>
      </div>
      {branchDivergence ? <BranchDivergencePanel command={command} divergence={branchDivergence} payload={payload} prefix={prefix} workflow={workflow} /> : null}
      <div className="mt-4 overflow-hidden rounded border border-gray-200 dark:border-gray-700">
        {stepItems.map((item, index) => item.type === "loop" ? (
          <LoopGroup command={command} item={item} key={item.loopId} payload={payload} workflowArtifacts={workflow.artifacts} />
        ) : (
          <DisplayStepCard command={command} item={item} key={displayStepItemKey(item)} numberLabel={index + 1} payload={payload} workflowArtifacts={workflow.artifacts} />
        ))}
      </div>
    </section>
  )
}

function BranchDivergencePanel({
  divergence,
  workflow,
  payload,
  command,
  prefix
}: {
  divergence: BranchDivergence
  workflow: JobWorkflow
  payload: JobDetailPayload
  command: ReturnType<typeof useJobCommand>
  prefix: string
}) {
  const { t } = useT("jobs")
  const sourcePath = withRoutePrefix(`/jobs/${payload.job.id}/source`, prefix)
  const branch = divergence.branch || t("workflow_pr_branch_fallback")

  return (
    <div className="mt-4 rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950 dark:border-amber-900/60 dark:bg-amber-950/30 dark:text-amber-100">
      <div className="font-semibold">{t("workflow_divergence_title")}</div>
      <p className="mt-1 text-amber-900 dark:text-amber-200">
        {t("workflow_divergence_review")}
      </p>
      <dl className="mt-2 grid gap-1 text-xs text-amber-900 dark:text-amber-200 sm:grid-cols-3">
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_branch")}</dt><dd className="font-mono">{branch}</dd></div>
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_remote")}</dt><dd className="font-mono">{shortSha(divergence.remote_sha)}</dd></div>
        <div><dt className="font-semibold uppercase tracking-wide">{t("workflow_divergence_local")}</dt><dd className="font-mono">{shortSha(divergence.local_sha)}</dd></div>
      </dl>
      {divergence.recovery_pending ? (
        <p className="mt-2 text-xs font-medium text-blue-700 dark:text-blue-300">{t("workflow_replace_pending")}</p>
      ) : null}
      {divergence.recovery_error?.message ? (
        <p className="mt-2 text-xs font-medium text-red-700 dark:text-red-300">{t("workflow_replace_failed", { message: divergence.recovery_error.message })}</p>
      ) : null}
      <div className="mt-3 flex flex-wrap gap-2">
        <Link className={buttonClass("secondary")} to={sourcePath}>{t("workflow_open_source")}</Link>
        <CommandButton command={command} input={{ method: "post", path: payload.paths.app_run_again_path }} tone="secondary">
          {t("workflow_retry_from_pr")}
        </CommandButton>
        {divergence.recovery_pending ? (
          <button className={buttonClass("secondary")} disabled type="button">{t("workflow_replace_queued")}</button>
        ) : (
          <CommandButton command={command} input={{ method: "post", path: workflow.app_force_push_branch_path, confirm: t("workflow_replace_confirm", { branch }) }} tone="danger">
            {t("workflow_replace_pr_branch")}
          </CommandButton>
        )}
        <CommandButton command={command} input={{ method: "post", path: workflow.app_discard_branch_output_path }} tone="secondary">
          {t("workflow_discard_stale")}
        </CommandButton>
      </div>
    </div>
  )
}

function LoopGroup({ item, payload, command, workflowArtifacts }: { item: LoopStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; workflowArtifacts?: Record<string, unknown> | null }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const status = loopDisplayStatus(item)

  return (
    <section className="border-b border-gray-200 last:border-b-0 dark:border-gray-700">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 bg-violet-50 px-3 py-2 text-left hover:bg-violet-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:bg-violet-950/30 dark:hover:bg-violet-950/50"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="font-medium text-gray-900 dark:text-gray-100">{loopDisplayName(item, t)}</span>
          <SmallPill>{t("loop_iteration_count", { count: item.iterations.length })}</SmallPill>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {status ? <StatusPill state={status} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="space-y-3 border-t border-violet-100 bg-white p-3 dark:border-violet-900/60 dark:bg-gray-950">
          {item.iterations.map((iteration) => (
            <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700" key={iteration.iteration}>
              <div className="border-b border-gray-200 bg-gray-50 px-3 py-2 text-xs font-semibold uppercase text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400">
                {t("loop_iteration", { n: iteration.iteration })}
              </div>
              {iteration.items.map((stepItem, index) => (
                <DisplayStepCard command={command} item={stepItem} key={displayStepItemKey(stepItem)} numberLabel={index + 1} payload={payload} workflowArtifacts={workflowArtifacts} />
              ))}
            </section>
          ))}
        </div>
      ) : null}
    </section>
  )
}

function DisplayStepCard({ item, payload, command, numberLabel, workflowArtifacts }: { item: DisplayStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string; workflowArtifacts?: Record<string, unknown> | null }) {
  if (item.type === "grade") return <GradeGroup command={command} item={item} numberLabel={numberLabel} payload={payload} workflowArtifacts={workflowArtifacts} />

  return <StepCard command={command} numberLabel={numberLabel} payload={payload} step={item.step} workflowArtifacts={workflowArtifacts} />
}

function GradeGroup({ item, payload, command, numberLabel, workflowArtifacts }: { item: GradeStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string; workflowArtifacts?: Record<string, unknown> | null }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const status = gradeDisplayStatus(item)
  const phases = gradePhases(item, t)
  const summaries = gradeSummaries(item)

  return (
    <div className="border-b border-gray-200 bg-white last:border-b-0 dark:border-gray-700 dark:bg-gray-900">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 bg-violet-50/50 px-3 py-2 text-left hover:bg-violet-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:bg-violet-950/20 dark:hover:bg-violet-950/40"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="w-6 shrink-0 text-right font-mono text-xs text-gray-400 dark:text-gray-500">{numberLabel}.</span>
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{t("grade_label")}</span>
          {item.graders.length > 0 ? <SmallPill>{t("grade_check_count", { count: item.graders.length })}</SmallPill> : null}
          {summaries.length > 0 ? <GradeSummaryPills summaries={summaries} /> : null}
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {status ? <StatusPill state={status} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="border-t border-violet-100 bg-violet-50/20 p-3 dark:border-violet-900/60 dark:bg-violet-950/10">
          <div className="overflow-hidden rounded border border-violet-100 bg-white dark:border-gray-700 dark:bg-gray-900">
            {phases.map((phase, index) => (
              <StepCard
                command={command}
                displayName={phase.displayName}
                key={phase.step.id}
                metadataLabel={phase.metadataLabel}
                numberLabel={index + 1}
                payload={payload}
                step={phase.step}
                workflowArtifacts={workflowArtifacts}
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

function GradeSummaryPills({ summaries }: { summaries: GradeSummary[] }) {
  const { t } = useT("jobs")
  const counts = gradeSummaryCounts(summaries)
  return (
    <span className="hidden items-center gap-1 sm:inline-flex">
      {counts.passed > 0 ? <SmallPill>{t("grade_passed", { count: counts.passed })}</SmallPill> : null}
      {counts.failed > 0 ? <SmallPill>{t("grade_failed", { count: counts.failed })}</SmallPill> : null}
      {counts.error > 0 ? <SmallPill>{t("grade_error", { count: counts.error })}</SmallPill> : null}
    </span>
  )
}

const GRADER_DESCRIPTION_LIMIT = 220

// Compact, human-friendly view of a grader Step's details: whether it's
// required, its description (collapsed with "Read more" when long), and the
// command. The raw fields (output, log_path, exit_code, duration_s,
// log_bytes, timeout_minutes) are intentionally hidden — the grade log
// button on the run exposes the output.
function GraderDetails({ details }: { details: Record<string, unknown> }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const description = (stringValue(details.description) || "").replace(/\s+/g, " ").trim()
  const command = (stringValue(details.command) || "").trim()
  const required = booleanValue(details.required)
  const isLong = description.length > GRADER_DESCRIPTION_LIMIT
  const shownDescription = expanded || !isLong ? description : `${description.slice(0, GRADER_DESCRIPTION_LIMIT).trimEnd()}…`

  return (
    <div className="mt-2 space-y-2 text-xs">
      <SmallPill>{required === false ? t("grader_optional") : t("grader_required")}</SmallPill>
      {description ? (
        <p className="text-gray-700 dark:text-gray-300">
          {shownDescription}
          {isLong ? (
            <button
              className="ml-1 font-medium text-blue-600 hover:text-blue-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
              onClick={() => setExpanded((current) => !current)}
              type="button"
            >
              {expanded ? t("grader_read_less") : t("grader_read_more")}
            </button>
          ) : null}
        </p>
      ) : (
        <p className="italic text-gray-400 dark:text-gray-500">{t("grader_no_description")}</p>
      )}
      {command ? (
        <div>
          <div className="mb-1 font-medium uppercase tracking-wide text-gray-400 dark:text-gray-500">{t("grader_command_label")}</div>
          <pre className="overflow-x-auto rounded bg-white p-2 font-mono text-[11px] text-gray-700 dark:bg-gray-950 dark:text-gray-300">{command}</pre>
        </div>
      ) : null}
    </div>
  )
}

function StepCard({ step, payload, command, numberLabel, displayName, metadataLabel, workflowArtifacts }: { step: JobStep; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string; displayName?: string; metadataLabel?: string; workflowArtifacts?: Record<string, unknown> | null }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)
  const runs = sortedRunsNewestFirst(step.runs)
  const activeRun = runs.find((run) => isActiveState(run.state))
  const displayStatus = activeRun ? activeRun.state : step.display_status
  const prepareFailure = prepareFailureDetails(step)

  const artifacts = workflowArtifacts ?? {}
  const summaryArtifact = (step.kind === "summarize" || step.kind === "summarize_amend")
    ? (typeof artifacts.summary === "string" && artifacts.summary ? artifacts.summary : null)
    : null
  const testPlanArtifact = step.kind === "test_plan" ? stepArtifactTestPlan(artifacts.test_plan) : null
  const adversarialReviewArtifact = step.kind === "adversarial_review" ? stepArtifactAdversarialReview(artifacts.adversarial_review_iterations) : null

  return (
    <div className="border-b border-gray-200 bg-white last:border-b-0 dark:border-gray-700 dark:bg-gray-900">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-gray-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 dark:hover:bg-gray-800"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="w-6 shrink-0 text-right font-mono text-xs text-gray-400 dark:text-gray-500">{numberLabel}.</span>
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{displayName || step.display_name}</span>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {displayStatus ? <StatusPill state={displayStatus} /> : null}
          <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="border-t border-gray-100 bg-gray-50 p-3 dark:border-gray-800 dark:bg-gray-950">
          <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            <span>{metadataLabel || step.kind}</span>
            {step.loop_id ? <span>{t("step_metadata_iteration", { n: step.iteration ?? 1 })}</span> : null}
            {activeRun && step.state !== activeRun.state ? <SmallPill>{t("step_state_display", { state: step.state.replaceAll("_", " ") })}</SmallPill> : null}
            {step.latest ? <SmallPill>{t("step_latest")}</SmallPill> : null}
            <span><RelativeTimestamp value={step.started_at || step.created_at} /></span>
            {step.finished_at ? <span>{formatDuration(step.started_at, step.finished_at)}</span> : null}
          </div>
          {activeRun ? <ActiveRunBanner run={activeRun} /> : null}
          {prepareFailure ? <PrepareFailurePanel failure={prepareFailure} /> : null}
          {step.details && !prepareFailure ? (
            step.kind === "grader"
              ? <GraderDetails details={objectDetails(step.details)} />
              : <pre className="mt-2 overflow-x-auto rounded bg-white p-2 text-xs text-gray-600 dark:bg-gray-900 dark:text-gray-300">{stringify(step.details)}</pre>
          ) : null}
          {runs.length > 0 ? (
            <div className="mt-3 space-y-2">
              {runs.map((run, idx) => (
                <RunRow
                  active={activeRun?.id === run.id}
                  command={command}
                  key={run.id}
                  payload={payload}
                  run={run}
                  stepAdversarialReviewArtifact={idx === 0 ? adversarialReviewArtifact : null}
                  stepSummaryArtifact={idx === 0 ? summaryArtifact : null}
                  stepTestPlanArtifact={idx === 0 ? testPlanArtifact : null}
                />
              ))}
            </div>
          ) : <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">{t("section_no_runs")}</p>}
        </div>
      ) : null}
    </div>
  )
}

function StepSummaryPanel({ summary, onClose }: { summary: string; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_summary")}</ArtifactPanelHeader>
      <div className="overflow-auto p-3 max-md:min-h-0 max-md:flex-1">
        <Markdown className="chat-prose text-sm text-gray-700 dark:text-gray-300" text={summary} />
      </div>
    </section>
  )
}

function StepTestPlanPanel({ testPlan, onClose }: { testPlan: { steps: string[]; notes: string | null }; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_test_plan")}</ArtifactPanelHeader>
      <div className="overflow-auto p-3 max-md:min-h-0 max-md:flex-1">
        {testPlan.steps.length > 0 ? (
          <ol className="list-decimal space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-300">
            {testPlan.steps.map((step, index) => <li key={`${index}-${step}`}>{step}</li>)}
          </ol>
        ) : null}
        {testPlan.notes ? <Markdown className="chat-prose mt-3 text-sm text-gray-700 dark:text-gray-300" text={testPlan.notes} /> : null}
      </div>
    </section>
  )
}

export function StepAdversarialReviewPanel({ iterations, onClose }: { iterations: JobAdversarialReviewIteration[]; onClose: () => void }) {
  const { t } = useT("jobs")
  const lastIndex = iterations.length - 1
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_adversarial_review")}</ArtifactPanelHeader>
      <div className="divide-y divide-gray-200 overflow-auto max-md:min-h-0 max-md:flex-1 dark:divide-gray-700">
        {iterations.map((iteration, index) => {
          const isFinal = index === lastIndex
          const isApproved = iteration.verdict === "approved"
          const verdictLabel = isApproved ? t("adversarial_review_verdict_approved") : t("adversarial_review_verdict_needs_work")
          return (
            <div className="p-3" key={iteration.iteration}>
              <div className="flex items-center gap-2">
                <h5 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                  {t("adversarial_review_round", { n: iteration.iteration })}
                </h5>
                {isFinal ? (
                  <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-semibold ${isApproved ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/50 dark:text-emerald-300" : "bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-300"}`}>
                    {verdictLabel}
                  </span>
                ) : (
                  <span className="inline-flex items-center rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">
                    {verdictLabel}
                  </span>
                )}
              </div>
              <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={iteration.critique} />
            </div>
          )
        })}
      </div>
    </section>
  )
}

function PrepareFailurePanel({ failure }: { failure: PrepareFailure }) {
  const { t } = useT("jobs")
  const status = prepareFailureStatus(failure, t)

  return (
    <section className="mt-2 rounded border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
      <div className="font-semibold">
        {failure.soft ? t("prepare_failure_soft_title") : t("prepare_failure_hard_title")}
      </div>
      {failure.soft ? (
        <p className="mt-1">
          {t("prepare_failure_soft_body")} <code className="font-mono">{t("prepare_failure_soft_syrus_yml")}</code> <code className="font-mono">{t("prepare_failure_soft_prepare")}</code> {t("prepare_failure_soft_suffix")}
        </p>
      ) : null}
      <dl className="mt-2 grid gap-x-4 gap-y-1 md:grid-cols-[max-content_1fr]">
        <dt className="font-medium">{t("prepare_failure_command")}</dt>
        <dd className="min-w-0 break-words font-mono">{failure.command || "-"}</dd>
        <dt className="font-medium">{t("prepare_failure_workdir")}</dt>
        <dd className="min-w-0 break-words font-mono">{failure.workdir || "-"}</dd>
        <dt className="font-medium">{t("prepare_failure_status_label")}</dt>
        <dd>{status}</dd>
      </dl>
      {failure.output_tail ? (
        <pre className="mt-3 max-h-64 overflow-auto rounded border border-amber-200 bg-white/70 p-2 font-mono text-[11px] text-amber-950 whitespace-pre-wrap dark:border-amber-800 dark:bg-gray-950 dark:text-amber-100">{failure.output_tail}</pre>
      ) : null}
    </section>
  )
}

function RunRow({ run, payload, command, active = false, stepSummaryArtifact = null, stepTestPlanArtifact = null, stepAdversarialReviewArtifact = null }: { run: JobRun; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; active?: boolean; stepSummaryArtifact?: string | null; stepTestPlanArtifact?: { steps: string[]; notes: string | null } | null; stepAdversarialReviewArtifact?: JobAdversarialReviewIteration[] | null }) {
  const { t } = useT("jobs")
  const [gradeLogOpen, setGradeLogOpen] = useState(false)
  const [artifactView, setArtifactView] = useState<"transcript" | "diff" | "step_diff" | "summary" | "test_plan" | "adversarial_review" | null>(null)
  const isRunArtifactView = artifactView === "transcript" || artifactView === "diff" || artifactView === "step_diff"
  const gradeLog = useMutation({
    mutationFn: (path: string) => fetchJobGradeLog(path),
    onSuccess: () => {
      setArtifactView(null)
      setGradeLogOpen(true)
    }
  })
  const artifacts = useQuery({
    queryKey: ["job_run_artifacts", String(payload.job.id), String(run.id)],
    queryFn: () => fetchJobRunArtifacts(run.app_artifacts_path),
    enabled: isRunArtifactView,
    refetchInterval: artifactView === "transcript" && isActiveState(run.state) ? 2000 : false
  })
  const artifactsLoading = isRunArtifactView && artifacts.isFetching && !artifacts.data

  function showArtifacts(view: "transcript" | "diff" | "step_diff") {
    setGradeLogOpen(false)
    setArtifactView((current) => current === view ? null : view)
  }

  function toggleStepArtifact(view: "summary" | "test_plan" | "adversarial_review") {
    setGradeLogOpen(false)
    setArtifactView((current) => current === view ? null : view)
  }

  function showGradeLog(path: string) {
    setArtifactView(null)
    if (gradeLogOpen) {
      setGradeLogOpen(false)
    } else if (gradeLog.data) {
      setGradeLogOpen(true)
    } else {
      gradeLog.mutate(path)
    }
  }

  return (
    <div className={`rounded border bg-white p-3 text-sm dark:bg-gray-900 ${active ? "border-blue-300 ring-1 ring-blue-100 dark:border-blue-700 dark:ring-blue-900/70" : "border-gray-200 dark:border-gray-700"}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium text-gray-900 dark:text-gray-100">{t("run_number", { id: run.id })}</span>
            <StatusPill state={run.state} />
            {run.rate_limited ? <SmallPill>{t("run_rate_limited")}</SmallPill> : null}
          </div>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {run.agent_provider || t("run_agent_fallback")} · {t("run_turns", { count: run.agent_turns ?? 0 })} · {run.job_log_count} {t("run_log_line", { count: run.job_log_count })} · {formatCurrency(run.cost_usd || 0)}
          </p>
          {run.agent_summary ? <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={run.agent_summary} /> : null}
          {run.health_snapshots.at(-1) ? <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">{t("run_health")} {run.health_snapshots.at(-1)?.health_status || "unknown"} {run.health_snapshots.at(-1)?.hint ? `- ${run.health_snapshots.at(-1)?.hint}` : ""}</p> : null}
          {run.failure_classification ? <p className="mt-1 text-xs text-gray-600 dark:text-gray-300">{t("run_failure_label")} {humanize(run.failure_classification.classification)} · {run.failure_classification.retryable ? t("run_retryable") : t("run_not_retryable")}{run.failure_classification.reason ? ` - ${run.failure_classification.reason}` : ""}</p> : null}
          {run.run_diagnostic?.present ? <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">{t("run_diagnostic_captured")} <RelativeTimestamp value={run.run_diagnostic.created_at} />{run.run_diagnostic.error_message ? `: ${run.run_diagnostic.error_message}` : ""}</p> : null}
        </div>
        <div className="flex flex-wrap justify-end gap-2">
          {run.job_log_count > 0 ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("transcript")} type="button">
              {artifactsLoading && artifactView === "transcript" ? t("run_loading") : t("run_transcript")}
            </button>
          ) : null}
          {stepSummaryArtifact !== null ? (
            <button className={buttonClass("secondary")} onClick={() => toggleStepArtifact("summary")} type="button">
              {t("step_btn_summary")}
            </button>
          ) : null}
          {stepTestPlanArtifact !== null ? (
            <button className={buttonClass("secondary")} onClick={() => toggleStepArtifact("test_plan")} type="button">
              {t("step_btn_test_plan")}
            </button>
          ) : null}
          {stepAdversarialReviewArtifact !== null ? (
            <button className={buttonClass("secondary")} onClick={() => toggleStepArtifact("adversarial_review")} type="button">
              {t("step_btn_adversarial_review")}
            </button>
          ) : null}
          {run.agent_diff_present ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("diff")} type="button">
              {artifactsLoading && artifactView === "diff" ? t("run_loading") : t("run_diff")}
            </button>
          ) : null}
          {run.step_agent_diff_present ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("step_diff")} type="button">
              {artifactsLoading && artifactView === "step_diff" ? t("run_loading") : t("run_step_diff")}
            </button>
          ) : null}
          {run.can_stop ? <CommandButton command={command} input={{ method: "post", path: run.app_stop_path }} tone="danger">{t("run_stop")}</CommandButton> : null}
          {run.can_diagnose ? <CommandButton command={command} input={{ method: "post", path: run.app_diagnose_path }} tone="secondary">{t("run_diagnose")}</CommandButton> : null}
          {run.can_resume ? <CommandButton command={command} input={{ method: "post", path: payload.paths.app_resume_path, body: { source_run_id: run.id } }} tone="secondary">{t("run_resume")}</CommandButton> : null}
          {run.app_grade_log_path ? (
            <button className={buttonClass("secondary")} disabled={gradeLog.isPending} onClick={() => showGradeLog(run.app_grade_log_path!)} type="button">
              {gradeLog.isPending ? t("run_loading_log") : t("run_grade_log")}
            </button>
          ) : null}
        </div>
      </div>
      {artifacts.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(artifacts.error, t("run_artifacts_error"))}</p> : null}
      {isRunArtifactView && artifacts.data ? <RunArtifactsPanel onClose={() => setArtifactView(null)} payload={artifacts.data} view={artifactView as "transcript" | "diff" | "step_diff"} /> : null}
      {artifactView === "summary" && stepSummaryArtifact ? (
        <StepSummaryPanel onClose={() => setArtifactView(null)} summary={stepSummaryArtifact} />
      ) : null}
      {artifactView === "test_plan" && stepTestPlanArtifact ? (
        <StepTestPlanPanel onClose={() => setArtifactView(null)} testPlan={stepTestPlanArtifact} />
      ) : null}
      {artifactView === "adversarial_review" && stepAdversarialReviewArtifact ? (
        <StepAdversarialReviewPanel iterations={stepAdversarialReviewArtifact} onClose={() => setArtifactView(null)} />
      ) : null}
      {gradeLog.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(gradeLog.error, t("run_grade_log_error"))}</p> : null}
      {gradeLogOpen && gradeLog.data ? (
        <RunGradeLogPanel onClose={() => setGradeLogOpen(false)} payload={gradeLog.data} />
      ) : null}
    </div>
  )
}

function RunArtifactsPanel({ payload, view, onClose }: { payload: Awaited<ReturnType<typeof fetchJobRunArtifacts>>; view: "transcript" | "diff" | "step_diff"; onClose: () => void }) {
  const { t } = useT("jobs")
  if (view === "diff") {
    return (
      <section className={artifactPanelClass()}>
        <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_diff")}</ArtifactPanelHeader>
        {payload.agent_diff ? (
          <AgentDiff diff={payload.agent_diff} />
        ) : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("artifact_no_diff")}</p>}
      </section>
    )
  }

  if (view === "step_diff") {
    return (
      <section className={artifactPanelClass()}>
        <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_step_diff")}</ArtifactPanelHeader>
        {payload.step_agent_diff ? (
          <AgentDiff diff={payload.step_agent_diff} />
        ) : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("artifact_no_diff")}</p>}
      </section>
    )
  }

  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{t("artifact_header_transcript")}</ArtifactPanelHeader>
      {payload.logs.length > 0 ? <RunTranscriptLogs logs={payload.logs} /> : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("artifact_no_transcript")}</p>}
    </section>
  )
}

function RunGradeLogPanel({ payload, onClose }: { payload: Awaited<ReturnType<typeof fetchJobGradeLog>>; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{payload.name || t("run_number", { id: payload.run_id })} {t("artifact_grade_log_title")}</ArtifactPanelHeader>
      <pre className="max-h-96 overflow-auto bg-white p-3 font-mono text-xs text-gray-800 whitespace-pre-wrap max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950 dark:text-gray-200" data-testid="run-grade-log-stream"><AnsiText text={payload.contents} /></pre>
    </section>
  )
}

function ArtifactPanelHeader({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <div className="flex shrink-0 items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
      <h4 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{children}</h4>
      <button aria-label={t("artifact_close")} className="hidden rounded p-2 text-gray-500 hover:bg-gray-100 hover:text-gray-700 max-md:block dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
        <CloseIcon className="h-5 w-5" />
      </button>
    </div>
  )
}
