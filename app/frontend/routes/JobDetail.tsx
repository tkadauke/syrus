import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode, UIEvent } from "react"
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { CloseIcon } from "../components/CloseIcon"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill } from "../components/StatusPill"
import { workflowSlug } from "../lib/slugs"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import {
  createJobAttachments,
  deleteJobCommand,
  fetchJobDetail,
  fetchJobGradeLog,
  fetchJobRunArtifacts,
  fetchJobSource,
  fetchJobTimeline,
  patchJobCommand,
  postJobCommand,
  type JobAttachment,
  type JobDependency,
  type JobDetailPayload,
  type JobRun,
  type JobSourcePayload,
  type JobStep,
  type JobWorkflow
} from "../api/jobs"

type JobTab = "summary" | "workflows" | "attachments" | "source"
type JobDetailQueryKey = readonly ["jobs", string, "detail", string]
type CommandInput =
  | { method: "post"; path: string; body?: unknown; confirm?: string }
  | { method: "patch"; path: string; body?: unknown; confirm?: string }
  | { method: "delete"; path: string; confirm?: string }
type ButtonTone = "primary" | "secondary" | "success" | "danger"
type HeaderAction = {
  key: string
  label: string
  input: CommandInput
  tone: ButtonTone
}
type PrepareFailure = {
  command?: string
  workdir?: string
  exit_status?: number | null
  timed_out?: boolean
  stopped?: boolean
  operator_killed?: boolean
  aliveness_failed?: boolean
  duration_s?: number | null
  output_tail?: string | null
}

const RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX = 24

export function JobDetailRoute() {
  const params = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const id = params.id || ""
  const activeTab = tabFromLocation(location.pathname, location.search)
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const detailSearch = jobDetailSearch(location.search)
  const queryKey = jobDetailQueryKey(id, detailSearch)
  const detail = useQuery({
    queryKey,
    queryFn: () => fetchJobDetail(id, detailSearch),
    enabled: id.length > 0
  })

  function selectTab(tab: JobTab) {
    const search = new URLSearchParams(location.search)
    if (tab === "summary") search.delete("tab")
    else search.set("tab", tab)
    if (tab !== "workflows") search.delete("workflows_page")
    const next = search.toString()
    navigate(`${location.pathname}${next ? `?${next}` : ""}`)
  }

  return (
    <main aria-label="Job" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {detail.isPending ? <PanelMessage>Loading Job...</PanelMessage> : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, "Unable to load Job.")}</PanelMessage> : null}
      {detail.isSuccess ? <JobDetailView activeTab={activeTab} onSelectTab={selectTab} payload={detail.data} prefix={prefix} queryKey={queryKey} /> : null}
    </main>
  )
}

function jobDetailQueryKey(id: string | number, search: string): JobDetailQueryKey {
  return ["jobs", String(id), "detail", search] as const
}

function jobDetailSearch(search: string) {
  const current = new URLSearchParams(search)
  const next = new URLSearchParams()
  const workflowsPage = current.get("workflows_page")
  if (workflowsPage) next.set("workflows_page", workflowsPage)
  const value = next.toString()
  return value ? `?${value}` : ""
}

function tabFromLocation(pathname: string, search: string): JobTab {
  if (pathname.endsWith("/source")) return "source"

  const value = new URLSearchParams(search).get("tab")
  return value === "workflows" || value === "attachments" || value === "source" ? value : "summary"
}

function JobDetailView({ payload, queryKey, activeTab, onSelectTab, prefix }: { payload: JobDetailPayload; queryKey: JobDetailQueryKey; activeTab: JobTab; onSelectTab: (tab: JobTab) => void; prefix: string }) {
  const location = useLocation()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const command = useJobCommand(payload.job.id, queryKey, setNotice)
  const title = payload.job.issue_title || jobSourceLabel(payload)
  const workflowAnchor = location.hash.startsWith("#workflow-") ? location.hash.slice(1) : null
  const renderedWorkflowIds = payload.workflows.map((workflow) => workflow.id).join(",")

  useEffect(() => {
    setNotice(payload.message || null)
  }, [payload.job.id, payload.message])

  useEffect(() => {
    if (activeTab !== "workflows" || !workflowAnchor) return undefined

    const frame = window.requestAnimationFrame(() => {
      document.getElementById(workflowAnchor)?.scrollIntoView({ block: "start" })
    })

    return () => window.cancelAnimationFrame(frame)
  }, [activeTab, workflowAnchor, renderedWorkflowIds])

  return (
    <>
      <header className="space-y-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
            <div className="flex flex-wrap items-center gap-2">
              <p className="mt-1 break-words text-sm text-gray-600 dark:text-gray-300">
                <Link className="font-mono hover:underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>{payload.repository.slug}</Link>
                <span className="px-2 text-gray-300 dark:text-gray-600">/</span>
                <JobSourceLink payload={payload} />
              </p>
              <StatusPill state={payload.job.summary_state} />
              {payload.job.agent_provider ? <SmallPill>{payload.job.agent_provider}</SmallPill> : null}
              {payload.job.credential_mode ? <SmallPill>{payload.job.credential_mode}</SmallPill> : null}
            </div>
            <div className="mt-1 flex flex-wrap items-center gap-x-1 gap-y-1 text-sm text-gray-500 dark:text-gray-400">
              <CopyableJobSlug slug={jobSlug(payload.job.id)} />
              <span>· {payload.job.workflows_count} {plural(payload.job.workflows_count, "workflow")} · {payload.job.runs_count} {plural(payload.job.runs_count, "run")}</span>
              {payload.job.total_cost_usd == null ? null : <span>· {formatCurrency(payload.job.total_cost_usd)}</span>}
              {payload.job.prepare_skipped ? <span className="font-medium text-amber-700">· prepare skipped</span> : null}
            </div>
          </div>
          <HeaderActions command={command} payload={payload} />
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Job command failed.")}</PanelMessage> : null}

      <TabNav active={activeTab} attachmentsCount={payload.attachments.length} workflowsCount={payload.job.workflows_count} onSelect={onSelectTab} />

      {activeTab === "summary" ? <SummaryTab command={command} payload={payload} prefix={prefix} /> : null}
      {activeTab === "workflows" ? <WorkflowsTab command={command} payload={payload} prefix={prefix} /> : null}
      {activeTab === "attachments" ? <AttachmentsTab payload={payload} queryKey={queryKey} onNotice={setNotice} /> : null}
      {activeTab === "source" ? <SourceTab jobId={String(payload.job.id)} /> : null}
    </>
  )
}

function useJobCommand(jobId: number, queryKey: JobDetailQueryKey, onNotice: (message: string | null) => void) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()

  return useMutation({
    mutationFn: (input: CommandInput) => {
      if (input.confirm && !window.confirm(input.confirm)) return Promise.resolve({ message: null })
      if (input.method === "delete") return deleteJobCommand(input.path)
      if (input.method === "patch") return patchJobCommand(input.path, input.body)
      return postJobCommand(input.path, input.body)
    },
    onSuccess: (payload) => {
      if (payload.redirect_to) navigate(payload.redirect_to)
      onNotice(payload.message || null)
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId)] })
      void queryClient.invalidateQueries({ queryKey })
    }
  })
}

function HeaderActions({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const [retryFeedbackOpen, setRetryFeedbackOpen] = useState(false)
  const actions = headerActions(payload)
  const visibleKeys = primaryHeaderActionKeys(payload, actions)
  const visibleActions = visibleKeys.map((key) => actions.find((action) => action.key === key)).filter((action): action is HeaderAction => Boolean(action))
  const overflowActions = actions.filter((action) => !visibleKeys.includes(action.key))

  return (
    <>
      <div className="flex flex-wrap items-center justify-end gap-2">
        {visibleActions.map((action) => (
          <CommandButton command={command} input={action.input} key={action.key} tone={action.tone}>{action.label}</CommandButton>
        ))}
        {overflowActions.length > 0 ? <HeaderActionsMenu actions={overflowActions} command={command} onRetryFeedback={() => setRetryFeedbackOpen(true)} /> : null}
      </div>
      {retryFeedbackOpen ? (
        <RetryFeedbackDialog
          command={command}
          onClose={() => setRetryFeedbackOpen(false)}
          path={payload.paths.app_run_again_path}
        />
      ) : null}
    </>
  )
}

function headerActions(payload: JobDetailPayload): HeaderAction[] {
  const actions = payload.actions
  const paths = payload.paths
  const available: HeaderAction[] = []

  if (actions.can_start) available.push({ key: "start", label: "Start Run", input: { method: "post", path: paths.app_start_path }, tone: "primary" })
  if (actions.can_poll_feedback) available.push({ key: "poll_feedback", label: "Check feedback", input: { method: "post", path: paths.app_poll_feedback_path }, tone: "secondary" })
  if (actions.can_rebase) available.push({ key: "rebase", label: "Rebase now", input: { method: "post", path: paths.app_rebase_path }, tone: "secondary" })
  if (actions.can_check_mergeability) available.push({ key: "check_mergeability", label: "Check mergeability", input: { method: "post", path: paths.app_check_mergeability_path }, tone: "secondary" })
  if (actions.can_retry) available.push({ key: "retry", label: "Retry", input: { method: "post", path: paths.app_run_again_path }, tone: "primary" })
  if (actions.can_retry) available.push({ key: "retry_feedback", label: "Retry with feedback", input: { method: "post", path: paths.app_run_again_path }, tone: "secondary" })
  if (actions.can_restart) available.push({ key: "restart", label: "Start over", input: { method: "post", path: paths.app_restart_path, confirm: "Start over with a new Job and abandon this branch?" }, tone: "secondary" })
  if (actions.can_approve) available.push({ key: "approve", label: payload.job.landing_failure_reason ? "Reapprove" : "Approve", input: { method: "post", path: paths.app_approve_path }, tone: "success" })
  if (actions.can_unapprove) available.push({ key: "unapprove", label: "Unapprove", input: { method: "post", path: paths.app_unapprove_path, confirm: "Move this Job back to implemented?" }, tone: "secondary" })
  if (actions.can_claim) available.push({ key: "claim", label: "Claim", input: { method: "post", path: paths.app_claim_path }, tone: "secondary" })
  if (actions.can_unclaim) available.push({ key: "unclaim", label: "Release claim", input: { method: "delete", path: paths.app_claim_path }, tone: "secondary" })
  if (actions.can_cancel) available.push({ key: "cancel", label: "Cancel", input: { method: "post", path: paths.app_cancel_path, confirm: "Cancel any running work and close this Job?" }, tone: "danger" })
  if (actions.can_reopen) available.push({ key: "reopen", label: "Reopen", input: { method: "post", path: paths.app_reopen_path }, tone: "success" })
  if (actions.can_mark_valid) available.push({ key: "mark_valid", label: "Mark valid", input: { method: "post", path: paths.app_mark_valid_path }, tone: "secondary" })
  available.push({ key: "pin", label: payload.pinned ? "Unpin" : "Pin", input: payload.pinned ? { method: "delete", path: paths.app_pin_path } : { method: "post", path: paths.app_pin_path }, tone: "secondary" })

  return available
}

function primaryHeaderActionKeys(payload: JobDetailPayload, actions: HeaderAction[]) {
  const availableKeys = new Set(actions.map((action) => action.key))
  const jobState = payload.job.summary_state.toLowerCase()
  const keys: string[] = []

  function add(key: string) {
    if (availableKeys.has(key) && keys.length < 2) keys.push(key)
  }

  if (payload.job.any_active_run || jobState === "running") {
    add("cancel")
  } else if (availableKeys.has("approve")) {
    add("approve")
    add("retry")
  } else if (jobState === "failed") {
    add("retry")
    add("restart")
  } else if (availableKeys.has("reopen")) {
    add("reopen")
  } else if (availableKeys.has("retry")) {
    add("retry")
  } else {
    add("start")
    add("claim")
    add("unclaim")
    add("mark_valid")
  }

  if (keys.length < 2) {
    add("claim")
    add("unclaim")
  }

  return keys
}

function HeaderActionsMenu({ actions, command, onRetryFeedback }: { actions: HeaderAction[]; command: ReturnType<typeof useJobCommand>; onRetryFeedback: () => void }) {
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        className={buttonClass("secondary")}
        disabled={command.isPending}
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        More
      </button>
      {open ? (
        <div className="absolute right-0 z-20 mt-2 w-56 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900" role="menu">
          {actions.map((action) => (
            <button
              className={menuButtonClass(action.tone)}
              disabled={command.isPending}
              key={action.key}
              onClick={() => {
                setOpen(false)
                if (action.key === "retry_feedback") {
                  onRetryFeedback()
                  return
                }
                command.mutate(action.input)
              }}
              role="menuitem"
              type="button"
            >
              {action.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}

function RetryFeedbackDialog({ command, path, onClose }: { command: ReturnType<typeof useJobCommand>; path: string; onClose: () => void }) {
  const [feedback, setFeedback] = useState("")
  const trimmedFeedback = feedback.trim()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!trimmedFeedback) return

    command.mutate(
      { method: "post", path, body: { retry_context: trimmedFeedback } },
      { onSuccess: onClose }
    )
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-gray-900/40 p-4" role="presentation">
      <section aria-labelledby="retry-feedback-title" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-900" role="dialog" aria-modal="true">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="retry-feedback-title">Retry with feedback</h2>
            <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">This feedback will be added to the retry prompt.</p>
          </div>
          <button
            aria-label="Close retry with feedback"
            className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            disabled={command.isPending}
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <form className="mt-4 space-y-3" onSubmit={submit}>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300" htmlFor="retry-feedback-text">
            Feedback
          </label>
          <textarea
            autoFocus
            className="min-h-36 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            id="retry-feedback-text"
            onChange={(event) => setFeedback(event.target.value)}
            required
            value={feedback}
          />
          <div className="flex flex-wrap justify-end gap-2">
            <button className={buttonClass("secondary")} disabled={command.isPending} onClick={onClose} type="button">Cancel</button>
            <button className={buttonClass("primary")} disabled={command.isPending || !trimmedFeedback} type="submit">
              {command.isPending ? "Retrying..." : "Retry"}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

function CommandButton({ children, command, input, tone = "primary" }: { children: ReactNode; command: ReturnType<typeof useJobCommand>; input: CommandInput; tone?: ButtonTone }) {
  return (
    <button className={buttonClass(tone)} disabled={command.isPending} onClick={() => command.mutate(input)} type="button">
      {children}
    </button>
  )
}

function CopyableJobSlug({ slug }: { slug: string }) {
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return

    const timeout = window.setTimeout(() => setCopied(false), 1500)
    return () => window.clearTimeout(timeout)
  }, [copied])

  async function copySlug() {
    if (!navigator.clipboard?.writeText) return

    try {
      await navigator.clipboard.writeText(slug)
      setCopied(true)
    } catch {
      setCopied(false)
    }
  }

  return (
    <button
      aria-label={`Copy ${slug} to clipboard`}
      className="group inline-flex items-center gap-1 rounded px-1 py-0.5 font-mono text-gray-600 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-gray-100"
      onClick={copySlug}
      title={copied ? "Copied" : `Copy ${slug}`}
      type="button"
    >
      <span>{slug}</span>
      <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-green-600 dark:text-green-300" : "text-gray-400 group-hover:text-gray-600 dark:text-gray-500 dark:group-hover:text-gray-300"}`} />
    </button>
  )
}

function CopyIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" viewBox="0 0 20 20">
      <rect height="11" rx="2" stroke="currentColor" strokeWidth="1.8" width="11" x="6" y="3" />
      <path d="M3 7v8a2 2 0 0 0 2 2h8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function TagsPanel({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const [tagName, setTagName] = useState("")

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    command.mutate({ method: "post", path: payload.paths.app_tags_path, body: { tag_name: tagName } }, { onSuccess: () => setTagName("") })
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Tags</h2>
          {payload.tags.length > 0 ? payload.tags.map((tag) => (
            <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700 dark:bg-gray-800 dark:text-gray-200" key={tag.id}>
              {tag.name}
              <button
                aria-label={`Remove ${tag.name}`}
                className="inline-flex h-4 w-4 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-red-600 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300"
                disabled={command.isPending}
                onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_tags_path}/${tag.id}` })}
                title={`Remove ${tag.name}`}
                type="button"
              >
                <CloseIcon className="h-3 w-3" />
              </button>
            </span>
          )) : <span className="text-sm text-gray-400 dark:text-gray-500">No tags yet.</span>}
        </div>
        <form className="flex items-center gap-2" onSubmit={submit}>
          <input className="w-40 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" list="job-tag-options" onChange={(event) => setTagName(event.target.value)} placeholder="Add tag" required value={tagName} />
          <datalist id="job-tag-options">
            {payload.tag_options.map((tag) => <option key={tag.id} value={tag.name} />)}
          </datalist>
          <button className={buttonClass("secondary")} disabled={command.isPending} type="submit">Add</button>
        </form>
      </div>
    </section>
  )
}

function TabNav({ active, workflowsCount, attachmentsCount, onSelect }: { active: JobTab; workflowsCount: number; attachmentsCount: number; onSelect: (tab: JobTab) => void }) {
  const tabs: Array<{ id: JobTab; label: string }> = [
    { id: "summary", label: "Summary" },
    { id: "workflows", label: `Workflows (${workflowsCount})` },
    { id: "attachments", label: `Attachments (${attachmentsCount})` },
    { id: "source", label: "Source" }
  ]

  return (
    <div className="flex overflow-x-auto border-b border-gray-200 dark:border-gray-700">
      {tabs.map((tab) => (
        <button
          className={`shrink-0 border-b-2 px-4 py-2 text-sm font-medium ${active === tab.id ? "border-blue-600 text-blue-600 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200"}`}
          key={tab.id}
          onClick={() => onSelect(tab.id)}
          type="button"
        >
          {tab.label}
        </button>
      ))}
    </div>
  )
}

function SummaryTab({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  return (
    <div className="space-y-4">
      {payload.landing_queue_entry ? (
        <PanelMessage>
          In landing queue: position #{payload.landing_queue_entry.position}
          {payload.landing_queue_entry.blocked_reason ? ` (${payload.landing_queue_entry.blocked_reason})` : ""}
          {payload.landing_queue_entry.waiting_for_jobs.length > 0 ? (
            <>
              {" "}
              Waiting for: {payload.landing_queue_entry.waiting_for_jobs.map((job, index) => (
                <span key={job.id}>
                  {index > 0 ? ", " : null}
                  <Link className="font-medium text-blue-700 underline hover:no-underline" to={`${prefix}${job.job_path}`}>
                    {job.label} {job.title}
                  </Link>
                </span>
              ))}
            </>
          ) : null}
        </PanelMessage>
      ) : null}
      {payload.job.landing_failure_reason ? <PanelMessage tone="error">Landing failed: {payload.job.landing_failure_reason}</PanelMessage> : null}
      <RetryStatePanel payload={payload} />
      {payload.unsatisfied_dependencies.length > 0 ? <UnsatisfiedDependencies command={command} payload={payload} prefix={prefix} /> : null}

      <section className="grid gap-4 rounded border border-gray-200 bg-white p-4 text-sm sm:grid-cols-2 lg:grid-cols-4 dark:border-gray-700 dark:bg-gray-900">
        <KeyValue label="Owner"><JobOwnerLabel payload={payload} prefix={prefix} /></KeyValue>
        <KeyValue label="Priority"><SmallPill>{payload.job.priority}</SmallPill></KeyValue>
        <KeyValue label="Validity"><span className="capitalize">{payload.job.validity}</span></KeyValue>
        {payload.epic ? <KeyValue label="Epic"><EpicSummaryLink epic={payload.epic} prefix={prefix} /></KeyValue> : null}
        <KeyValue label="Branch"><code className="break-all">{payload.job.branch_name || "-"}</code></KeyValue>
        <KeyValue label="Stack base"><StackBaseForm command={command} payload={payload} /></KeyValue>
        <KeyValue label="Pull request"><PullRequestSummary payload={payload} /></KeyValue>
        <KeyValue label="Cost">{payload.job.total_cost_usd == null ? "-" : formatCurrency(payload.job.total_cost_usd)} <span className="text-xs text-gray-400 dark:text-gray-500">({payload.job.billed_runs_count} billed)</span></KeyValue>
        <KeyValue label="Started">{formatDate(payload.job.started_at)}</KeyValue>
        <KeyValue label="Closed">{payload.job.finished_at ? `${formatDate(payload.job.finished_at)} (${payload.job.closure_reason || "unspecified"})` : "still open"}</KeyValue>
      </section>

      <TagsPanel command={command} payload={payload} />

      <DependenciesPanel command={command} payload={payload} prefix={prefix} />

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Issue</h2>
          {payload.job.issue_body ? <pre className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-600 dark:text-gray-300">{payload.job.issue_body}</pre> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">No issue body.</p>}
        </section>
        <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Agent summary</h2>
          {payload.summary ? <p className="mt-2 whitespace-pre-wrap text-sm text-gray-700 dark:text-gray-300">{payload.summary.text}</p> : <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">No summary yet.</p>}
        </section>
      </div>

      <TimelinePanel canView={payload.actions.can_view_timeline} jobId={payload.job.id} prefix={prefix} />
      <AttachmentPreview attachments={payload.attachments} />
    </div>
  )
}

function EpicSummaryLink({ epic, prefix }: { epic: NonNullable<JobDetailPayload["epic"]>; prefix: string }) {
  return (
    <Link className="text-blue-600 hover:underline" to={withRoutePrefix(epic.epic_path, prefix)}>
      {epic.display_number} {epic.title}
    </Link>
  )
}

function RetryStatePanel({ payload }: { payload: JobDetailPayload }) {
  const retry = payload.job.retry_state
  if (!retry || (retry.state_label === "No failure" && !retry.classification)) return null

  return (
    <section className={`rounded border px-4 py-3 text-sm ${retry.auto_retry_exhausted ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200" : retry.provider_circuit_open ? "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200" : "border-gray-200 bg-white text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"}`}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold">{retry.state_label}</span>
        <SmallPill>{retry.classification_label}</SmallPill>
        <SmallPill>{retry.retryable ? "retryable" : "not retryable"}</SmallPill>
        <SmallPill>{retry.retry_attempt_count}/{retry.retry_budget} attempts</SmallPill>
        <SmallPill>{retry.retry_budget_remaining} remaining</SmallPill>
      </div>
      <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs">
        {retry.next_auto_retry_at ? <span>Next retry {formatDate(retry.next_auto_retry_at)}</span> : null}
        {retry.retry_delayed_until ? <span>Delayed until {formatDate(retry.retry_delayed_until)}</span> : null}
        {retry.retry_delay_reason ? <span>{retry.retry_delay_reason}</span> : null}
      </div>
    </section>
  )
}

function JobOwnerLabel({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const owner = payload.job.claimed_by_user
  if (!owner) return <span className="text-gray-400 dark:text-gray-500">Unclaimed</span>

  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <Link className="font-medium text-blue-700 hover:underline" to={withRoutePrefix(owner.profile_path, prefix)}>
        {payload.job.claimed_by_current_user ? "You" : owner.display_name}
      </Link>
      {payload.job.claimed_at ? <span className="text-xs text-gray-400 dark:text-gray-500">{formatDate(payload.job.claimed_at)}</span> : null}
    </span>
  )
}

function UnsatisfiedDependencies({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  return (
    <section className="rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <span className="font-medium">Waiting on {payload.unsatisfied_dependencies.length} {plural(payload.unsatisfied_dependencies.length, "dependency")}.</span>
          <span className="ml-2 inline-flex flex-wrap gap-x-2 gap-y-1">
            {payload.unsatisfied_dependencies.map((dependency, index) => (
              <span key={dependency.id}>
                {index > 0 ? <span className="mr-2">,</span> : null}
                <DependencyLink dependency={dependency} prefix={prefix} />
              </span>
            ))}
          </span>
        </div>
        {payload.actions.can_override_dependencies ? (
          <CommandButton command={command} input={{ method: "post", path: payload.paths.app_dependency_override_path, confirm: "Bypass dependency checks for this Job?" }} tone="secondary">
            Override and force-run
          </CommandButton>
        ) : null}
      </div>
    </section>
  )
}

function StackBaseForm({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const [stackBase, setStackBase] = useState(payload.job.stack_base)

  useEffect(() => setStackBase(payload.job.stack_base), [payload.job.stack_base])

  return (
    <form className="flex flex-wrap items-center gap-2" onSubmit={(event) => {
      event.preventDefault()
      command.mutate({ method: "patch", path: payload.paths.app_stack_base_path, body: { stack_base: stackBase } })
    }}>
      <select className="rounded border border-gray-300 bg-white px-2 py-1 text-xs text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => setStackBase(event.target.value)} value={stackBase}>
        <option value="auto">auto</option>
        <option value="main">main</option>
      </select>
      <button className="text-xs text-blue-600 hover:underline" disabled={command.isPending} type="submit">Update</button>
    </form>
  )
}

function PullRequestSummary({ payload }: { payload: JobDetailPayload }) {
  if (!payload.job.pr_number && !payload.job.external_pr_number) return <span className="text-gray-400 dark:text-gray-500">-</span>

  return (
    <div className="space-y-1">
      {payload.job.pr_number ? <a className="text-blue-600 hover:underline" href={payload.job.pr_url || "#"} rel="noopener" target="_blank">Syrus PR #{payload.job.pr_number}</a> : null}
      {payload.job.external_pr_number ? <a className="block text-violet-700 hover:underline" href={payload.job.external_pr_url || "#"} rel="noopener" target="_blank">External PR #{payload.job.external_pr_number}</a> : null}
      <div><MergeablePill value={payload.job.pr_mergeable} /> {payload.job.pr_mergeable_checked_at ? <span className="text-xs text-gray-400 dark:text-gray-500">checked {formatDate(payload.job.pr_mergeable_checked_at)}</span> : null}</div>
    </div>
  )
}

function DependenciesPanel({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const [target, setTarget] = useState("")

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    command.mutate({ method: "post", path: payload.paths.app_dependencies_path, body: { dependency_target: target } }, { onSuccess: () => setTarget("") })
  }

  return (
    <section className="grid gap-4 lg:grid-cols-2">
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">Dependencies</h2>
        {payload.dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependencies.map((dependency) => (
              <li className="flex flex-wrap items-center justify-between gap-2 py-2" key={dependency.id}>
                <span><DependencyLink dependency={dependency} prefix={prefix} /> <span className="text-xs text-gray-400 dark:text-gray-500">({dependency.source})</span></span>
                {dependency.manual ? <button className="text-xs text-red-600 hover:underline" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_dependencies_path}/${dependency.id}`, confirm: "Remove this dependency?" })} type="button">Remove</button> : null}
              </li>
            ))}
          </ul>
        ) : <p className="mt-2 text-gray-400 dark:text-gray-500">No dependencies.</p>}
        <form className="mt-3 flex flex-wrap items-end gap-2 border-t border-gray-100 pt-3 dark:border-gray-800" onSubmit={submit}>
          <label className="min-w-0 flex-1 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            Dependency
            <select className="mt-1 w-full min-w-64 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => setTarget(event.target.value)} required value={target}>
              <option value="">Select a Job or issue</option>
              {payload.dependency_target_options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <button className={buttonClass("secondary")} disabled={command.isPending} type="submit">Add</button>
        </form>
      </div>
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{payload.dependents.length} other {plural(payload.dependents.length, "Job")} depend on this one</h2>
        {payload.dependents.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {payload.dependents.map((dependent) => (
              <li className="flex flex-wrap items-center gap-2 py-2" key={dependent.id}>
                <Link className="text-blue-600 hover:underline" to={withRoutePrefix(dependent.job.job_path, prefix)}>{dependent.job.repository_slug} {jobSlug(dependent.job.id)}</Link>
                <StatusPill state={dependent.job.summary_state} />
              </li>
            ))}
          </ul>
        ) : <p className="mt-2 text-gray-400 dark:text-gray-500">No dependent Jobs.</p>}
      </div>
    </section>
  )
}

function TimelinePanel({ canView, jobId, prefix }: { canView: boolean; jobId: number; prefix: string }) {
  const [expanded, setExpanded] = useState(false)
  const timeline = useQuery({
    queryKey: ["jobs", String(jobId), "timeline"],
    queryFn: () => fetchJobTimeline(String(jobId)),
    enabled: canView && expanded
  })

  if (!canView) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Timeline</h2>
        <button
          aria-expanded={expanded}
          className="rounded border border-gray-300 px-3 py-1 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          onClick={() => setExpanded((value) => !value)}
          type="button"
        >
          {expanded ? "Hide timeline" : "Show timeline"}
        </button>
      </div>
      {expanded && timeline.isPending ? <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">Loading timeline...</p> : null}
      {expanded && timeline.isError ? <p className="mt-2 text-sm text-red-700">{errorMessage(timeline.error || new Error("Timeline failed."), "Unable to load timeline.")}</p> : null}
      {expanded && timeline.data && timeline.data.events.length > 0 ? (
        <ol className="mt-3 space-y-3">
          {timeline.data.events.map((event, index) => (
            <li className="border-l border-gray-200 pl-3 text-sm dark:border-gray-700" key={`${event.at}-${event.title}-${index}`}>
              <div className="font-medium text-gray-900 dark:text-gray-100">
                {event.workflow_path ? (
                  <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(event.workflow_path, prefix)}>{event.title}</Link>
                ) : event.title}
              </div>
              <div className="text-xs text-gray-500 dark:text-gray-400">
                {formatDate(event.at)} · {event.source}
                {event.ref_label ? (
                  <>
                    {" · "}
                    {event.workflow_path ? (
                      <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(event.workflow_path, prefix)}>{event.ref_label}</Link>
                    ) : event.ref_label}
                  </>
                ) : null}
              </div>
              {event.detail ? <div className="mt-1 text-gray-600 dark:text-gray-300">{event.detail}</div> : null}
            </li>
          ))}
        </ol>
      ) : null}
    </section>
  )
}

function AttachmentPreview({ attachments }: { attachments: JobAttachment[] }) {
  if (attachments.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Attachments</h2>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {attachments.slice(0, 6).map((attachment) => <AttachmentCard attachment={attachment} key={attachment.id} />)}
      </div>
    </section>
  )
}

function WorkflowsTab({ payload, command, prefix }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  if (payload.workflows.length === 0) return <PanelMessage>No workflows yet.</PanelMessage>

  return (
    <div className="space-y-4">
      <WorkflowsPagination payload={payload} prefix={prefix} />
      {payload.workflows.map((workflow) => <WorkflowCard command={command} key={workflow.id} payload={payload} prefix={prefix} workflow={workflow} />)}
      <WorkflowsPagination payload={payload} prefix={prefix} />
    </div>
  )
}

function WorkflowsPagination({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const pagination = payload.workflows_pagination
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label="Workflow pagination" className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>Showing {pagination.first_item}-{pagination.last_item} of {pagination.total_workflows}</span>
      <div className="flex gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>Previous</Link> : <span className={disabledPaginationClass()}>Previous</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>Next</Link> : <span className={disabledPaginationClass()}>Next</span>}
      </div>
    </nav>
  )
}

function WorkflowCard({ workflow, payload, command, prefix }: { workflow: JobWorkflow; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; prefix: string }) {
  const stepItems = workflowStepItems(workflow.steps)

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" id={`workflow-${workflow.id}`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            <Link className="hover:underline" to={withRoutePrefix(workflow.path, prefix)}>{workflow.slug || workflowSlug(workflow.id)}</Link>
          </h2>
          <p className="text-xs text-gray-500 dark:text-gray-400">{workflow.trigger_kind} · {workflow.agent_provider || "default agent"} · created {formatDate(workflow.created_at)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {workflow.state === "running" ? null : <StatusPill state={workflow.state} />}
          {workflow.retry_available ? <CommandButton command={command} input={{ method: "post", path: workflow.app_retry_step_path }} tone="secondary">Retry failed step</CommandButton> : null}
          {workflow.state === "failed" && !workflow.cleaned_up_at ? <CommandButton command={command} input={{ method: "post", path: workflow.app_push_commits_path }} tone="secondary">Push commits</CommandButton> : null}
        </div>
      </div>
      <div className="mt-4 overflow-hidden rounded border border-gray-200 dark:border-gray-700">
        {stepItems.map((item, index) => item.type === "loop" ? (
          <LoopGroup command={command} item={item} key={item.loopId} payload={payload} />
        ) : (
          <DisplayStepCard command={command} item={item} key={displayStepItemKey(item)} numberLabel={index + 1} payload={payload} />
        ))}
      </div>
    </section>
  )
}

function LoopGroup({ item, payload, command }: { item: LoopStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
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
          <span className="font-medium text-gray-900 dark:text-gray-100">{loopDisplayName(item)}</span>
          <SmallPill>{item.iterations.length} {plural(item.iterations.length, "iteration")}</SmallPill>
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
                Iteration {iteration.iteration}
              </div>
              {iteration.items.map((stepItem, index) => (
                <DisplayStepCard command={command} item={stepItem} key={displayStepItemKey(stepItem)} numberLabel={index + 1} payload={payload} />
              ))}
            </section>
          ))}
        </div>
      ) : null}
    </section>
  )
}

function DisplayStepCard({ item, payload, command, numberLabel }: { item: DisplayStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string }) {
  if (item.type === "grade") return <GradeGroup command={command} item={item} numberLabel={numberLabel} payload={payload} />

  return <StepCard command={command} numberLabel={numberLabel} payload={payload} step={item.step} />
}

function GradeGroup({ item, payload, command, numberLabel }: { item: GradeStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string }) {
  const [open, setOpen] = useState(false)
  const status = gradeDisplayStatus(item)
  const phases = gradePhases(item)
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
          <span className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">Grade</span>
          {item.graders.length > 0 ? <SmallPill>{item.graders.length} {plural(item.graders.length, "check")}</SmallPill> : null}
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
              />
            ))}
          </div>
        </div>
      ) : null}
    </div>
  )
}

type GradeSummary = {
  name: string
  status: "passed" | "failed" | "error" | "running" | "queued" | "cancelled" | "unknown"
  required: boolean | null
  exitCode: number | null
  duration: number | null
  logBytes: number | null
}

function GradeSummaryPills({ summaries }: { summaries: GradeSummary[] }) {
  const counts = gradeSummaryCounts(summaries)
  return (
    <span className="hidden items-center gap-1 sm:inline-flex">
      {counts.passed > 0 ? <SmallPill>{counts.passed} passed</SmallPill> : null}
      {counts.failed > 0 ? <SmallPill>{counts.failed} failed</SmallPill> : null}
      {counts.error > 0 ? <SmallPill>{counts.error} error</SmallPill> : null}
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
  const [expanded, setExpanded] = useState(false)
  const description = (stringValue(details.description) || "").replace(/\s+/g, " ").trim()
  const command = (stringValue(details.command) || "").trim()
  const required = booleanValue(details.required)
  const isLong = description.length > GRADER_DESCRIPTION_LIMIT
  const shownDescription = expanded || !isLong ? description : `${description.slice(0, GRADER_DESCRIPTION_LIMIT).trimEnd()}…`

  return (
    <div className="mt-2 space-y-2 text-xs">
      <SmallPill>{required === false ? "optional" : "required"}</SmallPill>
      {description ? (
        <p className="text-gray-700 dark:text-gray-300">
          {shownDescription}
          {isLong ? (
            <button
              className="ml-1 font-medium text-blue-600 hover:text-blue-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
              onClick={() => setExpanded((current) => !current)}
              type="button"
            >
              {expanded ? "Read less" : "Read more"}
            </button>
          ) : null}
        </p>
      ) : (
        <p className="italic text-gray-400 dark:text-gray-500">No description.</p>
      )}
      {command ? (
        <div>
          <div className="mb-1 font-medium uppercase tracking-wide text-gray-400 dark:text-gray-500">Command</div>
          <pre className="overflow-x-auto rounded bg-white p-2 font-mono text-[11px] text-gray-700 dark:bg-gray-950 dark:text-gray-300">{command}</pre>
        </div>
      ) : null}
    </div>
  )
}

function StepCard({ step, payload, command, numberLabel, displayName, metadataLabel }: { step: JobStep; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number | string; displayName?: string; metadataLabel?: string }) {
  const [open, setOpen] = useState(false)
  const runs = sortedRunsNewestFirst(step.runs)
  const activeRun = runs.find((run) => isActiveState(run.state))
  const displayStatus = activeRun ? activeRun.state : step.display_status
  const prepareFailure = prepareFailureDetails(step)

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
            {step.loop_id ? <span>iteration {step.iteration ?? 1}</span> : null}
            {activeRun && step.state !== activeRun.state ? <SmallPill>step {step.state.replaceAll("_", " ")}</SmallPill> : null}
            {step.latest ? <SmallPill>latest</SmallPill> : null}
            <span>{formatDate(step.started_at || step.created_at)}</span>
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
              {runs.map((run) => <RunRow active={activeRun?.id === run.id} command={command} key={run.id} payload={payload} run={run} />)}
            </div>
          ) : <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">No runs for this step.</p>}
        </div>
      ) : null}
    </div>
  )
}

function PrepareFailurePanel({ failure }: { failure: PrepareFailure }) {
  const status = prepareFailureStatus(failure)

  return (
    <section className="mt-2 rounded border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
      <div className="font-semibold">Setup failed before the agent started</div>
      <dl className="mt-2 grid gap-x-4 gap-y-1 md:grid-cols-[max-content_1fr]">
        <dt className="font-medium">Command</dt>
        <dd className="min-w-0 break-words font-mono">{failure.command || "-"}</dd>
        <dt className="font-medium">Working directory</dt>
        <dd className="min-w-0 break-words font-mono">{failure.workdir || "-"}</dd>
        <dt className="font-medium">Status</dt>
        <dd>{status}</dd>
      </dl>
      {failure.output_tail ? (
        <pre className="mt-3 max-h-64 overflow-auto rounded border border-amber-200 bg-white/70 p-2 font-mono text-[11px] text-amber-950 whitespace-pre-wrap dark:border-amber-800 dark:bg-gray-950 dark:text-amber-100">{failure.output_tail}</pre>
      ) : null}
    </section>
  )
}

function RunRow({ run, payload, command, active = false }: { run: JobRun; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; active?: boolean }) {
  const [gradeLogOpen, setGradeLogOpen] = useState(false)
  const [artifactView, setArtifactView] = useState<"transcript" | "diff" | null>(null)
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
    enabled: artifactView != null,
    refetchInterval: artifactView === "transcript" && isActiveState(run.state) ? 2000 : false
  })
  const artifactsLoading = artifacts.isFetching && !artifacts.data

  function showArtifacts(view: "transcript" | "diff") {
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
            <span className="font-medium text-gray-900 dark:text-gray-100">Run #{run.id}</span>
            <StatusPill state={run.state} />
            {run.rate_limited ? <SmallPill>rate limited</SmallPill> : null}
          </div>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {run.agent_provider || "agent"} · {run.agent_turns ?? 0} {plural(run.agent_turns ?? 0, "turn")} · {run.job_log_count} log {plural(run.job_log_count, "line")} · {formatCurrency(run.cost_usd || 0)}
          </p>
          {run.agent_summary ? <p className="mt-2 whitespace-pre-wrap text-gray-700 dark:text-gray-300">{run.agent_summary}</p> : null}
          {run.health_snapshots.at(-1) ? <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">Health: {run.health_snapshots.at(-1)?.health_status || "unknown"} {run.health_snapshots.at(-1)?.hint ? `- ${run.health_snapshots.at(-1)?.hint}` : ""}</p> : null}
          {run.failure_classification ? <p className="mt-1 text-xs text-gray-600 dark:text-gray-300">Failure: {humanize(run.failure_classification.classification)} · {run.failure_classification.retryable ? "retryable" : "manual review"}{run.failure_classification.reason ? ` - ${run.failure_classification.reason}` : ""}</p> : null}
          {run.run_diagnostic?.present ? <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">Diagnostic captured {formatDate(run.run_diagnostic.created_at)}{run.run_diagnostic.error_message ? `: ${run.run_diagnostic.error_message}` : ""}</p> : null}
        </div>
        <div className="flex flex-wrap justify-end gap-2">
          {run.job_log_count > 0 ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("transcript")} type="button">
              {artifactsLoading && artifactView === "transcript" ? "Loading..." : "Transcript"}
            </button>
          ) : null}
          {run.agent_diff_present ? (
            <button className={buttonClass("secondary")} disabled={artifactsLoading} onClick={() => showArtifacts("diff")} type="button">
              {artifactsLoading && artifactView === "diff" ? "Loading..." : "Diff"}
            </button>
          ) : null}
          {run.can_stop ? <CommandButton command={command} input={{ method: "post", path: run.app_stop_path }} tone="danger">Stop</CommandButton> : null}
          {run.can_diagnose ? <CommandButton command={command} input={{ method: "post", path: run.app_diagnose_path }} tone="secondary">Diagnose</CommandButton> : null}
          {run.can_resume ? <CommandButton command={command} input={{ method: "post", path: payload.paths.app_resume_path, body: { source_run_id: run.id } }} tone="secondary">Resume</CommandButton> : null}
          {run.app_grade_log_path ? (
            <button className={buttonClass("secondary")} disabled={gradeLog.isPending} onClick={() => showGradeLog(run.app_grade_log_path!)} type="button">
              {gradeLog.isPending ? "Loading log..." : "Grade log"}
            </button>
          ) : null}
        </div>
      </div>
      {artifacts.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(artifacts.error, "Unable to load run artifacts.")}</p> : null}
      {artifactView && artifacts.data ? <RunArtifactsPanel onClose={() => setArtifactView(null)} payload={artifacts.data} view={artifactView} /> : null}
      {gradeLog.isError ? <p className="mt-3 text-xs text-red-700 dark:text-red-300">{errorMessage(gradeLog.error, "Grade log failed.")}</p> : null}
      {gradeLogOpen && gradeLog.data ? (
        <RunGradeLogPanel onClose={() => setGradeLogOpen(false)} payload={gradeLog.data} />
      ) : null}
    </div>
  )
}

function RunArtifactsPanel({ payload, view, onClose }: { payload: Awaited<ReturnType<typeof fetchJobRunArtifacts>>; view: "transcript" | "diff"; onClose: () => void }) {
  if (view === "diff") {
    return (
      <section className={artifactPanelClass()}>
        <ArtifactPanelHeader onClose={onClose}>Agent diff</ArtifactPanelHeader>
        {payload.agent_diff ? (
          <AgentDiff diff={payload.agent_diff} />
        ) : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">No diff captured for this run.</p>}
      </section>
    )
  }

  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>Transcript</ArtifactPanelHeader>
      {payload.logs.length > 0 ? <RunTranscriptLogs logs={payload.logs} /> : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">No transcript rows captured for this run.</p>}
    </section>
  )
}

function RunGradeLogPanel({ payload, onClose }: { payload: Awaited<ReturnType<typeof fetchJobGradeLog>>; onClose: () => void }) {
  return (
    <section className={artifactPanelClass()}>
      <ArtifactPanelHeader onClose={onClose}>{payload.name || `Run #${payload.run_id}`} grade log</ArtifactPanelHeader>
      <pre className="max-h-96 overflow-auto bg-white p-3 font-mono text-xs text-gray-800 whitespace-pre-wrap max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950 dark:text-gray-200" data-testid="run-grade-log-stream">{payload.contents}</pre>
    </section>
  )
}

function artifactPanelClass() {
  return "mt-3 rounded border border-gray-200 bg-gray-50 max-md:fixed max-md:inset-0 max-md:z-50 max-md:mt-0 max-md:flex max-md:h-[100dvh] max-md:flex-col max-md:rounded-none max-md:border-0 max-md:bg-white dark:border-gray-700 dark:bg-gray-950 max-md:dark:bg-gray-950"
}

function ArtifactPanelHeader({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  return (
    <div className="flex shrink-0 items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
      <h4 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{children}</h4>
      <button aria-label="Close artifact viewer" className="hidden rounded p-2 text-gray-500 hover:bg-gray-100 hover:text-gray-700 max-md:block dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
        <CloseIcon className="h-5 w-5" />
      </button>
    </div>
  )
}

type DiffLineKind = "file" | "meta" | "hunk" | "add" | "delete" | "context"
type DiffLine = {
  kind: DiffLineKind
  oldLine: number | null
  newLine: number | null
  marker: string
  code: string
}

function AgentDiff({ diff }: { diff: string }) {
  const lines = parseUnifiedDiff(diff)

  return (
    <div className="max-h-[32rem] overflow-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950" data-testid="agent-diff-viewer">
      <table className="min-w-full border-separate border-spacing-0">
        <tbody>
          {lines.map((line, index) => (
            <tr className={diffLineClass(line.kind)} data-diff-kind={line.kind} key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
              <td className={diffGutterClass(line.kind)}>{line.oldLine ?? ""}</td>
              <td className={diffGutterClass(line.kind)}>{line.newLine ?? ""}</td>
              <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
              <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200">{line.code || " "}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function parseUnifiedDiff(diff: string) {
  const rawLines = diff.replace(/\r\n/g, "\n").split("\n")
  if (rawLines.at(-1) === "") rawLines.pop()

  const lines: DiffLine[] = []
  let oldLine: number | null = null
  let newLine: number | null = null

  for (const rawLine of rawLines) {
    const hunk = rawLine.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
    if (hunk) {
      oldLine = Number(hunk[1])
      newLine = Number(hunk[2])
      lines.push(diffLine("hunk", rawLine))
      continue
    }

    if (rawLine.startsWith("diff --git ")) {
      lines.push(diffLine("file", rawLine))
    } else if (rawLine.startsWith("+") && !rawLine.startsWith("+++")) {
      lines.push(diffLine("add", rawLine.slice(1), null, newLine, "+"))
      if (newLine !== null) newLine += 1
    } else if (rawLine.startsWith("-") && !rawLine.startsWith("---")) {
      lines.push(diffLine("delete", rawLine.slice(1), oldLine, null, "-"))
      if (oldLine !== null) oldLine += 1
    } else if (rawLine.startsWith(" ") && oldLine !== null && newLine !== null) {
      lines.push(diffLine("context", rawLine.slice(1), oldLine, newLine))
      oldLine += 1
      newLine += 1
    } else {
      lines.push(diffLine("meta", rawLine))
    }
  }

  return lines
}

function diffLine(kind: DiffLineKind, code: string, oldLine: number | null = null, newLine: number | null = null, marker = "") {
  return { kind, oldLine, newLine, marker, code }
}

function diffLineClass(kind: DiffLineKind) {
  switch (kind) {
    case "add": return "bg-green-50 dark:bg-green-950/40"
    case "delete": return "bg-red-50 dark:bg-red-950/40"
    case "hunk": return "bg-blue-50 text-blue-800 dark:bg-blue-950/50 dark:text-blue-200"
    case "file": return "bg-gray-100 font-semibold dark:bg-gray-800 dark:text-gray-100"
    case "meta": return "bg-gray-50 text-gray-500 dark:bg-gray-900 dark:text-gray-400"
    default: return "bg-white dark:bg-gray-950"
  }
}

function diffGutterClass(kind: DiffLineKind) {
  const base = "w-12 select-none border-r px-2 py-0.5 text-right text-gray-400"
  switch (kind) {
    case "add": return `${base} border-green-200 bg-green-100 text-green-700 dark:border-green-900 dark:bg-green-950/60 dark:text-green-300`
    case "delete": return `${base} border-red-200 bg-red-100 text-red-700 dark:border-red-900 dark:bg-red-950/60 dark:text-red-300`
    case "hunk": return `${base} border-blue-200 bg-blue-100 text-blue-700 dark:border-blue-900 dark:bg-blue-950/60 dark:text-blue-300`
    default: return `${base} border-gray-200 bg-gray-50 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-500`
  }
}

function diffMarkerClass(kind: DiffLineKind) {
  const base = "w-6 select-none px-2 py-0.5 text-center"
  switch (kind) {
    case "add": return `${base} text-green-700`
    case "delete": return `${base} text-red-700`
    case "hunk": return `${base} text-blue-700`
    default: return `${base} text-gray-300`
  }
}

function RunTranscriptLogs({ logs }: { logs: Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"] }) {
  const listRef = useRef<HTMLOListElement | null>(null)
  const atBottomRef = useRef(true)
  const logSignature = logs.map((log) => `${log.id}:${log.sequence}:${log.kind || ""}:${log.chunk.length}`).join("|")
  const displayLogs = coalesceTranscriptLogs(logs)

  function handleScroll(event: UIEvent<HTMLOListElement>) {
    atBottomRef.current = isRunTranscriptAtBottom(event.currentTarget)
  }

  useLayoutEffect(() => {
    if (atBottomRef.current) scrollRunTranscriptToBottom(listRef.current)
  }, [logSignature])

  return (
    <ol className="max-h-[32rem] overflow-auto divide-y divide-gray-200 max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:divide-gray-800" data-testid="run-transcript-log-stream" onScroll={handleScroll} ref={listRef}>
      {displayLogs.map((log) => (
        <li className="grid gap-2 px-3 py-2 font-mono text-xs text-gray-800 sm:grid-cols-[5rem_minmax(0,1fr)] dark:text-gray-200" key={log.id}>
          <span className="text-gray-400 dark:text-gray-500">{transcriptLogKindLabel(log.kind) || `#${log.sequence}`}</span>
          <pre className="whitespace-pre-wrap break-words">{log.chunk}</pre>
        </li>
      ))}
    </ol>
  )
}

type TranscriptLog = Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"][number]
type DisplayTranscriptLog = TranscriptLog & { sourceKey: string }

function coalesceTranscriptLogs(logs: TranscriptLog[]) {
  const displayLogs: DisplayTranscriptLog[] = []
  const sourceByKind = new Map<string, string>()

  for (const log of logs) {
    const displayLog = { ...log, sourceKey: transcriptLogSourceKey(log, sourceByKind) }
    const previous = displayLogs.at(-1)
    if (previous && shouldCoalesceTranscriptLogs(previous, displayLog)) {
      previous.chunk = joinTranscriptChunks(previous.chunk, displayLog.chunk)
      continue
    }

    displayLogs.push(displayLog)
  }

  return displayLogs
}

function transcriptLogSourceKey(log: TranscriptLog, sourceByKind: Map<string, string>) {
  const kind = log.kind || "log"
  const command = commandMarkerSource(log.chunk)
  if (command) {
    const source = `${kind}:command:${command}`
    sourceByKind.set(kind, source)
    return source
  }

  return sourceByKind.get(kind) || `${kind}:run`
}

function commandMarkerSource(chunk: string) {
  const firstLine = chunk.split(/\r?\n/, 1)[0]?.trim() || ""
  const marker = firstLine.match(/^\[(prepare|grade|grader:[^\]]+)\](?: \(\d+\/\d+\))? \$ (.+)$/)
  if (!marker) return null

  return `${marker[1]}:${marker[2]}`
}

function shouldCoalesceTranscriptLogs(previous: DisplayTranscriptLog, next: DisplayTranscriptLog) {
  if (previous.kind !== next.kind) return false
  if (previous.sourceKey !== next.sourceKey) return false
  return !["tool_call", "rate_limited"].includes(previous.kind || "")
}

function joinTranscriptChunks(previous: string, next: string) {
  if (previous.endsWith("\n") || next.startsWith("\n")) return previous + next
  return `${previous}\n${next}`
}

function isRunTranscriptAtBottom(element: HTMLElement) {
  return element.scrollHeight - element.scrollTop - element.clientHeight <= RUN_TRANSCRIPT_BOTTOM_THRESHOLD_PX
}

function scrollRunTranscriptToBottom(element: HTMLElement | null) {
  if (!element) return
  element.scrollTop = element.scrollHeight
}

function transcriptLogKindLabel(kind: string | null | undefined) {
  if (kind === "assistant_text") return "Agent"
  if (kind === "tool_call") return "Tool"
  if (kind === "system") return "System"
  return kind
}

function AttachmentsTab({ payload, queryKey, onNotice }: { payload: JobDetailPayload; queryKey: JobDetailQueryKey; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [files, setFiles] = useState<File[]>([])
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const add = useMutation({
    mutationFn: () => createJobAttachments(payload.paths.app_attachments_path, { files, googleDocUrl }),
    onSuccess: (result) => {
      onNotice(result.message || null)
      setFiles([])
      setGoogleDocUrl("")
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(payload.job.id)] })
    }
  })
  const remove = useMutation({
    mutationFn: (path: string) => deleteJobCommand(path),
    onSuccess: (result) => {
      onNotice(result.message || null)
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs", String(payload.job.id)] })
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    add.mutate()
  }

  return (
    <section className="space-y-4">
      <form className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" onSubmit={submit}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Add attachment</h2>
        <div className="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] md:items-end">
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            Files
            <input className="mt-1 block w-full text-sm" multiple onChange={(event) => setFiles(Array.from(event.target.files || []))} type="file" />
          </label>
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
            Google Doc URL
            <input className="mt-1 w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/..." type="url" value={googleDocUrl} />
          </label>
          <button className={buttonClass("primary")} disabled={add.isPending || (files.length === 0 && googleDocUrl.trim() === "")} type="submit">Add</button>
        </div>
        {add.isError ? <p className="mt-2 text-sm text-red-700">{errorMessage(add.error, "Unable to add attachment.")}</p> : null}
      </form>

      {payload.attachments.length > 0 ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {payload.attachments.map((attachment) => (
            <div className="relative" key={attachment.id}>
              <AttachmentCard attachment={attachment} />
              <button className="absolute right-2 top-2 rounded border border-red-200 bg-white px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:bg-gray-950 dark:text-red-300 dark:hover:bg-red-950/40" disabled={remove.isPending} onClick={() => remove.mutate(attachment.app_delete_path)} type="button">Remove</button>
            </div>
          ))}
        </div>
      ) : <PanelMessage>No attachments.</PanelMessage>}
      {remove.isError ? <PanelMessage tone="error">{errorMessage(remove.error, "Unable to remove attachment.")}</PanelMessage> : null}
    </section>
  )
}

function AttachmentCard({ attachment }: { attachment: JobAttachment }) {
  const title = attachment.title || attachment.filename || attachment.google_doc_url || `Attachment #${attachment.id}`
  return (
    <article className="rounded border border-gray-200 bg-white p-3 text-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="font-medium text-gray-900 dark:text-gray-100">{attachment.file_path ? <a className="hover:underline" href={attachment.file_path}>{title}</a> : title}</div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {attachment.google_doc_url ? <a className="text-blue-600 hover:underline" href={attachment.google_doc_url} rel="noopener" target="_blank">Google Doc</a> : attachment.content_type || attachment.attachment_type}
        {attachment.byte_size ? ` · ${formatBytes(attachment.byte_size)}` : ""}
      </div>
    </article>
  )
}

function SourceTab({ jobId }: { jobId: string }) {
  const [sourceRef, setSourceRef] = useState<string | null>(null)
  const [sourcePath, setSourcePath] = useState<string | null>(null)
  const search = sourceSearch(sourceRef, sourcePath)
  const source = useQuery({
    queryKey: ["jobs", jobId, "source", search],
    queryFn: () => fetchJobSource(jobId, search)
  })

  if (source.isPending) return <PanelMessage>Loading source browser...</PanelMessage>
  if (source.isError) return <PanelMessage tone="error">{errorMessage(source.error, "Unable to load source browser.")}</PanelMessage>

  return <SourceBrowser payload={source.data} onSelectPath={(path) => {
    setSourceRef(source.data.selected_ref)
    setSourcePath(path)
  }} onSelectRef={(ref) => {
    setSourceRef(ref)
    setSourcePath(null)
  }} />
}

function SourceBrowser({ payload, onSelectPath, onSelectRef }: { payload: JobSourcePayload; onSelectPath: (path: string) => void; onSelectRef: (ref: string) => void }) {
  const visibleItems = useMemo(() => payload.tree_items.slice(0, 2000), [payload.tree_items])
  const tree = useMemo(() => buildSourceTree(visibleItems), [visibleItems])
  const [expandedPaths, setExpandedPaths] = useState<Set<string>>(() => new Set())
  const refOptions = refOptionsFor(payload)

  if (payload.source_error) return <PanelMessage tone="error">{payload.source_error}</PanelMessage>

  function toggleDirectory(path: string) {
    setExpandedPaths((current) => {
      const next = new Set(current)
      if (next.has(path)) {
        next.delete(path)
      } else {
        next.add(path)
      }
      return next
    })
  }

  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <label className="text-sm text-gray-600 dark:text-gray-300">
          Viewing
          <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" onChange={(event) => onSelectRef(event.target.value)} value={payload.selected_ref}>
            {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        {payload.tree_truncated ? <span className="text-xs text-amber-700">Tree truncated by GitHub.</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)] dark:border-gray-700 dark:bg-gray-900">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r dark:border-gray-700 dark:bg-gray-950">
          {tree.length > 0 ? tree.map((node) => (
            <SourceTreeRow
              expandedPaths={expandedPaths}
              key={node.path}
              node={node}
              onSelectPath={onSelectPath}
              onToggleDirectory={toggleDirectory}
              selectedPath={payload.selected_path}
            />
          )) : <p className="p-4 text-sm text-gray-400 dark:text-gray-500">No files found.</p>}
          {payload.tree_items.length > visibleItems.length ? <p className="p-3 text-xs text-amber-700">Showing first {visibleItems.length.toLocaleString()} files.</p> : null}
        </div>
        <div className="min-w-0 overflow-auto">
          {payload.file_error ? <p className="p-4 text-sm text-red-700">{payload.file_error}</p> : null}
          {payload.file ? (
            <>
              <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
                <span className="min-w-0 flex-1 truncate">{payload.file.path}</span>
                <span>{payload.file.language}</span>
                <span>{formatBytes(payload.file.size)}</span>
              </div>
              <pre className="m-0 overflow-x-auto p-4 text-sm leading-relaxed text-gray-900 dark:text-gray-100"><code>{payload.file.content}</code></pre>
            </>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400 dark:text-gray-500">Select a file to view its contents.</div>}
        </div>
      </div>
    </section>
  )
}

type SourceTreeFile = JobSourcePayload["tree_items"][number]
type SourceTreeNode = {
  path: string
  name: string
  children: SourceTreeNode[]
  file: SourceTreeFile | null
}

function buildSourceTree(items: SourceTreeFile[]) {
  const root: SourceTreeNode = { path: "", name: "", children: [], file: null }
  const directories = new Map<string, SourceTreeNode>([["", root]])

  for (const item of items) {
    const parts = item.path.split("/").filter(Boolean)
    let parent = root
    let currentPath = ""

    parts.forEach((part, index) => {
      currentPath = currentPath ? `${currentPath}/${part}` : part
      let node = directories.get(currentPath)

      if (!node) {
        node = { path: currentPath, name: part, children: [], file: null }
        directories.set(currentPath, node)
        parent.children.push(node)
      }

      if (index === parts.length - 1) node.file = item
      parent = node
    })
  }

  sortSourceTree(root)
  return root.children
}

function sortSourceTree(node: SourceTreeNode) {
  node.children.sort((a, b) => {
    if (!!a.file !== !!b.file) return a.file ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  node.children.forEach(sortSourceTree)
}

function SourceTreeRow({
  expandedPaths,
  node,
  onSelectPath,
  onToggleDirectory,
  selectedPath
}: {
  expandedPaths: Set<string>
  node: SourceTreeNode
  onSelectPath: (path: string) => void
  onToggleDirectory: (path: string) => void
  selectedPath: string | null
}) {
  return (
    <>
      {node.file ? (
        <button
          className={`block w-full truncate py-1.5 pr-3 text-left font-mono text-xs hover:bg-blue-50 dark:hover:bg-blue-950/40 ${selectedPath === node.path ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-200" : "text-gray-700 dark:text-gray-300"}`}
          key={node.path}
          onClick={() => onSelectPath(node.path)}
          style={{ paddingLeft: `${0.75 + node.path.split("/").length * 0.75}rem` }}
          title={`${node.path} (${formatBytes(node.file.size)})`}
          type="button"
        >
          {node.name}
        </button>
      ) : (
        <button
          aria-expanded={expandedPaths.has(node.path)}
          aria-label={node.name}
          className="block w-full truncate py-1.5 pr-3 text-left font-mono text-xs font-semibold text-gray-700 hover:bg-blue-50 dark:text-gray-300 dark:hover:bg-blue-950/40"
          onClick={() => onToggleDirectory(node.path)}
          style={{ paddingLeft: `${0.75 + Math.max(node.path.split("/").length - 1, 0) * 0.75}rem` }}
          title={node.path}
          type="button"
        >
          <span className="mr-1 inline-block w-3 text-gray-400 dark:text-gray-500">{expandedPaths.has(node.path) ? "-" : "+"}</span>
          {node.name}
        </button>
      )}
      {!node.file && expandedPaths.has(node.path) ? node.children.map((child) => (
        <SourceTreeRow
          expandedPaths={expandedPaths}
          key={child.path}
          node={child}
          onSelectPath={onSelectPath}
          onToggleDirectory={onToggleDirectory}
          selectedPath={selectedPath}
        />
      )) : null}
    </>
  )
}

function refOptionsFor(payload: JobSourcePayload) {
  const options = new Map<string, string>()
  options.set(payload.merge_base_sha || payload.default_ref, `Merge base (${(payload.merge_base_sha || payload.default_ref).slice(0, 7)})`)
  payload.branch_commits.forEach((commit) => options.set(commit.sha, `${commit.short_sha} ${commit.message}`))
  if (!options.has(payload.selected_ref)) options.set(payload.selected_ref, payload.selected_ref.slice(0, 12))

  return Array.from(options, ([value, label]) => ({ value, label }))
}

function sourceSearch(ref: string | null, path: string | null) {
  const params = new URLSearchParams()
  if (ref) params.set("ref", ref)
  if (path) params.set("path", path)
  const value = params.toString()
  return value ? `?${value}` : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function KeyValue({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <div className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-gray-800 dark:text-gray-200">{children}</div>
    </div>
  )
}

function MergeablePill({ value }: { value: boolean | null }) {
  if (value === true) return <StatusPill state="mergeable" />
  if (value === false) return <StatusPill state="unmergeable" />
  return <StatusPill state="unknown" />
}

function SmallPill({ children }: { children: ReactNode }) {
  return <span className="inline-flex items-center rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{children}</span>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function buttonClass(tone: ButtonTone) {
  const base = "inline-flex items-center rounded px-3 py-1.5 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50"
  const tones = {
    primary: "bg-blue-600 text-white hover:bg-blue-500 dark:bg-blue-500 dark:hover:bg-blue-400",
    secondary: "border border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800",
    success: "bg-emerald-600 text-white hover:bg-emerald-500 dark:bg-emerald-500 dark:hover:bg-emerald-400",
    danger: "bg-amber-600 text-white hover:bg-amber-500 dark:bg-amber-500 dark:text-gray-950 dark:hover:bg-amber-400"
  }
  return `${base} ${tones[tone]}`
}

function menuButtonClass(tone: ButtonTone) {
  const tones = {
    primary: "text-blue-700 hover:bg-blue-50 dark:text-blue-200 dark:hover:bg-blue-950/40",
    secondary: "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800",
    success: "text-emerald-700 hover:bg-emerald-50 dark:text-emerald-200 dark:hover:bg-emerald-950/40",
    danger: "text-amber-700 hover:bg-amber-50 dark:text-amber-200 dark:hover:bg-amber-950/40"
  }
  return `block w-full px-4 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-50 ${tones[tone]}`
}

function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
}

function jobSourceLabel(payload: JobDetailPayload) {
  if (payload.job.issue_number) return `#${payload.job.issue_number}`
  if (payload.job.kind === "direct") return "Direct Job"
  if (payload.job.kind === "cron") return "Scheduled Job"
  return jobSlug(payload.job.id)
}

function JobSourceLink({ payload }: { payload: JobDetailPayload }) {
  const label = jobSourceLabel(payload)
  if (!payload.job.issue_url) return <span>{label}</span>

  return (
    <a className="hover:underline" href={payload.job.issue_url} rel="noopener" target="_blank">
      {label}
    </a>
  )
}

function dependencyLabel(dependency: JobDependency) {
  if (dependency.pending) return dependency.unresolved_slug || "Unresolved dependency"
  const target = dependency.depends_on_job
  if (!target) return dependency.unresolved_slug || "Missing dependency"
  const issue = target.issue_number ? `#${target.issue_number}` : jobSlug(target.id)
  return `${target.repository_slug} ${issue} (${target.summary_state})`
}

function DependencyLink({ dependency, prefix }: { dependency: JobDependency; prefix: string }) {
  const target = dependency.depends_on_job
  const label = dependencyLabel(dependency)
  if (dependency.pending || !target) return <span>{label}</span>

  return <Link className="text-blue-700 underline hover:no-underline" to={withRoutePrefix(target.job_path, prefix)}>{label}</Link>
}

function jobSlug(id: number) {
  return `JOB-${id}`
}

function formatDate(value: string | null) {
  if (!value) return "-"
  return new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function formatCurrency(value: number) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 4, maximumFractionDigits: 4 }).format(value)
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}

function plural(count: number, singular: string) {
  return count === 1 ? singular : `${singular}s`
}

type WorkflowStepItem =
  | DisplayStepItem
  | LoopStepItem

type DisplayStepItem =
  | { type: "step"; step: JobStep }
  | GradeStepItem

type GradeStepItem = {
  type: "grade"
  key: string
  steps: JobStep[]
  graders: JobStep[]
}

type LoopStepItem = {
  type: "loop"
  loopId: string
  iterations: Array<{ iteration: number; steps: JobStep[]; items: DisplayStepItem[] }>
}

function workflowStepItems(steps: JobStep[]): WorkflowStepItem[] {
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

function displayStepItems(steps: JobStep[]): DisplayStepItem[] {
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
      graders: gradeSteps.filter((gradeStep) => gradeStep.kind === "grader" || gradeStep.kind === "grade")
    })
  }

  return items
}

function loopIterations(steps: JobStep[]) {
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

function isGradeDisplayStep(step: JobStep) {
  return step.kind === "grader_fanout" || step.kind === "grader" || step.kind === "grader_collect" || step.kind === "grade"
}

function displayStepItemKey(item: DisplayStepItem) {
  return item.type === "grade" ? item.key : `step-${item.step.id}`
}

function gradePhases(item: GradeStepItem) {
  return item.steps.map((step) => {
    if (step.kind === "grader_fanout") return { step, displayName: "Setup", metadataLabel: "grade setup" }
    if (step.kind === "grader_collect") return { step, displayName: "Result", metadataLabel: "grade result" }
    if (step.kind === "grade") return { step, displayName: step.display_name || "Grade", metadataLabel: "grade" }
    return { step, displayName: step.display_name, metadataLabel: "grader" }
  })
}

function gradeDisplayStatus(item: GradeStepItem) {
  const statuses = item.steps.map((step) => effectiveStepStatus(step)).filter((status): status is string => Boolean(status))
  if (statuses.includes("running")) return "running"
  if (statuses.includes("queued")) return "queued"
  if (statuses.includes("failed")) return "failed"
  if (statuses.includes("cancelled")) return "cancelled"
  if (item.steps.length > 0 && item.steps.every((step) => effectiveStepStatus(step) === "succeeded")) return "succeeded"
  return null
}

function gradeSummaries(item: GradeStepItem): GradeSummary[] {
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

function gradeSummaryStatus(step: JobStep, details: Record<string, unknown>): GradeSummary["status"] {
  const status = stringValue(details.status)
  if (status === "passed" || status === "failed" || status === "error" || status === "cancelled") return status
  if (step.state === "succeeded") return "passed"
  if (step.state === "failed") return numberValue(details.exit_code) === null ? "error" : "failed"
  if (step.state === "running") return "running"
  if (step.state === "queued") return "queued"
  if (step.state === "cancelled") return "cancelled"
  return "unknown"
}

function gradeSummaryCounts(summaries: GradeSummary[]) {
  return summaries.reduce((counts, summary) => {
    if (summary.status === "passed") counts.passed += 1
    else if (summary.status === "failed") counts.failed += 1
    else if (summary.status === "error") counts.error += 1
    return counts
  }, { passed: 0, failed: 0, error: 0 })
}

function loopDisplayName(item: LoopStepItem) {
  const kinds = item.iterations.flatMap((iteration) => iteration.steps.map((step) => step.kind))
  if (kinds.some((kind) => kind === "grade" || kind === "grader" || kind.startsWith("grader_"))) return "Grade loop"
  return "Loop"
}

function loopDisplayStatus(item: LoopStepItem) {
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

function effectiveStepStatus(step: JobStep) {
  const activeRun = sortedRunsNewestFirst(step.runs).find((run) => isActiveState(run.state))
  return activeRun?.state ?? step.display_status
}

function effectiveLoopStepStatus(step: JobStep) {
  return effectiveStepStatus(step) ?? step.state
}

function sortedRunsNewestFirst(runs: JobRun[]) {
  return [...runs].sort((left, right) => {
    const leftTime = runSortTime(left)
    const rightTime = runSortTime(right)
    if (leftTime !== rightTime) return rightTime - leftTime
    return right.id - left.id
  })
}

function runSortTime(run: JobRun) {
  return new Date(run.started_at || run.created_at || run.updated_at || 0).getTime()
}

function isActiveState(state: string) {
  return state === "queued" || state === "running"
}

// Live wall-clock, ticking every second while `active`. Used so a
// queued/running Run's elapsed time updates in place.
function useNow(active: boolean) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return undefined
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [active])
  return now
}

function formatElapsed(seconds: number) {
  const total = Math.max(0, Math.floor(seconds))
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  if (minutes < 60) return `${minutes}m ${total % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

// A queued Run hasn't started_at yet — it's waiting for a free worker in
// the SolidQueue pool, NOT "starting the agent". Surface that honestly
// (with how long it's been waiting) so a capacity wait doesn't read as a
// hung job; a running Run shows how long it's been going.
function ActiveRunBanner({ run }: { run: JobRun }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const queued = run.state === "queued" || !run.started_at
  const now = useNow(true)
  const sinceIso = queued ? run.created_at : run.started_at
  const elapsed = sinceIso ? formatElapsed((now - new Date(sinceIso).getTime()) / 1000) : null

  if (queued) {
    return (
      <div className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
        <span className="font-semibold">Run #{run.id} is waiting for a worker{elapsed ? ` · queued ${elapsed}` : ""}</span>
        <span className="mt-1 block text-amber-700 dark:text-amber-300">
          The run-worker pool is busy — this run starts as soon as a slot frees up, it is not stuck. Check the{" "}
          <Link className="underline hover:text-amber-900 dark:hover:text-amber-100" to={withRoutePrefix("/admin/queue/pending", prefix)}>pending queue</Link> for the backlog.
        </span>
      </div>
    )
  }

  return (
    <div className="mt-2 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-xs text-blue-800 dark:border-blue-900/70 dark:bg-blue-950/40 dark:text-blue-200">
      <span className="font-semibold">Run #{run.id} is running{elapsed ? ` · ${elapsed}` : ""}</span>
      <span> (since {formatDate(run.started_at)})</span>
    </div>
  )
}

function prepareFailureDetails(step: JobStep): PrepareFailure | null {
  if (step.kind !== "prepare" || !isRecord(step.details)) return null
  const failure = step.details.prepare_failure
  return isRecord(failure) ? failure as PrepareFailure : null
}

function prepareFailureStatus(failure: PrepareFailure) {
  if (failure.timed_out) return "timed out"
  if (failure.operator_killed) return "operator killed"
  if (failure.stopped) return "stopped"
  if (failure.aliveness_failed) return "process disappeared"
  if (failure.exit_status != null) return `exit ${failure.exit_status}`
  return "failed"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function stringify(value: unknown) {
  return typeof value === "string" ? value : JSON.stringify(value, null, 2)
}

function humanize(value: string) {
  return value.replaceAll("_", " ")
}

function objectDetails(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {}
  return value as Record<string, unknown>
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : null
}

function numberValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function booleanValue(value: unknown) {
  return typeof value === "boolean" ? value : null
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
