import { useVirtualizer } from "@tanstack/react-virtual"
import { useQuery } from "@tanstack/react-query"
import { useMemo, useRef, useState, type CSSProperties, type FormEvent, type ReactNode } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import {
  fetchJobTargetGraph,
  fetchRepositoryTargetGraph,
  type TargetGraphEdge,
  type TargetGraphPayload,
  type TargetGraphQuery,
  type TargetGraphTarget,
  type TargetGraphTargetExplanation
} from "../api/targetGraphs"
import { RepositoryPageShell } from "../components/RepositoryPageShell"
import { PageHeading, SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { Input } from "../components/Input"
import { Button } from "../components/Button"
import { Select } from "../components/Select"
import { FilterBar } from "../components/FilterBar"
import { CloseIcon } from "../components/CloseIcon"
import { Modal } from "../components/Modal"
import { TonePill, type PillTone } from "../components/StatusPill"
import { Surface } from "../components/ui"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { errorMessage } from "../lib/errorMessage"
import { useT } from "../hooks/useT"

const DEFAULT_LIMIT = 100
const FOCUS_STATES = ["selected", "failing", "skipped", "cached"] as const
const DIRECTIONS = ["both", "dependencies", "dependents"] as const
const TARGET_TABLE_GRID = "grid min-w-[52rem] grid-cols-[minmax(14rem,1.25fr)_7rem_minmax(13rem,1fr)_10rem_10rem] gap-3"
const TARGET_TABLE_HEADER_CLASS = `${TARGET_TABLE_GRID} border-b border-border bg-surface-raised px-3 py-2 text-[11px] font-semibold uppercase tracking-wide text-text-secondary`
const TARGET_TABLE_ROW_CLASS = `${TARGET_TABLE_GRID} min-h-14 w-full items-center border-b border-border px-3 py-1.5 text-left text-xs hover:bg-brand-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand`

export function RepositoryTargetGraphRoute() {
  const { t } = useT("settings")
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
      ariaLabel={t("target_graph.aria_repository")}
      heading={
        query.data ? (
          <PageHeading mono>
            <Link className="hover:underline" to={withRoutePrefix(`/repositories/${query.data.repository.id}`, prefix)}>
              {query.data.repository.slug}
            </Link>
          </PageHeading>
        ) : null
      }
      prefix={prefix}
      tabs={query.data?.tabs ?? []}
    >
      {query.isPending ? <PanelMessage>{t("target_graph.loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage tone="error">{errorMessage(query.error, t("target_graph.error_load"))}</PanelMessage> : null}
      {query.data ? (
        <TargetGraphExplorer
          backLink={{ label: t("target_graph.back_overview"), path: `/repositories/${query.data.repository.id}` }}
          payload={query.data}
          prefix={prefix}
          query={graphQuery}
        />
      ) : null}
    </RepositoryPageShell>
  )
}

export function JobTargetGraphPanel({ jobId, prefix }: { jobId: string | number; prefix: string }) {
  const { t } = useT("settings")
  const location = useLocation()
  const graphQuery = targetGraphQueryFromSearch(location.search)
  const query = useQuery({
    queryKey: ["jobs", String(jobId), "target_graph", graphQuery],
    queryFn: () => fetchJobTargetGraph(jobId, graphQuery),
    enabled: String(jobId).length > 0
  })

  if (query.isPending) return <PanelMessage>{t("target_graph.loading")}</PanelMessage>
  if (query.isError) return <PanelMessage tone="error">{errorMessage(query.error, t("target_graph.error_load"))}</PanelMessage>
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
    workflowId: params.get("workflow_id") || undefined,
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
  if (query.workflowId) params.set("workflow_id", query.workflowId)
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
  const { t } = useT("settings")
  const navigate = useNavigate()
  const location = useLocation()
  const [draft, setDraft] = useState(query.search || query.q || query.focusLabel || "")
  const rows = useMemo(() => buildGraphRows(payload.targets, payload.edges), [payload.targets, payload.edges])
  const [selectedLabel, setSelectedLabel] = useState<string | null>(null)
  const selectedRow = rows.find((row) => row.target.label === selectedLabel) ?? null
  const [showExplanations, setShowExplanations] = useState(false)
  const [showDiagnostics, setShowDiagnostics] = useState(false)
  const detailsQuery = useQuery({
    queryKey: ["target_graph_details", payload.source, query, showExplanations, showDiagnostics],
    queryFn: () =>
      payload.workflow
        ? fetchJobTargetGraph(payload.workflow.job_id, {
            ...query,
            workflowId: String(payload.workflow.id),
            include: [...(showExplanations ? ["explanations" as const] : []), ...(showDiagnostics ? ["diagnostics" as const] : [])]
          })
        : fetchRepositoryTargetGraph(payload.repository.id, {
            ...query,
            include: [...(showExplanations ? ["explanations" as const] : []), ...(showDiagnostics ? ["diagnostics" as const] : [])]
          }),
    enabled: showExplanations || showDiagnostics
  })
  const detailPayload = detailsQuery.data

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
    <div className="space-y-2.5">
      {payload.error ? <PanelMessage tone="error">{payload.error}</PanelMessage> : null}
      <TargetGraphSummary payload={payload} />
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
        projects={payload.projects}
        query={query}
        onDraftChange={setDraft}
        onSubmit={submitSearch}
        onUpdate={updateQuery}
      />
      <TargetGraphDecisionSummary payload={detailPayload ?? payload} query={query} overlaysAvailable={Boolean(payload.workflow)} onUpdate={updateQuery} />
      <section className="flex flex-wrap gap-2" aria-label={t("target_graph.additional_details")}>
        <Button onClick={() => setShowExplanations((value) => !value)} size="sm" type="button" variant="secondary">
          {showExplanations ? t("target_graph.hide_explanations") : t("target_graph.show_explanations")}
        </Button>
        <Button onClick={() => setShowDiagnostics((value) => !value)} size="sm" type="button" variant="secondary">
          {showDiagnostics ? t("target_graph.hide_diagnostics") : t("target_graph.show_diagnostics")}
        </Button>
      </section>
      {detailsQuery.isError ? <PanelMessage tone="error">{errorMessage(detailsQuery.error, t("target_graph.error_load_details"))}</PanelMessage> : null}
      {showExplanations && detailsQuery.isPending ? <PanelMessage>{t("target_graph.loading_explanations")}</PanelMessage> : null}
      {showExplanations && detailPayload ? <TargetGraphExplanations payload={detailPayload} /> : null}
      {showDiagnostics && detailPayload?.diagnostics ? <TargetGraphDiagnostics diagnostics={detailPayload.diagnostics} /> : null}
      {payload.targets.length === 0 ? (
        <PanelMessage>{t("target_graph.empty")}</PanelMessage>
      ) : (
        <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
            <div>
              <SectionHeading>{t("target_graph.targets_and_dependencies")}</SectionHeading>
              <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{t("target_graph.row_help")}</p>
            </div>
            <span className="text-xs text-gray-500 dark:text-gray-400">
              {t("target_graph.rendered_count", { count: payload.targets.length.toLocaleString(), total: payload.page.total.toLocaleString() })}
            </span>
          </div>
          <TargetGraphTable rows={rows} selectedLabel={selectedLabel} onSelect={setSelectedLabel} />
          {query.mode === "window" && (payload.page.offset > 0 || payload.page.next_offset !== null) ? (
            <div className="flex items-center justify-end gap-2 border-t border-gray-200 px-4 py-3 dark:border-gray-700">
              <Button
                disabled={payload.page.offset === 0}
                onClick={() => updateQuery({ offset: Math.max(0, payload.page.offset - payload.page.limit) })}
                size="sm"
                type="button"
                variant="secondary"
              >
                {t("target_graph.previous_page")}
              </Button>
              <Button
                disabled={payload.page.next_offset === null}
                onClick={() => updateQuery({ offset: payload.page.next_offset ?? payload.page.offset })}
                size="sm"
                type="button"
                variant="secondary"
              >
                {t("target_graph.next_page")}
              </Button>
            </div>
          ) : null}
        </section>
      )}
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-gray-500 dark:text-gray-400">
        <span>{t("target_graph.source", { scope: payload.source.scope, ref: payload.source.ref })}</span>
        {payload.workflow ? <span>{t("target_graph.workflow", { slug: payload.workflow.slug })}</span> : null}
        {payload.diagnostics?.source ? <span>{t("target_graph.compiled_from", { source: payload.diagnostics.source })}</span> : null}
        {backLink ? (
          <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(backLink.path, prefix)}>
            {backLink.label}
          </Link>
        ) : null}
      </div>
      {selectedRow ? (
        <TargetDetailPanel
          row={selectedRow}
          onClose={() => setSelectedLabel(null)}
          onFocus={(label) => {
            setSelectedLabel(null)
            setDraft(label)
            updateQuery({ mode: "neighborhood", focusLabel: label, focusState: undefined, q: undefined, search: undefined, offset: 0 })
          }}
        />
      ) : null}
    </div>
  )
}

function TargetGraphDiagnostics({ diagnostics }: { diagnostics: NonNullable<TargetGraphPayload["diagnostics"]> }) {
  const { t } = useT("settings")
  const labels = diagnostics.target_labels ?? []
  return (
    <Surface>
      <SectionHeading>{t("target_graph.diagnostics")}</SectionHeading>
      <div className="mt-2 text-xs text-text-secondary">{t("target_graph.diagnostic_target_count", { count: labels.length })}</div>
      {labels.length > 0 ? (
        <Surface className="mt-2 max-h-48 whitespace-pre-wrap overflow-auto font-mono text-xs" padding="sm" variant="inset">
          {labels.join("\n")}
        </Surface>
      ) : null}
    </Surface>
  )
}

function TargetGraphExplanations({ payload }: { payload: TargetGraphPayload }) {
  const { t } = useT("settings")
  const explanations = payload.explanations
  const projects = explanations?.projects ?? []
  const selected = explanations?.selected_targets ?? []
  const skipped = explanations?.skipped_targets ?? []
  const cached = explanations?.cached_targets ?? []
  const ambiguous = explanations?.ambiguous ?? []
  const hasExplanations = projects.length > 0 || selected.length > 0 || skipped.length > 0 || cached.length > 0 || ambiguous.length > 0
  if (!hasExplanations) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <SectionHeading>{t("target_graph.selection_explanations")}</SectionHeading>
        {payload.workflow ? (
          <span className="text-xs text-gray-500 dark:text-gray-400">{t("target_graph.runtime_decisions_from", { slug: payload.workflow.slug })}</span>
        ) : null}
      </div>
      <div className="mt-3 grid gap-4 xl:grid-cols-2">
        {projects.length > 0 ? (
          <ExplanationGroup title={t("target_graph.affected_projects")}>
            {projects.map((project) => (
              <li className="rounded border border-gray-200 p-3 dark:border-gray-700" key={project.id}>
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <span className="font-medium text-gray-950 dark:text-gray-100">{project.label || project.id}</span>
                  <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{project.id}</span>
                </div>
                {project.path ? <div className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{project.path}</div> : null}
                <div className="mt-2 flex flex-wrap gap-1.5">
                  <TonePill tone="blue">{t("target_graph.selected_count", { count: project.selected_target_count ?? 0 })}</TonePill>
                  <TonePill tone="amber">{t("target_graph.skipped_count", { count: project.skipped_target_count ?? 0 })}</TonePill>
                  <TonePill tone="green">{t("target_graph.cached_count", { count: project.cached_target_count ?? 0 })}</TonePill>
                </div>
              </li>
            ))}
          </ExplanationGroup>
        ) : null}
        {selected.length > 0 ? <TargetExplanationGroup entries={selected} title={t("target_graph.executable_targets_selected")} tone="blue" /> : null}
        {skipped.length > 0 ? <TargetExplanationGroup entries={skipped} title={t("target_graph.skipped_targets")} tone="amber" /> : null}
        {cached.length > 0 ? <TargetExplanationGroup entries={cached} title={t("target_graph.cached_targets")} tone="green" /> : null}
        {ambiguous.length > 0 ? (
          <ExplanationGroup title={t("target_graph.preview_and_project_choices")}>
            {ambiguous.map((entry) => (
              <li className="rounded border border-gray-200 p-3 dark:border-gray-700" key={entry.kind}>
                <div className="flex flex-wrap items-center gap-2">
                  <TonePill tone={entry.status === "ambiguous" ? "amber" : entry.status === "unavailable" ? "red" : "blue"}>{entry.status}</TonePill>
                  <span className="font-medium text-gray-950 dark:text-gray-100">{ambiguityLabel(entry.kind, t)}</span>
                </div>
                {entry.reason ? <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{entry.reason}</div> : null}
                {entry.choices && entry.choices.length > 0 ? (
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {entry.choices.map((choice) => (
                      <span className="rounded border border-gray-200 px-2 py-1 text-xs dark:border-gray-700" key={choice.id}>
                        <span className="font-medium">{choice.label || choice.id}</span>
                        {choice.path ? <span className="ml-1 font-mono text-gray-500 dark:text-gray-400">{choice.path}</span> : null}
                      </span>
                    ))}
                  </div>
                ) : null}
              </li>
            ))}
          </ExplanationGroup>
        ) : null}
      </div>
    </section>
  )
}

function ExplanationGroup({ children, title }: { children: ReactNode; title: string }) {
  return (
    <div>
      <div className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">{title}</div>
      <ul className="mt-2 space-y-2">{children}</ul>
    </div>
  )
}

function TargetExplanationGroup({ entries, title, tone }: { entries: TargetGraphTargetExplanation[]; title: string; tone: PillTone }) {
  const { t } = useT("settings")
  return (
    <ExplanationGroup title={title}>
      {(entries ?? []).map((entry) => (
        <li className="rounded border border-gray-200 p-3 dark:border-gray-700" key={`${entry.state}-${entry.target_label}`}>
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <TonePill tone={tone}>{entry.state}</TonePill>
            <span className="font-mono text-xs font-semibold text-gray-950 dark:text-gray-100">{entry.target_label}</span>
            {entry.required ? <TonePill tone="red">{t("target_graph.required")}</TonePill> : null}
          </div>
          {entry.project_label ? (
            <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("target_graph.project_label", { label: entry.project_label })}</div>
          ) : null}
          {entry.reason ? <div className="mt-1 text-xs text-gray-600 dark:text-gray-300">{entry.reason}</div> : null}
          <TargetHealthRefs entry={entry} />
        </li>
      ))}
    </ExplanationGroup>
  )
}

function TargetHealthRefs({ entry }: { entry: TargetGraphTargetExplanation }) {
  const refs = entry.target_health_record_refs ?? []
  if (refs.length === 0 && !entry.target_health_record_id) return null

  return (
    <div className="mt-2 flex flex-wrap gap-1.5 text-xs">
      {entry.target_health_record_id ? (
        <span className="rounded bg-gray-100 px-2 py-1 font-mono text-gray-700 dark:bg-gray-800 dark:text-gray-300">THR-{entry.target_health_record_id}</span>
      ) : null}
      {entry.commit_sha ? (
        <span className="rounded bg-gray-100 px-2 py-1 font-mono text-gray-700 dark:bg-gray-800 dark:text-gray-300">{entry.commit_sha.slice(0, 7)}</span>
      ) : null}
      {refs.map((ref, index) => (
        <span
          className="rounded bg-gray-100 px-2 py-1 font-mono text-gray-700 dark:bg-gray-800 dark:text-gray-300"
          key={`${ref.target_health_record_id}-${index}`}
        >
          THR-{ref.target_health_record_id ?? "?"}
          {ref.status ? ` ${ref.status}` : ""}
        </span>
      ))}
    </div>
  )
}

function TargetGraphToolbar({
  draft,
  overlaysAvailable,
  projects,
  query,
  onDraftChange,
  onSubmit,
  onUpdate
}: {
  draft: string
  overlaysAvailable: boolean
  projects: TargetGraphPayload["projects"]
  query: TargetGraphQuery
  onDraftChange: (value: string) => void
  onSubmit: (event: FormEvent) => void
  onUpdate: (query: TargetGraphQuery) => void
}) {
  const { t } = useT("settings")
  return (
    <section className="rounded border border-gray-200 bg-white p-2.5 dark:border-gray-700 dark:bg-gray-900">
      <div className="grid gap-2 lg:grid-cols-[minmax(16rem,1fr)_minmax(9rem,13rem)_7rem_minmax(9rem,12rem)]">
        <form className="flex min-w-0 gap-2" onSubmit={onSubmit}>
          <Input
            aria-label={t("target_graph.search_aria")}
            onChange={(event) => onDraftChange(event.target.value)}
            placeholder={t("target_graph.search_placeholder")}
            value={draft}
          />
          <Button type="submit">{query.mode === "window" ? t("target_graph.search") : t("target_graph.focus")}</Button>
        </form>
        <SelectControl
          label={t("target_graph.projects")}
          value={query.projectId || ""}
          onChange={(value) => onUpdate({ projectId: value || undefined, offset: 0 })}
        >
          <option value="">{t("target_graph.all_projects")}</option>
          {projects.map((project) => (
            <option key={project.id} value={project.id}>
              {project.label || project.id}
            </option>
          ))}
        </SelectControl>
        <SelectControl label={t("target_graph.depth")} value={String(query.depth ?? 1)} onChange={(value) => onUpdate({ depth: Number(value), offset: 0 })}>
          {[0, 1, 2, 3, 4].map((depth) => (
            <option key={depth} value={depth}>
              {depth}
            </option>
          ))}
        </SelectControl>
        <SelectControl
          label={t("target_graph.direction")}
          value={query.direction || "both"}
          onChange={(value) => onUpdate({ direction: value as TargetGraphQuery["direction"], offset: 0 })}
        >
          <option value="both">{t("target_graph.both")}</option>
          <option value="dependencies">{t("target_graph.dependencies")}</option>
          <option value="dependents">{t("target_graph.dependents")}</option>
        </SelectControl>
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <Button
          onClick={() => onUpdate({ mode: "window", focusLabel: undefined, focusState: undefined, offset: 0 })}
          size="sm"
          type="button"
          variant={query.mode === "window" ? "primary" : "secondary"}
        >
          {t("target_graph.browse")}
        </Button>
        <Button
          onClick={() => onUpdate({ mode: "neighborhood", focusLabel: draft || undefined, focusState: undefined, offset: 0 })}
          size="sm"
          type="button"
          variant={query.mode === "neighborhood" && !query.focusState ? "primary" : "secondary"}
        >
          {t("target_graph.neighborhood")}
        </Button>
        {!overlaysAvailable ? <span className="text-xs text-text-secondary">{t("target_graph.repository_overlay_note")}</span> : null}
      </div>
    </section>
  )
}

function SelectControl({ children, label, value, onChange }: { children: ReactNode; label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="block min-w-0 text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
      <span>{label}</span>
      <Select className="mt-1 normal-case" onChange={(event) => onChange(event.target.value)} value={value}>
        {children}
      </Select>
    </label>
  )
}

function TargetGraphSummary({ payload }: { payload: TargetGraphPayload }) {
  const { t } = useT("settings")
  const healthSummary = Object.entries(payload.health.summary).filter(([, count]) => count > 0)
  return (
    <section
      className="flex min-h-11 flex-wrap items-center gap-x-5 gap-y-2 rounded border border-border bg-surface px-3 py-2"
      aria-label={t("target_graph.summary")}
    >
      <CompactMetric label={t("target_graph.targets")} value={payload.page.total.toLocaleString()} />
      <CompactMetric label={t("target_graph.projects")} value={payload.projects.length.toLocaleString()} />
      <div className="flex items-center gap-1.5">
        <span className="text-xs text-gray-500 dark:text-gray-400">{t("target_graph.page_health")}</span>
        <div className="flex flex-wrap gap-1">
          {healthSummary.length === 0 ? <span className="text-sm text-gray-500 dark:text-gray-400">{t("target_graph.no_records_in_view")}</span> : null}
          {healthSummary.map(([status, count]) => (
            <TonePill key={status} tone={healthTone(status)}>
              {status} {count}
            </TonePill>
          ))}
        </div>
      </div>
      <span className="ml-auto text-xs text-gray-500 dark:text-gray-400">
        {payload.workflow ? t("target_graph.workflow_snapshot", { slug: payload.workflow.slug }) : t("target_graph.repository_snapshot")}
      </span>
    </section>
  )
}

function CompactMetric({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-baseline gap-1.5">
      <strong className="text-base text-gray-950 dark:text-gray-100">{value}</strong>
      <span className="text-xs text-gray-500 dark:text-gray-400">{label}</span>
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

function TargetGraphDecisionSummary({
  payload,
  query,
  overlaysAvailable,
  onUpdate
}: {
  payload: TargetGraphPayload
  query: TargetGraphQuery
  overlaysAvailable: boolean
  onUpdate: (query: TargetGraphQuery) => void
}) {
  const { t } = useT("settings")
  const counts = {
    selected: payload.explanations?.selected_targets?.length,
    skipped: payload.explanations?.skipped_targets?.length,
    cached: payload.explanations?.cached_targets?.length,
    failing: payload.health.summary.failed
  }
  const ambiguity = payload.explanations?.ambiguous?.find((entry) => entry.status !== "available")
  return (
    <section className="flex flex-wrap items-center gap-1.5 rounded border border-border bg-surface px-3 py-2" aria-label={t("target_graph.decision_summary")}>
      <span className="mr-1 text-xs font-semibold text-gray-700 dark:text-gray-200">{t("target_graph.decision_summary")}</span>
      <Button
        onClick={() => onUpdate({ mode: "window", focusLabel: undefined, focusState: undefined, offset: 0 })}
        size="sm"
        type="button"
        variant={!query.focusState ? "primary" : "secondary"}
      >
        {t("target_graph.all_with_count", { count: payload.page.total })}
      </Button>
      {FOCUS_STATES.map((state) => {
        const disabled = state !== "failing" && !overlaysAvailable
        return (
          <Button
            disabled={disabled}
            key={state}
            onClick={() => onUpdate({ mode: "neighborhood", focusLabel: undefined, focusState: state, search: undefined, q: undefined, offset: 0 })}
            size="sm"
            title={disabled ? t("target_graph.runtime_selection_unavailable") : undefined}
            type="button"
            variant={query.focusState === state ? "primary" : "secondary"}
          >
            {stateLabel(state, t)}
            {counts[state] !== undefined ? ` ${counts[state]}` : ""}
          </Button>
        )
      })}
      {ambiguity ? (
        <span className="ml-auto rounded bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-200">
          {ambiguityLabel(ambiguity.kind, t)}: {ambiguity.reason || ambiguity.status}
        </span>
      ) : null}
    </section>
  )
}

function TargetGraphTable({ rows, selectedLabel, onSelect }: { rows: TargetGraphRow[]; selectedLabel: string | null; onSelect: (label: string) => void }) {
  const { t } = useT("settings")
  const parentRef = useRef<HTMLDivElement | null>(null)
  const virtualizer = useVirtualizer({
    count: rows.length,
    estimateSize: () => 57,
    getScrollElement: () => parentRef.current,
    overscan: 8
  })
  const virtualRows = virtualizer.getVirtualItems()

  return (
    <div className="overflow-x-auto">
      <div className={TARGET_TABLE_HEADER_CLASS}>
        <span>{t("target_graph.target")}</span>
        <span>{t("target_graph.outcome")}</span>
        <span>{t("target_graph.decision_health")}</span>
        <span>{t("target_graph.project")}</span>
        <span>{t("target_graph.relationships")}</span>
      </div>
      <div className="h-[30rem] min-w-[52rem] overflow-auto" ref={parentRef} role="list">
        <div className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
          {virtualRows.map((virtualRow) => {
            const row = rows[virtualRow.index]
            if (!row) return null
            return (
              <div
                className="absolute left-0 top-0 w-full"
                data-index={virtualRow.index}
                key={virtualRow.key}
                ref={virtualizer.measureElement}
                role="listitem"
                style={virtualRowStyle(virtualRow.start)}
              >
                <TargetGraphRowButton row={row} selected={selectedLabel === row.target.label} onSelect={onSelect} />
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

function TargetGraphRowButton({ row, selected, onSelect }: { row: TargetGraphRow; selected: boolean; onSelect: (label: string) => void }) {
  const { t } = useT("settings")
  const target = row.target
  const outcome = target.selection?.state || (target.health?.status === "failed" ? "failing" : target.health?.status)
  return (
    <button
      aria-label={t("target_graph.open_target_details", { label: target.label })}
      aria-pressed={selected}
      className={`${TARGET_TABLE_ROW_CLASS} ${selected ? "bg-brand-muted shadow-[inset_3px_0_var(--color-brand)]" : ""}`}
      onClick={() => onSelect(target.label)}
      type="button"
    >
      <span className="min-w-0">
        <span className="block truncate font-mono font-semibold text-text-primary">{target.label}</span>
        <span className="mt-0.5 block truncate text-text-secondary">
          {target.kind}
          {target.executable_metadata?.command ? ` · ${target.executable_metadata.command}` : ""}
        </span>
      </span>
      <span>
        {outcome ? (
          <TonePill tone={outcome === "failing" ? "red" : target.selection?.state ? selectionTone(target.selection.state) : healthTone(outcome)}>
            {outcome}
          </TonePill>
        ) : (
          <span className="text-text-secondary">—</span>
        )}
      </span>
      <span className="line-clamp-2 text-text-secondary">
        {target.selection?.reason ||
          (target.health?.status ? t("target_graph.health_status", { status: target.health.status }) : t("target_graph.no_decision"))}
      </span>
      <span className="truncate text-text-secondary">{target.project?.label || target.project_id}</span>
      <span className="flex gap-1">
        <span className="rounded border border-border px-1.5 py-1">{t("target_graph.depends_on_count", { count: row.dependencies.length })}</span>
        <span className="rounded border border-border px-1.5 py-1">{t("target_graph.used_by_count", { count: row.dependents.length })}</span>
      </span>
    </button>
  )
}

function TargetDetailPanel({ row, onClose, onFocus }: { row: TargetGraphRow; onClose: () => void; onFocus: (label: string) => void }) {
  const { t } = useT("settings")
  const target = row.target
  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex justify-end bg-black/20"
      className="flex h-full w-full max-w-md flex-col bg-surface shadow-2xl"
      label={t("target_graph.target_details")}
      onClose={onClose}
      open
    >
      <div className="flex items-start justify-between gap-3 border-b border-border p-4">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-text-secondary">{t("target_graph.target_details")}</div>
          <h2 className="mt-1 truncate font-mono font-semibold">{target.label}</h2>
        </div>
        <Button aria-label={t("target_graph.close_details")} onClick={onClose} size="sm" type="button" variant="secondary">
          <CloseIcon />
        </Button>
      </div>
      <div className="flex-1 space-y-5 overflow-auto p-4 text-sm">
        <DetailSection title={t("target_graph.command")}>
          <code className="block rounded bg-surface-raised p-2 text-xs">{target.executable_metadata?.command || t("target_graph.no_command")}</code>
        </DetailSection>
        <DetailSection title={t("target_graph.project")}>
          <p>{target.project?.label || target.project_id}</p>
          {target.project?.path ? <code className="text-xs text-text-secondary">{target.project.path}</code> : null}
        </DetailSection>
        <DetailSection title={t("target_graph.decision_evidence")}>
          <p className="border-l-2 border-brand bg-brand-muted p-2 text-xs">{target.selection?.reason || t("target_graph.no_decision")}</p>
          {target.selection ? <TargetHealthRefs entry={{ target_label: target.label, ...target.selection }} /> : null}
          {target.health?.target_health_record_id ? (
            <div className="mt-2 font-mono text-xs">
              THR-{target.health.target_health_record_id} · {target.health.status}
            </div>
          ) : null}
        </DetailSection>
        <RelationshipList title={t("target_graph.depends_on")} empty={t("target_graph.no_dependencies")} labels={row.dependencies} onFocus={onFocus} />
        <RelationshipList title={t("target_graph.used_by")} empty={t("target_graph.no_dependents")} labels={row.dependents} onFocus={onFocus} />
      </div>
    </Modal>
  )
}

function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h3 className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-text-secondary">{title}</h3>
      {children}
    </section>
  )
}

const RELATIONSHIP_PAGE_SIZE = 50

function RelationshipList({ title, empty, labels, onFocus }: { title: string; empty: string; labels: string[]; onFocus: (label: string) => void }) {
  const { t } = useT("settings")
  const [visible, setVisible] = useState(RELATIONSHIP_PAGE_SIZE)
  const shown = labels.slice(0, visible)
  const remaining = labels.length - shown.length
  return (
    <DetailSection title={title}>
      <div className="divide-y divide-border">
        {labels.length === 0 ? (
          <p className="text-xs text-text-secondary">{empty}</p>
        ) : (
          shown.map((label) => (
            <button
              className="block w-full py-2 text-left font-mono text-xs text-brand hover:underline"
              key={label}
              onClick={() => onFocus(label)}
              type="button"
            >
              {label}
            </button>
          ))
        )}
      </div>
      {remaining > 0 ? (
        <button className="mt-2 text-xs font-medium text-brand hover:underline" onClick={() => setVisible((n) => n + RELATIONSHIP_PAGE_SIZE)} type="button">
          {t("target_graph.show_more_relationships", { batch: Math.min(remaining, RELATIONSHIP_PAGE_SIZE), remaining })}
        </button>
      ) : null}
    </DetailSection>
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

function stateLabel(state: (typeof FOCUS_STATES)[number], t: ReturnType<typeof useT>["t"]) {
  return state === "selected"
    ? t("target_graph.state_selected")
    : state === "failing"
      ? t("target_graph.state_failing")
      : state === "skipped"
        ? t("target_graph.state_skipped")
        : t("target_graph.state_cached")
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

function ambiguityLabel(kind: string, t: ReturnType<typeof useT>["t"]) {
  if (kind === "visual_review_preview_project") return t("target_graph.visual_review_preview_project")
  if (kind === "preview_project") return t("target_graph.preview_project")
  return kind.replace(/_/g, " ")
}
