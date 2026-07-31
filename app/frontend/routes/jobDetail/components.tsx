import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { formatRelativeDate } from "../../lib/relativeTime"
import { useQuery } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { CloseIcon } from "../../components/CloseIcon"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { StatusPill } from "../../components/StatusPill"
import { buttonClass } from "../../lib/buttonClasses"
import { errorMessage } from "../../lib/errorMessage"
import { formatBytes } from "../../lib/format"
import { fetchJobTimeline, type JobAttachment, type JobDependency, type JobDetailPayload } from "../../api/jobs"
import { useJobCommand } from "./command"
import { jobSlug } from "./formatting"
import type { ReactNode, UIEvent } from "react"
import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { AnsiText } from "../../components/AnsiText"
import type { JobRun, fetchJobRunArtifacts } from "../../api/jobs"
import { useT } from "../../hooks/useT"
import type { LineAnnotation } from "./diffRendering"
import { diffCoverageBorderClass, diffGutterClass, diffLineClass, diffMarkerClass, parseUnifiedDiff } from "./diffRendering"
import { withRoutePrefix } from "./formatting"
import { formatElapsed, humanize } from "./stepModel"
import { coalesceTranscriptLogs, isRunTranscriptAtBottom, scrollRunTranscriptToBottom } from "./transcript"

// Shared presentational micro-components extracted from JobDetail.tsx: the small
// pill/panel primitives, the live-elapsed hook, the active/queued Run banner, and
// the run-transcript log stream. Kept in a leaf module so both the route file and
// the workflow/step/run render subtree can import them without a circular edge.

export function AgentDiff({ diff, annotations }: { diff: string; annotations?: Record<string, LineAnnotation> }) {
  const lines = parseUnifiedDiff(diff)

  return (
    <div className="max-h-[32rem] overflow-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950" data-testid="agent-diff-viewer">
      <table className="min-w-full border-separate border-spacing-0">
        <tbody>
          {lines.map((line, index) => {
            const annotation = annotations && line.newLine != null ? annotations[String(line.newLine)] : undefined
            return (
              <tr
                className={diffLineClass(line.kind)}
                data-coverage={annotation}
                data-diff-kind={line.kind}
                key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}
              >
                <td className={diffGutterClass(line.kind)}>{line.oldLine ?? ""}</td>
                <td className={diffGutterClass(line.kind)}>{line.newLine ?? ""}</td>
                <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
                <td className={`min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200 ${diffCoverageBorderClass(annotation)}`}>{line.code || " "}</td>
                <td className="w-4 select-none px-1 text-center">
                  {annotation === "covered" ? <span className="text-emerald-600 dark:text-emerald-400">✓</span>
                    : annotation === "uncovered" ? <span className="text-red-600 dark:text-red-400">✗</span>
                    : null}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

export function SmallPill({ children }: { children: ReactNode }) {
  return <span className="inline-flex items-center rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{children}</span>
}

export function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

// Live wall-clock, ticking every second while `active`. Used so a
// queued/running Run's elapsed time updates in place.
export function useNow(active: boolean) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return undefined
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [active])
  return now
}

// A queued Run hasn't started_at yet — it's waiting for a free worker in
// the SolidQueue pool, NOT "starting the agent". Surface that honestly
// (with how long it's been waiting) so a capacity wait doesn't read as a
// hung job; a running Run shows how long it's been going.
export function ActiveRunBanner({ run }: { run: JobRun }) {
  const { t } = useT("jobs")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const queued = run.state === "queued" || !run.started_at
  const now = useNow(true)
  const sinceIso = queued ? run.created_at : run.started_at
  const elapsed = sinceIso ? formatElapsed((now - new Date(sinceIso).getTime()) / 1000) : null
  const activeProcess = run.active_process
  const budgetParts: string[] = []
  if (activeProcess?.wall_timeout_s) {
    budgetParts.push(t("run_active_process_wall_budget", { duration: formatElapsed(activeProcess.wall_timeout_s) }))
  }
  if (activeProcess?.silent_timeout_s) {
    budgetParts.push(t("run_active_process_silent_budget", { duration: formatElapsed(activeProcess.silent_timeout_s) }))
  }

  if (queued) {
    return (
      <div className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-200">
        <span className="font-semibold">{t("run_queued_waiting", { id: run.id })}{elapsed ? ` · ${t("run_queued_suffix", { elapsed })}` : ""}</span>
        <span className="mt-1 block text-amber-700 dark:text-amber-300">
          {t("run_queued_backlog")}{" "}
          <Link className="underline hover:text-amber-900 dark:hover:text-amber-100" to={withRoutePrefix("/admin/queue/pending", prefix)}>{t("run_queued_backlog_link")}</Link> {t("run_queued_backlog_suffix")}
        </span>
      </div>
    )
  }

  return (
    <div className="mt-2 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-xs text-blue-800 dark:border-blue-900/70 dark:bg-blue-950/40 dark:text-blue-200">
      <span className="font-semibold">{t("run_running", { id: run.id })}{elapsed ? ` · ${elapsed}` : ""}</span>
      <span> {t("run_running_suffix", { date: run.started_at ? formatRelativeDate(new Date(run.started_at)) : "-" })}</span>
      {activeProcess ? (
        <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-blue-700 dark:text-blue-300">
          <span>{t("run_active_process", { kind: humanize(activeProcess.kind) })}</span>
          <code className="max-w-full truncate rounded bg-white/75 px-1.5 py-0.5 font-mono text-[11px] text-blue-950 dark:bg-blue-900/40 dark:text-blue-100">
            {activeProcess.command || t("run_active_process_unknown_command")}
          </code>
          {budgetParts.length > 0 ? <span>{t("run_active_process_budget", { budget: budgetParts.join(" · ") })}</span> : null}
        </div>
      ) : null}
    </div>
  )
}

function transcriptLogKindLabel(kind: string | null | undefined, t: ReturnType<typeof useT>["t"]) {
  if (kind === "assistant_text") return t("transcript_kind_agent")
  if (kind === "tool_call") return t("transcript_kind_tool")
  if (kind === "system") return t("transcript_kind_system")
  return kind
}

export function RunTranscriptLogs({ logs }: { logs: Awaited<ReturnType<typeof fetchJobRunArtifacts>>["logs"] }) {
  const { t } = useT("jobs")
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
          <span className="text-gray-400 dark:text-gray-500">{transcriptLogKindLabel(log.kind, t) || `#${log.sequence}`}</span>
          <pre className="whitespace-pre-wrap break-words"><AnsiText text={log.chunk} /></pre>
        </li>
      ))}
    </ol>
  )
}

export function TagsPanel({ payload, command, embedded = false, canManageTags }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; embedded?: boolean; canManageTags: boolean }) {
  const { t } = useT("jobs")
  const [tagName, setTagName] = useState("")
  const [addingTag, setAddingTag] = useState(false)

  if (payload.tags.length === 0 && !canManageTags) return null

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    command.mutate(
      { method: "post", path: payload.paths.app_tags_path, body: { tag_name: tagName } },
      { onSuccess: () => { setTagName(""); setAddingTag(false) } }
    )
  }

  const content = (
    <div className="space-y-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_tags")}</h2>
        {payload.tags.map((tag) => (
          <span className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-700 dark:bg-gray-800 dark:text-gray-200" key={tag.id}>
            {tag.name}
            {canManageTags ? (
              <button
                aria-label={t("tags_remove_aria", { name: tag.name })}
                className="inline-flex h-4 w-4 items-center justify-center rounded text-gray-400 hover:bg-gray-200 hover:text-red-600 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-red-300"
                disabled={command.isPending}
                onClick={() => command.mutate({ method: "delete", path: `${payload.paths.app_tags_path}/${tag.id}` })}
                title={t("tags_remove_aria", { name: tag.name })}
                type="button"
              >
                <CloseIcon className="h-3 w-3" />
              </button>
            ) : null}
          </span>
        ))}
      </div>
      {canManageTags ? (
        addingTag ? (
          <form className="flex items-center gap-2" onSubmit={submit}>
            <input className="w-40 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100" list="job-tag-options" onChange={(event) => setTagName(event.target.value)} placeholder={t("tags_placeholder")} required value={tagName} />
            <datalist id="job-tag-options">
              {payload.tag_options.map((tag) => <option key={tag.id} value={tag.name} />)}
            </datalist>
            <button className={buttonClass("secondary")} disabled={command.isPending} type="submit">{t("tags_add")}</button>
            <button className="text-xs text-gray-500 hover:underline disabled:cursor-not-allowed disabled:opacity-50" disabled={command.isPending} onClick={() => setAddingTag(false)} type="button">{t("tags_cancel")}</button>
          </form>
        ) : (
          <button className="text-xs font-medium text-blue-600 hover:underline" onClick={() => setAddingTag(true)} type="button">{t("tags_add_tag")}</button>
        )
      ) : null}
    </div>
  )

  if (embedded) {
    return (
      <div className="mt-3 border-t border-gray-100 pt-3 dark:border-gray-800">
        {content}
      </div>
    )
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      {content}
    </section>
  )
}

export function NeedsAttentionBanner({ job }: { job: JobDetailPayload["job"] }) {
  const { t } = useT("jobs")
  if (!job.needs_attention) return null

  const reasonKeys: Record<string, string> = {
    fork_pr_closed: "attention_fork_pr_closed",
    fork_pr_changes_requested: "attention_fork_pr_changes_requested",
    upstream_pr_closed: "attention_upstream_pr_closed",
    upstream_pr_changes_requested: "attention_upstream_pr_changes_requested"
  }

  const message = job.needs_attention_reason
    ? (reasonKeys[job.needs_attention_reason]
        ? t(reasonKeys[job.needs_attention_reason])
        : t("attention_reason_fallback", { reason: job.needs_attention_reason }))
    : t("attention_generic")

  const gracePeriodText = job.grace_period_expires_at ? (() => {
    const expires = new Date(job.grace_period_expires_at)
    const now = new Date()
    const ms = expires.getTime() - now.getTime()
    if (ms <= 0) return t("grace_expired")
    const totalSeconds = Math.floor(ms / 1000)
    const days = Math.floor(totalSeconds / 86400)
    const hours = Math.floor((totalSeconds % 86400) / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    if (days > 0) return t("grace_cleanup_days", { days, hours })
    if (hours > 0) return t("grace_cleanup_hours", { hours, minutes })
    return t("grace_cleanup_minutes", { minutes })
  })() : null

  return (
    <div className="rounded border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
      <p className="font-medium">{t("action_needed")}</p>
      <p className="mt-1">{message}</p>
      {gracePeriodText ? <p className="mt-1 text-amber-700 dark:text-amber-300">{gracePeriodText}</p> : null}
    </div>
  )
}

export function FeedbackSourceBadge({ source }: { source: unknown }) {
  if (!source || typeof source !== "object") return null

  const s = source as Record<string, unknown>
  const attributedTo = typeof s.attributed_to === "string" ? s.attributed_to : null
  const githubHandle = typeof s.github_handle === "string" ? s.github_handle : null
  const action = typeof s.action === "string" ? s.action : null
  const confirmedBy = typeof s.confirmed_by === "string" ? s.confirmed_by : null

  if (!attributedTo && !githubHandle) return null

  const label = [
    githubHandle ? `@${githubHandle}` : null,
    attributedTo,
    confirmedBy ? `confirmed by ${confirmedBy}` : null,
    action === "replace" ? "(replaced)" : null
  ].filter(Boolean).join(" · ")

  return (
    <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{label}</p>
  )
}

export function EpicSummaryLink({ epic, prefix }: { epic: NonNullable<JobDetailPayload["epic"]>; prefix: string }) {
  return (
    <Link className="text-blue-600 hover:underline" to={withRoutePrefix(epic.epic_path, prefix)}>
      {epic.display_number} {epic.title}
    </Link>
  )
}

export function TimelinePanel({ canView, jobId, prefix, runsCount }: { canView: boolean; jobId: number; prefix: string; runsCount: number }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const timeline = useQuery({
    queryKey: ["jobs", String(jobId), "timeline"],
    queryFn: () => fetchJobTimeline(String(jobId)),
    enabled: canView && expanded
  })

  if (!canView) return null

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900" data-tour="job-timeline">
      <button
        aria-expanded={expanded}
        className="flex w-full items-center gap-2 p-4 text-left text-sm font-semibold text-gray-900 hover:bg-gray-50 dark:text-gray-100 dark:hover:bg-gray-800"
        onClick={() => setExpanded((value) => !value)}
        type="button"
      >
        <svg aria-hidden="true" className={`h-3 w-3 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`} fill="currentColor" viewBox="0 0 20 20">
          <path clipRule="evenodd" d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.17 10 7.23 6.29a.75.75 0 0 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z" fillRule="evenodd" />
        </svg>
        {t("section_timeline")} <span className="font-normal text-gray-500 dark:text-gray-400">{t("timeline_runs", { count: runsCount })}</span>
      </button>
      {expanded ? (
        <div className="border-t border-gray-100 px-4 pb-4 dark:border-gray-800">
          {timeline.isPending ? <p className="mt-3 text-sm text-gray-400 dark:text-gray-500">{t("timeline_loading")}</p> : null}
          {timeline.isError ? <p className="mt-3 text-sm text-red-700">{errorMessage(timeline.error || new Error("Timeline failed."), t("timeline_error"))}</p> : null}
          {timeline.data && timeline.data.events.length > 0 ? (
            <ol className="mt-3 space-y-3">
              {timeline.data.events.map((event, index) => (
                <li className="border-l border-gray-200 pl-3 text-sm dark:border-gray-700" key={`${event.at}-${event.title}-${index}`}>
                  <div className="font-medium text-gray-900 dark:text-gray-100">
                    {event.workflow_path ? (
                      <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(event.workflow_path, prefix)}>{event.title}</Link>
                    ) : event.title}
                  </div>
                  <div className="text-xs text-gray-500 dark:text-gray-400">
                    <RelativeTimestamp value={event.at} /> · {event.source}
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
        </div>
      ) : null}
    </section>
  )
}

export function AttachmentPreview({ attachments }: { attachments: JobAttachment[] }) {
  const { t } = useT("jobs")
  if (!attachments || attachments.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_attachments")}</h2>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {attachments.slice(0, 6).map((attachment) => <AttachmentCard attachment={attachment} key={attachment.id} />)}
      </div>
    </section>
  )
}

export function AttachmentCard({ attachment }: { attachment: JobAttachment }) {
  const { t } = useT("jobs")
  const title = attachment.title || attachment.filename || attachment.google_doc_url || `Attachment #${attachment.id}`
  return (
    <article className="rounded border border-gray-200 bg-white p-3 text-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="font-medium text-gray-900 dark:text-gray-100">{attachment.file_path ? <a className="hover:underline" href={attachment.file_path}>{title}</a> : title}</div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {attachment.google_doc_url ? <a className="text-blue-600 hover:underline" href={attachment.google_doc_url} rel="noopener" target="_blank">{t("attachment_google_doc")}</a> : attachment.content_type || attachment.attachment_type}
        {attachment.byte_size ? ` · ${formatBytes(attachment.byte_size)}` : ""}
      </div>
    </article>
  )
}

export function MergeablePill({ value }: { value: boolean | null }) {
  if (value === true) return <StatusPill state="mergeable" />
  if (value === false) return <StatusPill state="unmergeable" />
  return <StatusPill state="unknown" />
}

export function JobStateBadge({ state }: { state: string }) {
  const normalized = state.toLowerCase()
  const isFail = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel")
  const isSuccess = normalized.includes("success") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed")
  const isActive = normalized.includes("running") || normalized.includes("queued")

  const colors = isFail
    ? "text-red-700 dark:text-red-300"
    : isSuccess
      ? "text-emerald-700 dark:text-emerald-300"
      : isActive
        ? "text-blue-700 dark:text-blue-300"
        : "text-gray-600 dark:text-gray-300"

  const dotColors = isFail
    ? "bg-red-500 dark:bg-red-400"
    : isSuccess
      ? "bg-emerald-500 dark:bg-emerald-400"
      : isActive
        ? "bg-blue-500 dark:bg-blue-400"
        : "bg-gray-400 dark:bg-gray-500"

  return (
    <span className={`inline-flex items-center gap-1.5 text-sm font-semibold ${colors}`}>
      <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${dotColors} ${isActive ? "animate-pulse" : ""}`} />
      <span className="capitalize">{state.replaceAll("_", " ")}</span>
    </span>
  )
}

export function PendingJobTitle({ pending, title }: { pending: boolean; title: string }) {
  const { t } = useT("jobs")
  if (!pending) return <>{title}</>

  return (
    <span className="inline-flex min-w-0 items-center gap-2 italic text-gray-500 dark:text-gray-400">
      <span aria-hidden="true" className="inline-block h-4 w-4 shrink-0 animate-spin rounded-full border-2 border-gray-300 border-t-gray-500 dark:border-gray-700 dark:border-t-gray-300" />
      <span>{t("generating_title")}</span>
    </span>
  )
}

export function JobSourceLink({ payload, prefix }: { payload: JobDetailPayload; prefix: string }) {
  const { t } = useT("jobs")
  const label = jobSourceLabel(payload, t)
  if (payload.job.scheduled_task) {
    return (
      <Link className="hover:underline" to={withRoutePrefix(payload.job.scheduled_task.scheduled_task_path, prefix)}>
        {label}
      </Link>
    )
  }
  if (!payload.job.issue_url) return <span>{label}</span>

  return (
    <a className="hover:underline" href={payload.job.issue_url} rel="noopener" target="_blank">
      {label}
    </a>
  )
}

export function jobSourceLabel(payload: JobDetailPayload, t: ReturnType<typeof useT>["t"]) {
  if (payload.job.issue_number) return `#${payload.job.issue_number}`
  if (payload.job.kind === "direct") return t("source_label_direct")
  if (payload.job.kind === "cron") return t("source_label_scheduled")
  return jobSlug(payload.job.id)
}

export function DependencyLink({ dependency, prefix }: { dependency: JobDependency; prefix: string }) {
  const { t } = useT("jobs")
  const epicTarget = dependency.depends_on_epic
  const jobTarget = dependency.depends_on_job
  const label = dependencyLabel(dependency, t)

  if (epicTarget) {
    return (
      <Link className="text-blue-700 underline hover:no-underline" to={withRoutePrefix(epicTarget.epic_path, prefix)}>{label}</Link>
    )
  }

  if (dependency.pending || !jobTarget) return <span>{label}</span>

  return (
    <SlugHoverCard id={jobTarget.id} kind="job">
      <Link className="text-blue-700 underline hover:no-underline" to={withRoutePrefix(jobTarget.job_path, prefix)}>{label}</Link>
    </SlugHoverCard>
  )
}

export function dependencyLabel(dependency: JobDependency, t: ReturnType<typeof useT>["t"]) {
  if (dependency.depends_on_epic) {
    const epic = dependency.depends_on_epic
    return `${epic.repository_slug} ${epic.display_number} — ${epic.title} (${epic.state.replace(/_/g, " ")})`
  }
  if (dependency.pending) return dependency.unresolved_slug || t("dependency_unresolved")
  const target = dependency.depends_on_job
  if (!target) return dependency.unresolved_slug || t("dependency_missing")
  return `${target.repository_slug} ${jobSlug(target.id)} (${target.summary_state})`
}
