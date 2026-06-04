import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { CloseIcon } from "../components/CloseIcon"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill } from "../components/StatusPill"
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
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const command = useJobCommand(payload.job.id, queryKey, setNotice)
  const title = payload.job.issue_title || jobSourceLabel(payload)

  useEffect(() => {
    setNotice(payload.message || null)
  }, [payload.job.id, payload.message])

  return (
    <>
      <header className="space-y-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h1 className="break-words text-3xl font-semibold text-gray-900">{title}</h1>
            <div className="flex flex-wrap items-center gap-2">
              <p className="mt-1 break-words text-sm text-gray-600">
                <Link className="font-mono hover:underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>{payload.repository.slug}</Link>
                <span className="px-2 text-gray-300">/</span>
                <span>{jobSourceLabel(payload)}</span>
              </p>
              <StatusPill state={payload.job.summary_state} />
              {payload.job.agent_provider ? <SmallPill>{payload.job.agent_provider}</SmallPill> : null}
              {payload.job.credential_mode ? <SmallPill>{payload.job.credential_mode}</SmallPill> : null}
            </div>
            <p className="mt-1 text-sm text-gray-500">
              Job #{payload.job.id} · {payload.job.workflows_count} {plural(payload.job.workflows_count, "workflow")} · {payload.job.runs_count} {plural(payload.job.runs_count, "run")}
              {payload.job.total_cost_usd == null ? null : <> · {formatCurrency(payload.job.total_cost_usd)}</>}
              {payload.job.prepare_skipped ? <span className="font-medium text-amber-700"> · prepare skipped</span> : null}
            </p>
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
  if (actions.can_approve) available.push({ key: "approve", label: "Approve", input: { method: "post", path: paths.app_approve_path }, tone: "success" })
  if (actions.can_unapprove) available.push({ key: "unapprove", label: "Unapprove", input: { method: "post", path: paths.app_unapprove_path, confirm: "Move this Job back to implemented?" }, tone: "secondary" })
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
    add("mark_valid")
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
        <div className="absolute right-0 z-20 mt-2 w-56 rounded border border-gray-200 bg-white py-1 shadow-lg" role="menu">
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
      <section aria-labelledby="retry-feedback-title" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl" role="dialog" aria-modal="true">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900" id="retry-feedback-title">Retry with feedback</h2>
            <p className="mt-1 text-sm text-gray-500">This feedback will be added to the retry prompt.</p>
          </div>
          <button
            aria-label="Close retry with feedback"
            className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-700"
            disabled={command.isPending}
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <form className="mt-4 space-y-3" onSubmit={submit}>
          <label className="block text-sm font-medium text-gray-700" htmlFor="retry-feedback-text">
            Feedback
          </label>
          <textarea
            autoFocus
            className="min-h-36 w-full rounded border border-gray-300 px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
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

function TagsPanel({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const [tagName, setTagName] = useState("")

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    command.mutate({ method: "post", path: payload.paths.app_tags_path, body: { tag_name: tagName } }, { onSuccess: () => setTagName("") })
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <h2 className="text-sm font-semibold text-gray-900">Tags</h2>
          {payload.tags.length > 0 ? payload.tags.map((tag) => (
            <span className="inline-flex items-center gap-1 rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700" key={tag.id}>
              {tag.name}
              <button
                aria-label={`Remove ${tag.name}`}
                className="inline-flex h-4 w-4 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-red-600"
                disabled={command.isPending}
                onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_tags_path}/${tag.id}` })}
                title={`Remove ${tag.name}`}
                type="button"
              >
                <CloseIcon className="h-3 w-3" />
              </button>
            </span>
          )) : <span className="text-sm text-gray-400">No tags yet.</span>}
        </div>
        <form className="flex items-center gap-2" onSubmit={submit}>
          <input className="w-40 rounded border border-gray-300 px-2 py-1.5 text-sm" list="job-tag-options" onChange={(event) => setTagName(event.target.value)} placeholder="Add tag" required value={tagName} />
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
    <div className="flex overflow-x-auto border-b border-gray-200">
      {tabs.map((tab) => (
        <button
          className={`shrink-0 border-b-2 px-4 py-2 text-sm font-medium ${active === tab.id ? "border-blue-600 text-blue-600" : "border-transparent text-gray-500 hover:text-gray-800"}`}
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
        </PanelMessage>
      ) : null}
      {payload.job.landing_failure_reason ? <PanelMessage tone="error">Landing failed: {payload.job.landing_failure_reason}</PanelMessage> : null}
      {payload.unsatisfied_dependencies.length > 0 ? <UnsatisfiedDependencies command={command} payload={payload} /> : null}

      <section className="grid gap-4 rounded border border-gray-200 bg-white p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
        <KeyValue label="Priority"><SmallPill>{payload.job.priority}</SmallPill></KeyValue>
        <KeyValue label="Validity"><span className="capitalize">{payload.job.validity}</span></KeyValue>
        {payload.epic ? <KeyValue label="Epic"><EpicSummaryLink epic={payload.epic} prefix={prefix} /></KeyValue> : null}
        <KeyValue label="Branch"><code className="break-all">{payload.job.branch_name || "-"}</code></KeyValue>
        <KeyValue label="Stack base"><StackBaseForm command={command} payload={payload} /></KeyValue>
        <KeyValue label="Pull request"><PullRequestSummary payload={payload} /></KeyValue>
        <KeyValue label="Cost">{payload.job.total_cost_usd == null ? "-" : formatCurrency(payload.job.total_cost_usd)} <span className="text-xs text-gray-400">({payload.job.billed_runs_count} billed)</span></KeyValue>
        <KeyValue label="Started">{formatDate(payload.job.started_at)}</KeyValue>
        <KeyValue label="Closed">{payload.job.finished_at ? `${formatDate(payload.job.finished_at)} (${payload.job.closure_reason || "unspecified"})` : "still open"}</KeyValue>
      </section>

      <TagsPanel command={command} payload={payload} />

      <DependenciesPanel command={command} payload={payload} prefix={prefix} />

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-semibold text-gray-900">Issue</h2>
          {payload.job.issue_body ? <pre className="mt-2 whitespace-pre-wrap break-words text-sm text-gray-600">{payload.job.issue_body}</pre> : <p className="mt-2 text-sm text-gray-400">No issue body.</p>}
        </section>
        <section className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-semibold text-gray-900">Agent summary</h2>
          {payload.summary ? <p className="mt-2 whitespace-pre-wrap text-sm text-gray-700">{payload.summary.text}</p> : <p className="mt-2 text-sm text-gray-400">No summary yet.</p>}
        </section>
      </div>

      <TimelinePanel canView={payload.actions.can_view_timeline} jobId={payload.job.id} />
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

function UnsatisfiedDependencies({ payload, command }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  return (
    <section className="rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <span className="font-medium">Waiting on {payload.unsatisfied_dependencies.length} {plural(payload.unsatisfied_dependencies.length, "dependency")}.</span>
          <span className="ml-2">{payload.unsatisfied_dependencies.map(dependencyLabel).join(", ")}</span>
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
      <select className="rounded border border-gray-300 bg-white px-2 py-1 text-xs" onChange={(event) => setStackBase(event.target.value)} value={stackBase}>
        <option value="auto">auto</option>
        <option value="main">main</option>
      </select>
      <button className="text-xs text-blue-600 hover:underline" disabled={command.isPending} type="submit">Update</button>
    </form>
  )
}

function PullRequestSummary({ payload }: { payload: JobDetailPayload }) {
  if (!payload.job.pr_number && !payload.job.external_pr_number) return <span className="text-gray-400">-</span>

  return (
    <div className="space-y-1">
      {payload.job.pr_number ? <a className="text-blue-600 hover:underline" href={payload.job.pr_url || "#"} rel="noopener" target="_blank">Syrus PR #{payload.job.pr_number}</a> : null}
      {payload.job.external_pr_number ? <a className="block text-violet-700 hover:underline" href={payload.job.external_pr_url || "#"} rel="noopener" target="_blank">External PR #{payload.job.external_pr_number}</a> : null}
      <div><MergeablePill value={payload.job.pr_mergeable} /> {payload.job.pr_mergeable_checked_at ? <span className="text-xs text-gray-400">checked {formatDate(payload.job.pr_mergeable_checked_at)}</span> : null}</div>
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
      <div className="rounded border border-gray-200 bg-white p-4 text-sm">
        <h2 className="font-semibold text-gray-900">Dependencies</h2>
        {payload.dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100">
            {payload.dependencies.map((dependency) => (
              <li className="flex flex-wrap items-center justify-between gap-2 py-2" key={dependency.id}>
                <span>{dependencyLabel(dependency)} <span className="text-xs text-gray-400">({dependency.source})</span></span>
                {dependency.manual ? <button className="text-xs text-red-600 hover:underline" disabled={command.isPending} onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_dependencies_path}/${dependency.id}`, confirm: "Remove this dependency?" })} type="button">Remove</button> : null}
              </li>
            ))}
          </ul>
        ) : <p className="mt-2 text-gray-400">No dependencies.</p>}
        <form className="mt-3 flex flex-wrap items-end gap-2 border-t border-gray-100 pt-3" onSubmit={submit}>
          <label className="min-w-0 flex-1 text-xs font-medium uppercase text-gray-500">
            Dependency
            <select className="mt-1 w-full min-w-64 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700" onChange={(event) => setTarget(event.target.value)} required value={target}>
              <option value="">Select a Job or issue</option>
              {payload.dependency_target_options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <button className={buttonClass("secondary")} disabled={command.isPending} type="submit">Add</button>
        </form>
      </div>
      <div className="rounded border border-gray-200 bg-white p-4 text-sm">
        <h2 className="font-semibold text-gray-900">{payload.dependents.length} other {plural(payload.dependents.length, "Job")} depend on this one</h2>
        {payload.dependents.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100">
            {payload.dependents.map((dependent) => (
              <li className="py-2" key={dependent.id}>
                <Link className="text-blue-600 hover:underline" to={withRoutePrefix(dependent.job.job_path, prefix)}>{dependent.job.repository_slug} {dependent.job.issue_number ? `#${dependent.job.issue_number}` : `Job #${dependent.job.id}`}</Link>
                <StatusPill state={dependent.job.summary_state} />
              </li>
            ))}
          </ul>
        ) : <p className="mt-2 text-gray-400">No dependent Jobs.</p>}
      </div>
    </section>
  )
}

function TimelinePanel({ canView, jobId }: { canView: boolean; jobId: number }) {
  const [expanded, setExpanded] = useState(false)
  const timeline = useQuery({
    queryKey: ["jobs", String(jobId), "timeline"],
    queryFn: () => fetchJobTimeline(String(jobId)),
    enabled: canView && expanded
  })

  if (!canView) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900">Timeline</h2>
        <button
          aria-expanded={expanded}
          className="rounded border border-gray-300 px-3 py-1 text-sm font-medium text-gray-700 hover:bg-gray-50"
          onClick={() => setExpanded((value) => !value)}
          type="button"
        >
          {expanded ? "Hide timeline" : "Show timeline"}
        </button>
      </div>
      {expanded && timeline.isPending ? <p className="mt-2 text-sm text-gray-400">Loading timeline...</p> : null}
      {expanded && timeline.isError ? <p className="mt-2 text-sm text-red-700">{errorMessage(timeline.error || new Error("Timeline failed."), "Unable to load timeline.")}</p> : null}
      {expanded && timeline.data && timeline.data.events.length > 0 ? (
        <ol className="mt-3 space-y-3">
          {timeline.data.events.map((event, index) => (
            <li className="border-l border-gray-200 pl-3 text-sm" key={`${event.at}-${event.title}-${index}`}>
              <div className="font-medium text-gray-900">{event.title}</div>
              <div className="text-xs text-gray-500">{formatDate(event.at)} · {event.source}{event.ref ? ` · ${event.ref}` : ""}</div>
              {event.detail ? <div className="mt-1 text-gray-600">{event.detail}</div> : null}
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
    <section className="rounded border border-gray-200 bg-white p-4">
      <h2 className="text-sm font-semibold text-gray-900">Attachments</h2>
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
      {payload.workflows.map((workflow) => <WorkflowCard command={command} key={workflow.id} payload={payload} workflow={workflow} />)}
      <WorkflowsPagination payload={payload} prefix={prefix} />
    </div>
  )
}

function WorkflowsPagination({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const pagination = payload.workflows_pagination
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label="Workflow pagination" className="flex items-center justify-between text-sm text-gray-600">
      <span>Showing {pagination.first_item}-{pagination.last_item} of {pagination.total_workflows}</span>
      <div className="flex gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>Previous</Link> : <span className={disabledPaginationClass()}>Previous</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>Next</Link> : <span className={disabledPaginationClass()}>Next</span>}
      </div>
    </nav>
  )
}

function WorkflowCard({ workflow, payload, command }: { workflow: JobWorkflow; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const stepItems = workflowStepItems(workflow.steps)

  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-gray-900">Workflow #{workflow.id}</h2>
          <p className="text-xs text-gray-500">{workflow.trigger_kind} · {workflow.agent_provider || "default agent"} · created {formatDate(workflow.created_at)}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {workflow.state === "running" ? null : <StatusPill state={workflow.state} />}
          {workflow.retry_available ? <CommandButton command={command} input={{ method: "post", path: workflow.app_retry_step_path }} tone="secondary">Retry failed step</CommandButton> : null}
          {workflow.state === "failed" && !workflow.cleaned_up_at ? <CommandButton command={command} input={{ method: "post", path: workflow.app_push_commits_path }} tone="secondary">Push commits</CommandButton> : null}
        </div>
      </div>
      <div className="mt-4 overflow-hidden rounded border border-gray-200">
        {stepItems.map((item) => item.type === "loop" ? (
          <LoopGroup command={command} item={item} key={item.loopId} payload={payload} />
        ) : (
          <StepCard command={command} key={item.step.id} numberLabel={item.step.position + 1} payload={payload} step={item.step} />
        ))}
      </div>
    </section>
  )
}

function LoopGroup({ item, payload, command }: { item: LoopStepItem; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand> }) {
  const [open, setOpen] = useState(false)
  const status = loopDisplayStatus(item)

  return (
    <section className="border-b border-gray-200 last:border-b-0">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 bg-violet-50 px-3 py-2 text-left hover:bg-violet-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="font-medium text-gray-900">{loopDisplayName(item)}</span>
          <SmallPill>{item.iterations.length} {plural(item.iterations.length, "iteration")}</SmallPill>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {status ? <StatusPill state={status} /> : null}
          <span aria-hidden="true" className="text-gray-400">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="space-y-3 border-t border-violet-100 bg-white p-3">
          {item.iterations.map((iteration) => (
            <section className="overflow-hidden rounded border border-gray-200" key={iteration.iteration}>
              <div className="border-b border-gray-200 bg-gray-50 px-3 py-2 text-xs font-semibold uppercase text-gray-500">
                Iteration {iteration.iteration}
              </div>
              {iteration.steps.map((step, index) => (
                <StepCard command={command} key={step.id} numberLabel={index + 1} payload={payload} step={step} />
              ))}
            </section>
          ))}
        </div>
      ) : null}
    </section>
  )
}

function StepCard({ step, payload, command, numberLabel }: { step: JobStep; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; numberLabel: number }) {
  const [open, setOpen] = useState(false)
  const runs = sortedRunsNewestFirst(step.runs)
  const activeRun = runs.find((run) => isActiveState(run.state))
  const displayStatus = activeRun ? activeRun.state : step.display_status

  return (
    <div className="border-b border-gray-200 bg-white last:border-b-0">
      <button
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-gray-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <span className="flex min-w-0 items-center gap-2">
          <span className="w-6 shrink-0 text-right font-mono text-xs text-gray-400">{numberLabel}.</span>
          <span className="truncate text-sm font-medium text-gray-900">{step.display_name}</span>
        </span>
        <span className="flex shrink-0 items-center gap-2">
          {displayStatus ? <StatusPill state={displayStatus} /> : null}
          <span aria-hidden="true" className="text-gray-400">{open ? "−" : "+"}</span>
        </span>
      </button>
      {open ? (
        <div className="border-t border-gray-100 bg-gray-50 p-3">
          <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500">
            <span>{step.kind}</span>
            {step.loop_id ? <span>iteration {step.iteration ?? 1}</span> : null}
            {activeRun && step.state !== activeRun.state ? <SmallPill>step {step.state.replaceAll("_", " ")}</SmallPill> : null}
            {step.latest ? <SmallPill>latest</SmallPill> : null}
            <span>{formatDate(step.started_at || step.created_at)}</span>
          </div>
          {activeRun ? (
            <div className="mt-2 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-xs text-blue-800">
              <span className="font-semibold">Active run #{activeRun.id}</span>
              <span> is {activeRun.state.replaceAll("_", " ")}</span>
              <span> since {formatDate(activeRun.started_at || activeRun.created_at)}</span>
            </div>
          ) : null}
          {step.details ? <pre className="mt-2 overflow-x-auto rounded bg-white p-2 text-xs text-gray-600">{stringify(step.details)}</pre> : null}
          {runs.length > 0 ? (
            <div className="mt-3 space-y-2">
              {runs.map((run) => <RunRow active={activeRun?.id === run.id} command={command} key={run.id} payload={payload} run={run} />)}
            </div>
          ) : <p className="mt-2 text-xs text-gray-400">No runs for this step.</p>}
        </div>
      ) : null}
    </div>
  )
}

function RunRow({ run, payload, command, active = false }: { run: JobRun; payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; active?: boolean }) {
  const [gradeLogOpen, setGradeLogOpen] = useState(false)
  const [artifactView, setArtifactView] = useState<"transcript" | "diff" | null>(null)
  const gradeLog = useMutation({
    mutationFn: (path: string) => fetchJobGradeLog(path),
    onSuccess: () => setGradeLogOpen(true)
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

  return (
    <div className={`rounded border bg-white p-3 text-sm ${active ? "border-blue-300 ring-1 ring-blue-100" : "border-gray-200"}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium text-gray-900">Run #{run.id}</span>
            <StatusPill state={run.state} />
            {run.rate_limited ? <SmallPill>rate limited</SmallPill> : null}
          </div>
          <p className="mt-1 text-xs text-gray-500">
            {run.agent_provider || "agent"} · {run.agent_turns ?? 0} {plural(run.agent_turns ?? 0, "turn")} · {run.job_log_count} log {plural(run.job_log_count, "line")} · {formatCurrency(run.cost_usd || 0)}
          </p>
          {run.agent_summary ? <p className="mt-2 whitespace-pre-wrap text-gray-700">{run.agent_summary}</p> : null}
          {run.health_snapshots.at(-1) ? <p className="mt-2 text-xs text-gray-500">Health: {run.health_snapshots.at(-1)?.health_status || "unknown"} {run.health_snapshots.at(-1)?.hint ? `- ${run.health_snapshots.at(-1)?.hint}` : ""}</p> : null}
          {run.run_diagnostic?.present ? <p className="mt-1 text-xs text-amber-700">Diagnostic captured {formatDate(run.run_diagnostic.created_at)}{run.run_diagnostic.error_message ? `: ${run.run_diagnostic.error_message}` : ""}</p> : null}
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
            <button className={buttonClass("secondary")} disabled={gradeLog.isPending} onClick={() => gradeLog.mutate(run.app_grade_log_path!)} type="button">
              {gradeLog.isPending ? "Loading log..." : "Grade log"}
            </button>
          ) : null}
        </div>
      </div>
      {artifacts.isError ? <p className="mt-3 text-xs text-red-700">{errorMessage(artifacts.error, "Unable to load run artifacts.")}</p> : null}
      {artifactView && artifacts.data ? <RunArtifactsPanel payload={artifacts.data} view={artifactView} /> : null}
      {gradeLog.isError ? <p className="mt-3 text-xs text-red-700">{errorMessage(gradeLog.error, "Grade log failed.")}</p> : null}
      {gradeLogOpen && gradeLog.data ? (
        <section className="mt-3 rounded border border-gray-200 bg-gray-50">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-gray-200 px-3 py-2">
            <h4 className="text-xs font-semibold uppercase text-gray-500">{gradeLog.data.name || `Run #${gradeLog.data.run_id}`} grade log</h4>
            <button className="text-xs text-gray-500 underline hover:text-gray-700" onClick={() => setGradeLogOpen(false)} type="button">Hide</button>
          </div>
          <pre className="max-h-96 overflow-auto p-3 font-mono text-xs text-gray-800 whitespace-pre-wrap">{gradeLog.data.contents}</pre>
        </section>
      ) : null}
    </div>
  )
}

function RunArtifactsPanel({ payload, view }: { payload: Awaited<ReturnType<typeof fetchJobRunArtifacts>>; view: "transcript" | "diff" }) {
  if (view === "diff") {
    return (
      <section className="mt-3 rounded border border-gray-200 bg-gray-50">
        <h4 className="border-b border-gray-200 px-3 py-2 text-xs font-semibold uppercase text-gray-500">Agent diff</h4>
        {payload.agent_diff ? (
          <pre className="max-h-[32rem] overflow-auto p-3 font-mono text-xs text-gray-800 whitespace-pre-wrap">{payload.agent_diff}</pre>
        ) : <p className="p-3 text-sm text-gray-400">No diff captured for this run.</p>}
      </section>
    )
  }

  return (
    <section className="mt-3 rounded border border-gray-200 bg-gray-50">
      <h4 className="border-b border-gray-200 px-3 py-2 text-xs font-semibold uppercase text-gray-500">Transcript</h4>
      {payload.logs.length > 0 ? (
        <ol className="max-h-[32rem] overflow-auto divide-y divide-gray-200">
          {payload.logs.map((log) => (
            <li className="grid gap-2 px-3 py-2 font-mono text-xs text-gray-800 sm:grid-cols-[5rem_minmax(0,1fr)]" key={log.id}>
              <span className="text-gray-400">{transcriptLogKindLabel(log.kind) || `#${log.sequence}`}</span>
              <pre className="whitespace-pre-wrap break-words">{log.chunk}</pre>
            </li>
          ))}
        </ol>
      ) : <p className="p-3 text-sm text-gray-400">No transcript rows captured for this run.</p>}
    </section>
  )
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
      <form className="rounded border border-gray-200 bg-white p-4" onSubmit={submit}>
        <h2 className="text-sm font-semibold text-gray-900">Add attachment</h2>
        <div className="mt-3 grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] md:items-end">
          <label className="text-sm font-medium text-gray-700">
            Files
            <input className="mt-1 block w-full text-sm" multiple onChange={(event) => setFiles(Array.from(event.target.files || []))} type="file" />
          </label>
          <label className="text-sm font-medium text-gray-700">
            Google Doc URL
            <input className="mt-1 w-full rounded border border-gray-300 px-2 py-1.5 text-sm" onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/..." type="url" value={googleDocUrl} />
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
              <button className="absolute right-2 top-2 rounded border border-red-200 bg-white px-2 py-1 text-xs text-red-700 hover:bg-red-50" disabled={remove.isPending} onClick={() => remove.mutate(attachment.app_delete_path)} type="button">Remove</button>
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
    <article className="rounded border border-gray-200 bg-white p-3 text-sm">
      <div className="font-medium text-gray-900">{attachment.file_path ? <a className="hover:underline" href={attachment.file_path}>{title}</a> : title}</div>
      <div className="mt-1 text-xs text-gray-500">
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
        <label className="text-sm text-gray-600">
          Viewing
          <select className="ml-2 rounded border border-gray-300 bg-white px-2 py-1 text-sm" onChange={(event) => onSelectRef(event.target.value)} value={payload.selected_ref}>
            {refOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </label>
        {payload.tree_truncated ? <span className="text-xs text-amber-700">Tree truncated by GitHub.</span> : null}
      </div>
      <div className="grid min-h-[36rem] overflow-hidden rounded border border-gray-200 bg-white lg:grid-cols-[20rem_minmax(0,1fr)]">
        <div className="max-h-[36rem] overflow-auto border-b border-gray-200 bg-gray-50 lg:border-b-0 lg:border-r">
          {tree.length > 0 ? tree.map((node) => (
            <SourceTreeRow
              expandedPaths={expandedPaths}
              key={node.path}
              node={node}
              onSelectPath={onSelectPath}
              onToggleDirectory={toggleDirectory}
              selectedPath={payload.selected_path}
            />
          )) : <p className="p-4 text-sm text-gray-400">No files found.</p>}
          {payload.tree_items.length > visibleItems.length ? <p className="p-3 text-xs text-amber-700">Showing first {visibleItems.length.toLocaleString()} files.</p> : null}
        </div>
        <div className="min-w-0 overflow-auto">
          {payload.file_error ? <p className="p-4 text-sm text-red-700">{payload.file_error}</p> : null}
          {payload.file ? (
            <>
              <div className="sticky top-0 flex items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 font-mono text-xs text-gray-600">
                <span className="min-w-0 flex-1 truncate">{payload.file.path}</span>
                <span>{payload.file.language}</span>
                <span>{formatBytes(payload.file.size)}</span>
              </div>
              <pre className="m-0 overflow-x-auto p-4 text-sm leading-relaxed"><code>{payload.file.content}</code></pre>
            </>
          ) : <div className="flex h-full min-h-[20rem] items-center justify-center p-4 text-sm text-gray-400">Select a file to view its contents.</div>}
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
          className={`block w-full truncate py-1.5 pr-3 text-left font-mono text-xs hover:bg-blue-50 ${selectedPath === node.path ? "bg-blue-100 text-blue-700" : "text-gray-700"}`}
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
          className="block w-full truncate py-1.5 pr-3 text-left font-mono text-xs font-semibold text-gray-700 hover:bg-blue-50"
          onClick={() => onToggleDirectory(node.path)}
          style={{ paddingLeft: `${0.75 + Math.max(node.path.split("/").length - 1, 0) * 0.75}rem` }}
          title={node.path}
          type="button"
        >
          <span className="mr-1 inline-block w-3 text-gray-400">{expandedPaths.has(node.path) ? "-" : "+"}</span>
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
      <div className="text-xs font-medium uppercase text-gray-500">{label}</div>
      <div className="mt-1 text-gray-800">{children}</div>
    </div>
  )
}

function MergeablePill({ value }: { value: boolean | null }) {
  if (value === true) return <StatusPill state="mergeable" />
  if (value === false) return <StatusPill state="unmergeable" />
  return <StatusPill state="unknown" />
}

function SmallPill({ children }: { children: ReactNode }) {
  return <span className="inline-flex items-center rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600">{children}</span>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function buttonClass(tone: ButtonTone) {
  const base = "inline-flex items-center rounded px-3 py-1.5 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50"
  const tones = {
    primary: "bg-blue-600 text-white hover:bg-blue-500",
    secondary: "border border-gray-300 bg-white text-gray-700 hover:bg-gray-50",
    success: "bg-emerald-600 text-white hover:bg-emerald-500",
    danger: "bg-amber-600 text-white hover:bg-amber-500"
  }
  return `${base} ${tones[tone]}`
}

function menuButtonClass(tone: ButtonTone) {
  const tones = {
    primary: "text-blue-700 hover:bg-blue-50",
    secondary: "text-gray-700 hover:bg-gray-50",
    success: "text-emerald-700 hover:bg-emerald-50",
    danger: "text-amber-700 hover:bg-amber-50"
  }
  return `block w-full px-4 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-50 ${tones[tone]}`
}

function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 hover:bg-gray-50"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-300"
}

function jobSourceLabel(payload: JobDetailPayload) {
  if (payload.job.issue_number) return `#${payload.job.issue_number}`
  if (payload.job.kind === "direct") return "Direct Job"
  if (payload.job.kind === "cron") return "Scheduled Job"
  return `Job #${payload.job.id}`
}

function dependencyLabel(dependency: JobDependency) {
  if (dependency.pending) return dependency.unresolved_slug || "Unresolved dependency"
  const target = dependency.depends_on_job
  if (!target) return dependency.unresolved_slug || "Missing dependency"
  const issue = target.issue_number ? `#${target.issue_number}` : `Job #${target.id}`
  return `${target.repository_slug} ${issue} (${target.summary_state})`
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
  | { type: "step"; step: JobStep }
  | LoopStepItem

type LoopStepItem = {
  type: "loop"
  loopId: string
  iterations: Array<{ iteration: number; steps: JobStep[] }>
}

function workflowStepItems(steps: JobStep[]): WorkflowStepItem[] {
  const items: WorkflowStepItem[] = []
  const consumedLoopIds = new Set<string>()

  for (const step of steps) {
    if (!step.loop_id) {
      items.push({ type: "step", step })
      continue
    }

    if (consumedLoopIds.has(step.loop_id)) continue
    consumedLoopIds.add(step.loop_id)

    const loopSteps = steps.filter((candidate) => candidate.loop_id === step.loop_id)
    const iterations = loopIterations(loopSteps)
    if (iterations.length <= 1) {
      loopSteps.forEach((loopStep) => items.push({ type: "step", step: loopStep }))
      continue
    }

    items.push({ type: "loop", loopId: step.loop_id, iterations })
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
      steps: iterationSteps.sort((left, right) => left.position - right.position)
    }))
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

function stringify(value: unknown) {
  return typeof value === "string" ? value : JSON.stringify(value, null, 2)
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
