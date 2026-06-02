import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Fragment, type ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import {
  archiveEpic,
  fetchEpicDetail,
  updateEpicState,
  type EpicDetailJob,
  type EpicDetailPayload,
  type EpicGraph,
  type EpicStateTransition
} from "../api/epics"
import { Markdown } from "../lib/Markdown"

let mermaidInitialized = false
let mermaidRenderSequence = 0

type EpicCommand =
  | { kind: "state"; transition: EpicStateTransition }
  | { kind: "archive" }

export function EpicDetailRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const prefix = routePrefix(location.pathname)
  const epic = useQuery({
    queryKey: ["epics", id],
    queryFn: () => fetchEpicDetail(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label="Epic" className="mx-auto max-w-6xl space-y-6 p-6">
      {epic.isPending ? <PanelMessage>Loading Epic...</PanelMessage> : null}
      {epic.isError ? <PanelMessage tone="error">{errorMessage(epic.error, "Unable to load Epic.")}</PanelMessage> : null}
      {epic.isSuccess ? <EpicDetail payload={epic.data} prefix={prefix} /> : null}
    </main>
  )
}

function EpicDetail({ payload, prefix }: { payload: EpicDetailPayload; prefix: string }) {
  const queryClient = useQueryClient()
  const queryKey = ["epics", String(payload.epic.id)] as const
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const command = useMutation({
    mutationFn: (action: EpicCommand) => {
      if (action.kind === "archive") return archiveEpic(payload.paths.app_archive_path)
      return updateEpicState(payload.paths.app_state_path, action.transition.target_state)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })

  function runTransition(transition: EpicStateTransition) {
    if (transition.confirm && !window.confirm(transition.confirm)) return
    command.mutate({ kind: "state", transition })
  }

  return (
    <>
      <header className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="break-words text-2xl font-bold text-gray-900">
            <span className="font-mono">{payload.epic.display_number}</span>
            <span className="px-2 text-gray-400">·</span>
            {payload.epic.title}
          </h1>
          <StatePill state={payload.epic.state} />
        </div>
        <p className="text-sm text-gray-500">
          <Link className="font-mono hover:underline" to={withRoutePrefix(payload.epic.repository.repository_path, prefix)}>{payload.epic.repository.slug}</Link>
          <span> · {payload.epic.jobs_count} {payload.epic.jobs_count === 1 ? "Job" : "Jobs"}</span>
          <span> · updated {formatRelative(payload.epic.updated_at)}</span>
        </p>

        {payload.state_transitions.length > 0 ? (
          <div className="flex flex-wrap items-center gap-2">
            {payload.state_transitions.map((transition) => (
              <Fragment key={transition.target_state}>
                {transition.target_state === "archived" && !payload.epic.archived ? (
                  <Link className={secondaryButton()} to={withRoutePrefix(payload.paths.edit_epic_path, prefix)}>Edit</Link>
                ) : null}
                <button
                  className={secondaryButton()}
                  disabled={command.isPending}
                  onClick={() => runTransition(transition)}
                  type="button"
                >
                  {transition.label}
                </button>
              </Fragment>
            ))}
          </div>
        ) : null}

        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">
            {payload.summary.done_jobs_count}/{payload.summary.total_jobs_count} done
          </span>
          <span className="rounded bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700">
            {payload.summary.dependency_edge_count} {payload.summary.dependency_edge_count === 1 ? "dep" : "deps"}
          </span>
          {payload.summary.blocked ? <span className="rounded bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800">Blocked</span> : null}
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Epic command failed.")}</PanelMessage> : null}

      <DependencyGraph graph={payload.graph} />

      {payload.epic.description.trim() ? (
        <section className="rounded border border-gray-200 bg-white p-4">
          <h2 className="font-semibold text-gray-900">Description</h2>
          <Markdown className="chat-prose mt-2 text-sm text-gray-700" text={payload.epic.description} />
        </section>
      ) : null}

      <JobsSection jobs={payload.jobs} prefix={prefix} />
    </>
  )
}

function DependencyGraph({ graph }: { graph: EpicGraph }) {
  if (graph.empty) return <p className="text-sm text-gray-500">No external dependencies</p>

  return (
    <details className="group rounded border border-gray-200 bg-white text-sm" open={graph.initially_open}>
      <summary className="flex cursor-pointer flex-wrap items-center justify-between gap-2 px-3 py-2 text-gray-700 hover:bg-gray-50">
        <span className="flex items-center gap-2">
          <span className="text-gray-400 transition-transform group-open:rotate-90">▶</span>
          <span className="font-medium">Dependency graph</span>
          <span className="text-gray-500">({graph.epic_dependency_count} {graph.epic_dependency_count === 1 ? "epic dep" : "epic deps"}, {graph.job_blocker_count} {graph.job_blocker_count === 1 ? "job blocker" : "job blockers"})</span>
        </span>
      </summary>
      <div className="border-t border-gray-100 p-3">
        <MermaidGraph definition={graph.definition} />
      </div>
    </details>
  )
}

function MermaidGraph({ definition }: { definition: string }) {
  const [svg, setSvg] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setSvg(null)
    setError(null)

    void import("mermaid")
      .then(async (module) => {
        const mermaid = module.default
        if (!mermaidInitialized) {
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "base" })
          mermaidInitialized = true
        }

        return mermaid.render(`epic-dependency-graph-${++mermaidRenderSequence}`, definition)
      })
      .then(({ svg: renderedSvg }) => {
        if (!cancelled) setSvg(renderedSvg)
      })
      .catch((caught: unknown) => {
        if (!cancelled) setError(`Dependency graph could not render: ${caught instanceof Error ? caught.message : String(caught)}`)
      })

    return () => {
      cancelled = true
    }
  }, [definition])

  return (
    <div className="overflow-x-auto rounded bg-gray-50 p-3">
      {error ? <p className="text-sm text-red-700">{error}</p> : null}
      {!error && !svg ? <p className="text-sm text-gray-500">Rendering dependency graph...</p> : null}
      {svg ? <div className="min-w-[28rem] text-center text-gray-700" dangerouslySetInnerHTML={{ __html: svg }} /> : null}
    </div>
  )
}

function JobsSection({ jobs, prefix }: { jobs: EpicDetailJob[]; prefix: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white">
      <div className="border-b border-gray-200 px-4 py-3">
        <h2 className="font-semibold text-gray-900">Jobs</h2>
      </div>
      {jobs.length > 0 ? (
        <ul className="divide-y divide-gray-100 text-sm">
          {jobs.map((job) => (
            <li className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={job.id}>
              <div className="min-w-0">
                {job.title ? (
                  <>
                    <span className="font-medium text-gray-600">{job.label}</span>
                    <Link className="ml-1 text-gray-700 hover:underline" to={withRoutePrefix(job.path, prefix)}>{job.title}</Link>
                  </>
                ) : (
                  <Link className="font-medium text-blue-600 underline hover:no-underline" to={withRoutePrefix(job.path, prefix)}>{job.label}</Link>
                )}
              </div>
              <StatePill state={job.state} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="px-4 py-6 text-sm text-gray-400">No Jobs in this Epic.</p>
      )}
    </section>
  )
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    backlog: "bg-gray-100 text-gray-700",
    ready: "bg-sky-100 text-sky-700",
    in_progress: "bg-blue-100 text-blue-700",
    done: "bg-green-100 text-green-700",
    archived: "bg-gray-200 text-gray-800",
    queued: "bg-gray-100 text-gray-700",
    running: "bg-blue-100 text-blue-700",
    succeeded: "bg-green-100 text-green-700",
    failed: "bg-red-100 text-red-700",
    cancelled: "bg-amber-100 text-amber-700",
    open: "bg-emerald-100 text-emerald-700",
    triaging: "bg-sky-100 text-sky-700",
    blocked_by_epic: "bg-amber-100 text-amber-700",
    implemented: "bg-cyan-100 text-cyan-700",
    approved: "bg-green-100 text-green-700",
    landing: "bg-teal-100 text-teal-700",
    merged: "bg-emerald-100 text-emerald-700",
    landing_failed: "bg-red-100 text-red-700",
    closed: "bg-gray-200 text-gray-800",
    preempted: "bg-violet-100 text-violet-700",
    pending: "bg-gray-100 text-gray-700"
  }

  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 text-gray-700"}`}>{humanize(state)}</span>
}

function PanelMessage({ children, tone = "success" }: { children: ReactNode; tone?: "success" | "error" | "muted" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    muted: "border-gray-200 bg-white text-gray-600",
    success: "border-green-200 bg-green-50 text-green-700"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1 text-sm text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300"
}

function humanize(value: string) {
  return value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ")
}

function formatRelative(value: string) {
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  if (seconds < 60) return "just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
