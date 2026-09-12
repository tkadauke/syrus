import { useVirtualizer } from "@tanstack/react-virtual"
import { useQuery } from "@tanstack/react-query"
import { useMemo, useRef, useState, type CSSProperties, type FormEvent, type ReactNode } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { fetchJobTargetGraph, fetchRepositoryTargetGraph, type TargetGraphEdge, type TargetGraphPayload, type TargetGraphQuery, type TargetGraphTarget } from "../api/targetGraphs"
import { RepositoryPageShell } from "../components/RepositoryPageShell"
import { PageHeading, SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { Input } from "../components/Input"
import { FilterBar } from "../components/FilterBar"
import { TonePill, type PillTone } from "../components/StatusPill"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { errorMessage } from "../lib/errorMessage"

const DEFAULT_LIMIT = 180
const FOCUS_STATES = ["selected", "failing", "skipped", "cached"] as const
const DIRECTIONS = ["both", "dependencies", "dependents"] as const

export function RepositoryTargetGraphRoute() {
  const params = useParams()
  const location = useLocation()
  const repositoryId = params.repositoryId || params.id || ""
  const prefix = routePrefix(location.pathname)
  const graphQuery = targetGraphQueryFromSearch(location.search)
  const query = useQuery({
    queryKey: ["repositories", repositoryId, "target_graph", graphQuery],
    queryFn: () => fetchRepositoryTargetGraph(repositoryId, graphQuery),
    enabled: repositoryId.length > 0
  })

  return (
    <RepositoryPageShell
      activeTab="target_graph"
      ariaLabel="Repository target graph"
      heading={query.data ? (
        <PageHeading mono>
          <Link className="hover:underline" to={withRoutePrefix(`/repositories/${query.data.repository.id}`, prefix)}>{query.data.repository.slug}</Link>
        </PageHeading>
      ) : null}
      prefix={prefix}
      tabs={query.data?.tabs ?? []}
    >
      {query.isPending ? <PanelMessage>Loading target graph...</PanelMessage> : null}
      {query.isError ? <PanelMessage tone="error">{errorMessage(query.error, "Unable to load target graph.")}</PanelMessage> : null}
      {query.data ? (
        <TargetGraphExplorer
          backLink={{ label: "Overview", path: `/repositories/${query.data.repository.id}` }}
          payload={query.data}
          prefix={prefix}
          query={graphQuery}
        />
      ) : null}
    </RepositoryPageShell>
  )
}

export function JobTargetGraphPanel({ jobId, prefix }: { jobId: string | number; prefix: string }) {
  const location = useLocation()
  const graphQuery = targetGraphQueryFromSearch(location.search)
  const query = useQuery({
    queryKey: ["jobs", String(jobId), "target_graph", graphQuery],
    queryFn: () => fetchJobTargetGraph(jobId, graphQuery),
    enabled: String(jobId).length > 0
  })

  if (query.isPending) return <PanelMessage>Loading target graph...</PanelMessage>
  if (query.isError) return <PanelMessage tone="error">{errorMessage(query.error, "Unable to load target graph.")}</PanelMessage>
  if (!query.data) return null

  return <TargetGraphExplorer persistentSearchParams={{ tab: "target_graph" }} payload={query.data} prefix={prefix} query={graphQuery} />
}

export function targetGraphQueryFromSearch(search: string): TargetGraphQuery {
  const params = new URLSearchParams(search)
  const mode = params.get("mode") === "window" ? "window" : "neighborhood"
  const focusState = FOCUS_STATES.find((state) => state === params.get("focus_state"))
  const direction = DIRECTIONS.find((value) => value === params.get("direction")) || "both"
  const rawQ = params.get("q") || undefined
  const filter = rawQ && decodesAsFilterTree(rawQ) ? rawQ : undefined
  return {
    mode,
    focusLabel: params.get("focus_label") || undefined,
    focusState,
    projectId: params.get("project_id") || undefined,
    kind: params.get("kind") || undefined,
    q: filter ? undefined : rawQ,
    filter,
    search: params.get("search") || undefined,
    direction,
    depth: clampNumber(params.get("depth"), 1, 0, 4),
    limit: clampNumber(params.get("limit"), DEFAULT_LIMIT, 25, 500),
    offset: mode === "window" ? clampNumber(params.get("offset"), 0, 0, 100_000) : 0
  }
}

export function targetGraphSearchFromQuery(query: TargetGraphQuery, persistentSearchParams: Record<string, string> = {}) {
  const params = new URLSearchParams(persistentSearchParams)
  if (query.mode && query.mode !== "neighborhood") params.set("mode", query.mode)
  if (query.focusLabel) params.set("focus_label", query.focusLabel)
  if (query.focusState) params.set("focus_state", query.focusState)
  if (query.projectId) params.set("project_id", query.projectId)
  if (query.kind) params.set("kind", query.kind)
  if (query.filter) params.set("q", query.filter)
  else if (query.q) params.set("q", query.q)
  if (query.search) params.set("search", query.search)
  if (query.direction && query.direction !== "both") params.set("direction", query.direction)
  if (query.depth !== undefined && query.depth !== 1) params.set("depth", String(query.depth))
  if (query.limit !== undefined && query.limit !== DEFAULT_LIMIT) params.set("limit", String(query.limit))
  if (query.mode === "window" && query.offset) params.set("offset", String(query.offset))
  const value = params.toString()
  return value ? `?${value}` : ""
}

export function TargetGraphExplorer({
  backLink,
  payload,
  persistentSearchParams = {},
  prefix,
  query
}: {
  backLink?: { label: string; path: string }
  payload: TargetGraphPayload
  persistentSearchParams?: Record<string, string>
  prefix: string
  query: TargetGraphQuery
}) {
  const navigate = useNavigate()
  const location = useLocation()
  const [draft, setDraft] = useState(query.search || query.q || query.focusLabel || "")
  const rows = useMemo(() => buildGraphRows(payload.targets, payload.edges), [payload.targets, payload.edges])
  const visibleLabels = useMemo(() => new Set(payload.targets.map((target) => target.label)), [payload.targets])

  function updateQuery(next: TargetGraphQuery) {
    navigate(`${location.pathname}${targetGraphSearchFromQuery({ ...query, ...next }, persistentSearchParams)}`)
  }

  function submitSearch(event: FormEvent) {
    event.preventDefault()
    const value = draft.trim()
    updateQuery({
      focusLabel: query.mode === "neighborhood" ? value || undefined : undefined,
      focusState: undefined,
      q: undefined,
      search: query.mode === "window" ? value || undefined : undefined,
      offset: 0
    })
  }

  return (
    <div className="space-y-4">
      {payload.error ? <PanelMessage tone="error">{payload.error}</PanelMessage> : null}
      <FilterBar
        buildLink={targetGraphFilterLink}
        filter={payload.filter}
        filterSchema={payload.filter_schema ?? []}
        legacyFilterKeys={["project_id", "kind"]}
        pathname={location.pathname}
        search={location.search}
      />
      <TargetGraphToolbar
        draft={draft}
        overlaysAvailable={Boolean(payload.workflow)}
        query={query}
        onDraftChange={setDraft}
        onSubmit={submitSearch}
        onUpdate={updateQuery}
      />
      <TargetGraphStats payload={payload} query={query} />
      {payload.targets.length === 0 ? (
        <PanelMessage>
          No target graph nodes match this view.
        </PanelMessage>
      ) : (
        <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-700">
            <SectionHeading>Graph Neighborhood</SectionHeading>
            <span className="text-xs text-gray-500 dark:text-gray-400">{payload.targets.length.toLocaleString()} rendered of {payload.page.total.toLocaleString()}</span>
          </div>
          <TargetGraphCanvas
            rows={rows}
            visibleLabels={visibleLabels}
            onFocus={(label) => {
              setDraft(label)
              updateQuery({ mode: "neighborhood", focusLabel: label, focusState: undefined, q: undefined, search: undefined, offset: 0 })
            }}
          />
        </section>
      )}
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-gray-500 dark:text-gray-400">
        <span>Source {payload.source.scope} · {payload.source.ref}</span>
        {payload.workflow ? <span>Workflow {payload.workflow.slug}</span> : null}
        {payload.diagnostics?.source ? <span>Compiled from {payload.diagnostics.source}</span> : null}
        {backLink ? <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(backLink.path, prefix)}>{backLink.label}</Link> : null}
      </div>
    </div>
  )
}

function TargetGraphToolbar({
  draft,
  overlaysAvailable,
  query,
  onDraftChange,
  onSubmit,
  onUpdate
}: {
  draft: string
  overlaysAvailable: boolean
  query: TargetGraphQuery
  onDraftChange: (value: string) => void
  onSubmit: (event: FormEvent) => void
  onUpdate: (query: TargetGraphQuery) => void
}) {
  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="grid gap-3 xl:grid-cols-[minmax(18rem,1fr)_repeat(2,minmax(8rem,12rem))]">
        <form className="flex min-w-0 gap-2" onSubmit={onSubmit}>
          <Input
            aria-label="Target label or path search"
            onChange={(event) => onDraftChange(event.target.value)}
            placeholder="//app:target or app/**/*.rb"
            value={draft}
          />
          <button className="rounded bg-brand px-3 py-2 text-sm font-medium text-on-brand hover:opacity-90" type="submit">{query.mode === "window" ? "Search" : "Focus"}</button>
        </form>
        <SelectControl label="Depth" value={String(query.depth ?? 1)} onChange={(value) => onUpdate({ depth: Number(value), offset: 0 })}>
          {[0, 1, 2, 3, 4].map((depth) => <option key={depth} value={depth}>{depth}</option>)}
        </SelectControl>
        <SelectControl label="Direction" value={query.direction || "both"} onChange={(value) => onUpdate({ direction: value as TargetGraphQuery["direction"], offset: 0 })}>
          <option value="both">Both</option>
          <option value="dependencies">Dependencies</option>
          <option value="dependents">Dependents</option>
        </SelectControl>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        {FOCUS_STATES.map((state) => (
          (() => {
            const needsOverlay = state !== "failing"
            const disabled = needsOverlay && !overlaysAvailable
            return (
          <button
            className={`rounded border px-3 py-1.5 text-xs font-medium ${query.focusState === state ? "border-brand bg-brand text-on-brand" : "border-gray-300 bg-white text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800"}`}
            disabled={disabled}
            key={state}
            onClick={() => {
              onDraftChange("")
              onUpdate({ mode: "neighborhood", focusLabel: undefined, focusState: state, search: undefined, q: undefined, offset: 0 })
            }}
            title={disabled ? "Available on Job and Workflow target graphs after fanout records runtime selections." : undefined}
            type="button"
          >
            {stateLabel(state)}
          </button>
            )
          })()
        ))}
        <button
          className={`rounded border px-3 py-1.5 text-xs font-medium ${query.mode === "window" ? "border-brand bg-brand text-on-brand" : "border-gray-300 bg-white text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300 dark:hover:bg-gray-800"}`}
          onClick={() => onUpdate({ mode: "window", focusLabel: undefined, focusState: undefined, offset: 0 })}
          type="button"
        >
          Browse
        </button>
      </div>
    </section>
  )
}

function SelectControl({ children, label, value, onChange }: { children: ReactNode; label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="block min-w-0 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
      <span>{label}</span>
      <select
        className="mt-1 block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm normal-case text-gray-900 focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100"
        onChange={(event) => onChange(event.target.value)}
        value={value}
      >
        {children}
      </select>
    </label>
  )
}

function TargetGraphStats({ payload, query }: { payload: TargetGraphPayload; query: TargetGraphQuery }) {
  const healthSummary = Object.entries(payload.health.summary).filter(([, count]) => count > 0)
  return (
    <div className="grid gap-3 md:grid-cols-4">
      <StatBox label="Targets" value={payload.page.total.toLocaleString()} detail={`${payload.targets.length.toLocaleString()} in view`} />
      <StatBox label="Projects" value={payload.projects.length.toLocaleString()} detail={query.projectId || "all projects"} />
      <StatBox label="Mode" value={query.mode === "window" ? "Browse" : "Neighborhood"} detail={query.focusLabel || query.focusState || "first target"} />
      <div className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900">
        <div className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">Health</div>
        <div className="mt-2 flex min-h-7 flex-wrap gap-1.5">
          {healthSummary.length === 0 ? <span className="text-sm text-gray-500 dark:text-gray-400">No records in view</span> : null}
          {healthSummary.map(([status, count]) => (
            <TonePill key={status} tone={healthTone(status)}>{status} {count}</TonePill>
          ))}
        </div>
      </div>
    </div>
  )
}

function StatBox({ label, value, detail }: { label: string; value: string; detail: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white p-3 dark:border-gray-700 dark:bg-gray-900">
      <div className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-gray-950 dark:text-gray-100">{value}</div>
      <div className="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">{detail}</div>
    </div>
  )
}

export type TargetGraphRow = {
  target: TargetGraphTarget
  dependencies: string[]
  dependents: string[]
}

export function buildGraphRows(targets: TargetGraphTarget[], edges: TargetGraphEdge[]): TargetGraphRow[] {
  const dependenciesByTarget = new Map<string, string[]>()
  const dependentsByTarget = new Map<string, string[]>()
  targets.forEach((target) => {
    dependenciesByTarget.set(target.label, [...target.dependencies])
    dependentsByTarget.set(target.label, [])
  })
  edges.forEach((edge) => {
    if (!dependentsByTarget.has(edge.from)) dependentsByTarget.set(edge.from, [])
    dependentsByTarget.get(edge.from)?.push(edge.to)
  })
  return targets.map((target) => ({
    target,
    dependencies: dependenciesByTarget.get(target.label) || [],
    dependents: dependentsByTarget.get(target.label) || []
  }))
}

function TargetGraphCanvas({ rows, visibleLabels, onFocus }: { rows: TargetGraphRow[]; visibleLabels: Set<string>; onFocus: (label: string) => void }) {
  const parentRef = useRef<HTMLDivElement | null>(null)
  const virtualizer = useVirtualizer({
    count: rows.length,
    estimateSize: () => 132,
    getScrollElement: () => parentRef.current,
    overscan: 8
  })
  const virtualRows = virtualizer.getVirtualItems()

  return (
    <div className="h-[34rem] overflow-auto" ref={parentRef}>
      <div className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
        {virtualRows.map((virtualRow) => {
          const row = rows[virtualRow.index]
          if (!row) return null
          return (
            <div
              className="absolute left-0 top-0 w-full px-4 py-2"
              data-index={virtualRow.index}
              key={virtualRow.key}
              ref={virtualizer.measureElement}
              style={virtualRowStyle(virtualRow.start)}
            >
              <TargetGraphNode row={row} visibleLabels={visibleLabels} onFocus={onFocus} />
            </div>
          )
        })}
      </div>
    </div>
  )
}

function TargetGraphNode({ row, visibleLabels, onFocus }: { row: TargetGraphRow; visibleLabels: Set<string>; onFocus: (label: string) => void }) {
  const target = row.target
  return (
    <article className="rounded border border-gray-200 bg-gray-50 p-3 text-sm dark:border-gray-700 dark:bg-gray-950">
      <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div className="min-w-0">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <button className="truncate font-mono text-sm font-semibold text-gray-950 hover:text-brand dark:text-gray-100" onClick={() => onFocus(target.label)} type="button">
              {target.label}
            </button>
            <TonePill tone={kindTone(target.kind)}>{target.kind}</TonePill>
            {target.executable ? <TonePill tone="blue">run</TonePill> : null}
            {target.selection?.state ? <TonePill tone={selectionTone(target.selection.state)}>{target.selection.state}</TonePill> : null}
            {target.health?.status ? <TonePill tone={healthTone(target.health.status)}>{target.health.status}</TonePill> : null}
          </div>
          {target.executable_metadata?.command ? <div className="mt-1 truncate font-mono text-xs text-gray-500 dark:text-gray-400">{target.executable_metadata.command}</div> : null}
          {target.selection?.reason ? <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{target.selection.reason}</div> : null}
        </div>
        <button className="shrink-0 rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-white dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-900" onClick={() => onFocus(target.label)} type="button">
          Expand
        </button>
      </div>
      <div className="mt-3 grid gap-3 md:grid-cols-2">
        <EdgeList empty="No dependencies" labels={row.dependencies} title="Dependencies" visibleLabels={visibleLabels} onFocus={onFocus} />
        <EdgeList empty="No dependents" labels={row.dependents} title="Dependents" visibleLabels={visibleLabels} onFocus={onFocus} />
      </div>
    </article>
  )
}

function EdgeList({ empty, labels, title, visibleLabels, onFocus }: { empty: string; labels: string[]; title: string; visibleLabels: Set<string>; onFocus: (label: string) => void }) {
  return (
    <div>
      <div className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">{title}</div>
      <div className="mt-1 flex min-h-7 flex-wrap gap-1.5">
        {labels.length === 0 ? <span className="text-xs text-gray-500 dark:text-gray-400">{empty}</span> : null}
        {labels.slice(0, 10).map((label) => (
          <button
            className={`max-w-full truncate rounded border px-2 py-1 font-mono text-xs ${visibleLabels.has(label) ? "border-gray-300 bg-white text-gray-700 hover:border-brand hover:text-brand dark:border-gray-600 dark:bg-gray-900 dark:text-gray-300" : "border-dashed border-gray-300 text-gray-500 hover:border-brand dark:border-gray-700 dark:text-gray-500"}`}
            key={label}
            onClick={() => onFocus(label)}
            title={label}
            type="button"
          >
            {label}
          </button>
        ))}
        {labels.length > 10 ? <span className="text-xs text-gray-500 dark:text-gray-400">+{labels.length - 10}</span> : null}
      </div>
    </div>
  )
}

function virtualRowStyle(start: number): CSSProperties {
  return {
    transform: `translateY(${start}px)`
  }
}

function clampNumber(value: string | null, fallback: number, min: number, max: number) {
  if (value === null || value.trim() === "") return fallback
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(Math.max(Math.trunc(parsed), min), max)
}

function decodesAsFilterTree(value: string) {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/")
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0))
    const decoded = new TextDecoder().decode(bytes)
    const parsed = JSON.parse(decoded) as unknown
    return Boolean(parsed && typeof parsed === "object" && ("and" in parsed || "or" in parsed || "not" in parsed || "field" in parsed))
  } catch {
    return false
  }
}

function targetGraphFilterLink(path: string, search: string, updates: Record<string, string | number | null | undefined>) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) params.delete(key)
    else params.set(key, String(value))
  }
  params.delete("offset")
  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function stateLabel(state: (typeof FOCUS_STATES)[number]) {
  return state === "selected" ? "Selected" : state === "failing" ? "Failing" : state === "skipped" ? "Skipped" : "Cached"
}

function kindTone(kind: string): PillTone {
  if (kind === "grader") return "red"
  if (kind === "builder") return "blue"
  if (kind === "prepare") return "amber"
  if (kind === "formatter" || kind === "generator") return "green"
  return "gray"
}

function healthTone(status: string): PillTone {
  if (status === "failed") return "red"
  if (status === "passed") return "green"
  if (status === "running") return "blue"
  if (status === "skipped") return "amber"
  return "gray"
}

function selectionTone(state: string): PillTone {
  if (state === "selected") return "blue"
  if (state === "cached") return "green"
  if (state === "skipped") return "amber"
  return "gray"
}
