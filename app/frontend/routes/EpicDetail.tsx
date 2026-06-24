import { useMutation, useQuery, useQueryClient, type UseMutationResult } from "@tanstack/react-query"
import { Fragment, type FormEvent, type ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { CloseIcon } from "../components/CloseIcon"
import {
  addEpicDependency,
  archiveEpic,
  claimEpic,
  fetchEpicDetail,
  removeEpicDependency,
  searchEpicOptions,
  unclaimEpic,
  updateEpicState,
  type EpicDependencyRecord,
  type EpicDetailJob,
  type EpicDetailPayload,
  type EpicGraph,
  type EpicSearchOption,
  type EpicStateTransition
} from "../api/epics"
import { Markdown } from "../lib/Markdown"

let mermaidInitialized = false
let mermaidInitializedTheme: "base" | "dark" | null = null
let mermaidRenderSequence = 0

type EpicCommand =
  | { kind: "state"; transition: EpicStateTransition }
  | { kind: "archive" }
  | { kind: "claim" }
  | { kind: "unclaim" }

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
      if (action.kind === "claim") return claimEpic(payload.paths.app_claim_path)
      if (action.kind === "unclaim") return unclaimEpic(payload.paths.app_unclaim_path)
      return updateEpicState(payload.paths.app_state_path, action.transition.target_state)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })
  const dependencyCommand = useMutation({
    mutationFn: (action: { kind: "add"; dependsOnEpicId: number } | { kind: "remove"; dependsOnEpicId: number }) => {
      if (action.kind === "add") return addEpicDependency(payload.paths.app_dependencies_path, action.dependsOnEpicId)

      return removeEpicDependency(payload.paths.app_dependencies_path, action.dependsOnEpicId)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      queryClient.invalidateQueries({ queryKey })
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
          <h1 className="break-words text-2xl font-bold text-gray-900 dark:text-gray-100">
            <span className="font-mono">{payload.epic.display_number}</span>
            <span className="px-2 text-gray-400 dark:text-gray-500">·</span>
            {payload.epic.title}
          </h1>
          <StatePill state={payload.epic.state} />
        </div>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          <Link className="font-mono hover:underline" to={withRoutePrefix(payload.epic.repository.repository_path, prefix)}>{payload.epic.repository.slug}</Link>
          <span> · {payload.epic.jobs_count} {payload.epic.jobs_count === 1 ? "Job" : "Jobs"}</span>
          <span> · {ownerLabel(payload.epic)}</span>
          <span> · updated {formatRelative(payload.epic.updated_at)}</span>
        </p>

        {payload.state_transitions.length > 0 || payload.epic.claimable ? (
          <div className="flex flex-wrap items-center gap-2">
            {payload.epic.claimable && payload.epic.owner_status === "unclaimed" ? (
              <button
                className={secondaryButton()}
                disabled={command.isPending}
                onClick={() => command.mutate({ kind: "claim" })}
                type="button"
              >
                Claim
              </button>
            ) : null}
            {payload.epic.claimable && payload.epic.owned_by_current_user ? (
              <button
                className={secondaryButton()}
                disabled={command.isPending}
                onClick={() => command.mutate({ kind: "unclaim" })}
                type="button"
              >
                Unclaim
              </button>
            ) : null}
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
          <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200">
            {payload.summary.done_jobs_count}/{payload.summary.total_jobs_count} done
          </span>
          <span className="rounded bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700 dark:bg-violet-950/50 dark:text-violet-200">
            {payload.summary.dependency_edge_count} {payload.summary.dependency_edge_count === 1 ? "dep" : "deps"}
          </span>
          {payload.summary.blocked ? <span className="rounded bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950/50 dark:text-amber-200">{payload.summary.blocked_reason || "Blocked"}</span> : null}
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Epic command failed.")}</PanelMessage> : null}

      <DependencyGraph graph={payload.graph} />
      <DependenciesSection command={dependencyCommand} currentEpicId={payload.epic.id} dependencies={payload.dependencies} dependents={payload.dependents} prefix={prefix} />

      {payload.epic.description.trim() ? (
        <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <h2 className="font-semibold text-gray-900 dark:text-gray-100">Description</h2>
          <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.epic.description} />
        </section>
      ) : null}

      <JobsSection jobs={payload.jobs} prefix={prefix} />
    </>
  )
}

function DependenciesSection({
  command,
  currentEpicId,
  dependencies,
  dependents,
  prefix
}: {
  command: UseMutationResult<EpicDetailPayload, Error, { kind: "add"; dependsOnEpicId: number } | { kind: "remove"; dependsOnEpicId: number }>
  currentEpicId: number
  dependencies: EpicDependencyRecord[]
  dependents: EpicDependencyRecord[]
  prefix: string
}) {
  const [selectedDependency, setSelectedDependency] = useState<EpicSearchOption | null>(null)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const parsedId = Number.parseInt(String(selectedDependency?.value ?? ""), 10)
    if (!Number.isFinite(parsedId)) return

    command.mutate({ kind: "add", dependsOnEpicId: parsedId }, { onSuccess: () => setSelectedDependency(null) })
  }

  return (
    <section className="grid gap-4 lg:grid-cols-2">
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">Dependencies</h2>
        <h3 className="mt-3 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Depends on</h3>
        {dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {dependencies.map((dependency) => (
              <li className="flex min-h-10 items-center justify-between gap-3 py-2" key={dependency.epic_id}>
                <span className="flex min-w-0 flex-wrap items-center gap-2">
                  <Link className="min-w-0 break-words text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(dependency.url, prefix)}>{dependency.title}</Link>
                  <StatePill state={dependency.state} />
                </span>
                <button
                  aria-label={`Remove dependency on ${dependency.title}`}
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded border border-red-200 text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-red-900/70 dark:text-red-300 dark:hover:bg-red-950/40"
                  disabled={command.isPending}
                  onClick={() => command.mutate({ kind: "remove", dependsOnEpicId: dependency.epic_id })}
                  title={`Remove dependency on ${dependency.title}`}
                  type="button"
                >
                  <CloseIcon className="h-4 w-4" />
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-gray-400 dark:text-gray-500">None</p>
        )}
        <form className="mt-4 flex flex-wrap items-end gap-2 border-t border-gray-100 pt-3 dark:border-gray-800" onSubmit={submit}>
          <EpicDependencyTypeahead
            currentEpicId={currentEpicId}
            excludedEpicIds={dependencies.map((dependency) => dependency.epic_id)}
            onChange={setSelectedDependency}
            selected={selectedDependency}
          />
          <button className={secondaryButton()} disabled={command.isPending || !selectedDependency} type="submit">Add</button>
        </form>
        {command.isError ? <p className="mt-2 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(command.error, "Unable to update dependencies.")}</p> : null}
      </div>
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">Depended on by</h2>
        {dependents.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {dependents.map((dependent) => (
              <li className="flex min-h-10 flex-wrap items-center gap-2 py-2" key={dependent.epic_id}>
                <Link className="break-words text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(dependent.url, prefix)}>{dependent.title}</Link>
                <StatePill state={dependent.state} />
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-gray-400 dark:text-gray-500">None</p>
        )}
      </div>
    </section>
  )
}

function EpicDependencyTypeahead({
  currentEpicId,
  excludedEpicIds,
  onChange,
  selected
}: {
  currentEpicId: number
  excludedEpicIds: number[]
  onChange: (option: EpicSearchOption | null) => void
  selected: EpicSearchOption | null
}) {
  const [query, setQuery] = useState(selected?.label || "")
  const [options, setOptions] = useState<EpicSearchOption[]>([])
  const [loading, setLoading] = useState(false)
  const previousSelectedLabel = useRef<string | null>(selected?.label || null)
  const trimmedQuery = query.trim()
  const excluded = new Set([currentEpicId, ...excludedEpicIds].map(String))

  useEffect(() => {
    if (selected) {
      previousSelectedLabel.current = selected.label
      setQuery(selected.label)
      return
    }

    if (previousSelectedLabel.current && query === previousSelectedLabel.current) {
      setQuery("")
    }
    previousSelectedLabel.current = null
  }, [selected?.label])

  useEffect(() => {
    if (trimmedQuery.length < 2 || selected?.label === query) {
      setOptions([])
      setLoading(false)
      return
    }

    let cancelled = false
    const controller = new AbortController()
    setLoading(true)

    void searchEpicOptions(trimmedQuery, { signal: controller.signal }).then((loadedOptions) => {
      if (!cancelled) setOptions(loadedOptions.filter((option) => !excluded.has(String(option.value))))
    }).catch((error: unknown) => {
      if (!cancelled && !(error instanceof DOMException && error.name === "AbortError")) setOptions([])
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })

    return () => {
      cancelled = true
      controller.abort()
    }
  }, [excludedEpicIds.join("\0"), currentEpicId, query, selected?.label, trimmedQuery])

  function updateQuery(value: string) {
    setQuery(value)
    if (selected) onChange(null)
  }

  function choose(option: EpicSearchOption) {
    onChange(option)
    setQuery(option.label)
    setOptions([])
  }

  return (
    <label className="relative min-w-0 flex-1 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
      Add dependency
      <input
        aria-autocomplete="list"
        className="mt-1 w-full min-w-64 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
        onChange={(event) => updateQuery(event.target.value)}
        placeholder="Search Epics by name..."
        type="search"
        value={query}
      />
      {trimmedQuery.length >= 2 && selected?.label !== query ? (
        <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-56 overflow-y-auto rounded border border-gray-200 bg-white py-1 normal-case shadow-lg dark:border-gray-700 dark:bg-gray-900">
          {options.length > 0 ? (
            options.map((option) => (
              <button
                className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
                key={String(option.value)}
                onClick={() => choose(option)}
                type="button"
              >
                {option.label}
              </button>
            ))
          ) : (
            <div className="px-3 py-1.5 text-sm text-gray-400 dark:text-gray-500">{loading ? "Searching..." : "No matches"}</div>
          )}
        </div>
      ) : null}
    </label>
  )
}

function DependencyGraph({ graph }: { graph: EpicGraph }) {
  if (graph.empty) return <p className="text-sm text-gray-500 dark:text-gray-400">No external dependencies</p>

  return (
    <details className="group rounded border border-gray-200 bg-white text-sm dark:border-gray-700 dark:bg-gray-900" open={graph.initially_open}>
      <summary className="flex cursor-pointer flex-wrap items-center justify-between gap-2 px-3 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-800">
        <span className="flex items-center gap-2">
          <span className="text-gray-400 transition-transform group-open:rotate-90 dark:text-gray-500">▶</span>
          <span className="font-medium">Dependency graph</span>
          <span className="text-gray-500 dark:text-gray-400">({graph.epic_dependency_count} {graph.epic_dependency_count === 1 ? "epic dep" : "epic deps"}, {graph.job_blocker_count} {graph.job_blocker_count === 1 ? "job blocker" : "job blockers"})</span>
        </span>
      </summary>
      <div className="border-t border-gray-100 p-3 dark:border-gray-800">
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
        const theme = document.documentElement.classList.contains("dark") ? "dark" : "base"
        if (!mermaidInitialized || mermaidInitializedTheme !== theme) {
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme })
          mermaidInitialized = true
          mermaidInitializedTheme = theme
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
    <div className="overflow-x-auto rounded bg-gray-50 p-3 dark:bg-gray-950">
      {error ? <p className="text-sm text-red-700 dark:text-red-300">{error}</p> : null}
      {!error && !svg ? <p className="text-sm text-gray-500 dark:text-gray-400">Rendering dependency graph...</p> : null}
      {svg ? <div className="min-w-[28rem] text-center text-gray-700 dark:text-gray-200" dangerouslySetInnerHTML={{ __html: svg }} /> : null}
    </div>
  )
}

function JobsSection({ jobs, prefix }: { jobs: EpicDetailJob[]; prefix: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">Jobs</h2>
      </div>
      {jobs.length > 0 ? (
        <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
          {jobs.map((job) => (
            <li className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={job.id}>
              <div className="min-w-0">
                {job.title ? (
                  <>
                    <span className="font-medium text-gray-600 dark:text-gray-400">{job.label}</span>
                    <Link className="ml-1 text-gray-700 hover:underline dark:text-gray-200" to={withRoutePrefix(job.path, prefix)}>{job.title}</Link>
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
        <p className="px-4 py-6 text-sm text-gray-400 dark:text-gray-500">No Jobs in this Epic.</p>
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
    backlog: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200",
    ready: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-200",
    in_progress: "bg-blue-100 text-blue-700 dark:bg-blue-950/50 dark:text-blue-200",
    done: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    archived: "bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-100",
    queued: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200",
    running: "bg-blue-100 text-blue-700 dark:bg-blue-950/50 dark:text-blue-200",
    succeeded: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    failed: "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200",
    cancelled: "bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-200",
    open: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
    triaging: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-200",
    blocked_by_epic: "bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-200",
    implemented: "bg-cyan-100 text-cyan-700 dark:bg-cyan-950/50 dark:text-cyan-200",
    approved: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    landing: "bg-teal-100 text-teal-700 dark:bg-teal-950/50 dark:text-teal-200",
    merged: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
    landing_failed: "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200",
    closed: "bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-100",
    preempted: "bg-violet-100 text-violet-700 dark:bg-violet-950/50 dark:text-violet-200",
    pending: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"
  }

  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"}`}>{humanize(state)}</span>
}

function PanelMessage({ children, tone = "success" }: { children: ReactNode; tone?: "success" | "error" | "muted" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1 text-sm text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
}

function humanize(value: string) {
  return value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ")
}

function ownerLabel(epic: EpicDetailPayload["epic"]) {
  const owner = epic.owner_user || epic.owner
  return owner ? `Owner ${owner.email_address}` : "Unclaimed"
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
