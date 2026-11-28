import { useMemo, useSyncExternalStore } from "react"
import { useLocation } from "react-router-dom"
import { Button } from "@app/components/Button"
import { FilterBar, type FilterSchemaField } from "@app/components/FilterBar"
import { DataTable, Page, Section, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { spaLoaderDiagnostics } from "@app/pluginSdk"
import { buildCatalogFilterLink, catalogFilterTreeFromSearch, catalogFiltersFromSearch } from "../catalog/catalogFilterLink"

const FILTER_FIELDS = ["state", "group"] as const
const filterLink = buildCatalogFilterLink(FILTER_FIELDS)

function formatBytes(bytes: number | null) {
  if (bytes === null) return "—"
  return `${Math.round(bytes / 1024)} KB`
}

function formatTiming(timing: Record<string, unknown> | null, labels: { request: string; response: string; end: string }) {
  if (!timing) return null
  const values: Array<[string, unknown]> = [
    [labels.request, timing.request_start_ms],
    [labels.response, timing.response_start_ms],
    [labels.end, timing.response_end_ms]
  ]
  const formatted = values.flatMap(([label, value]) => typeof value === "number" ? [`${label} ${Math.round(value)} ms`] : [])
  return formatted.length ? formatted.join(" · ") : null
}

export function AdminSpaLoader() {
  const { t } = useT("syrus_dev")
  usePageTitle(t("spa_loader.heading"))
  const { pathname, search } = useLocation()
  const snapshot = useSyncExternalStore(spaLoaderDiagnostics.subscribe, spaLoaderDiagnostics.snapshot, spaLoaderDiagnostics.snapshot)
  const filters = useMemo(() => catalogFiltersFromSearch(FILTER_FIELDS, search), [search])
  const filterTree = useMemo(() => catalogFilterTreeFromSearch(FILTER_FIELDS, [], search), [search])
  const groups = useMemo(() => Array.from(new Set(snapshot.warmup.entries.map((entry) => entry.group).filter(Boolean))).sort() as string[], [snapshot])
  const schema: FilterSchemaField[] = [
    { field: "state", label: t("spa_loader.state"), bucket: "select", operators: ["is"], values: ["not_loaded", "queued", "loading", "loaded", "failed"].map((value) => ({ value, label: t(`spa_loader.states.${value}`) })) },
    { field: "group", label: t("spa_loader.group"), bucket: "select", operators: ["is"], values: groups.map((value) => ({ value, label: value })) }
  ]
  const entries = snapshot.warmup.entries.filter((entry) => (!filters.state || entry.state === filters.state) && (!filters.group || entry.group === filters.group))
  const startup = snapshot.startup
  const queuedEntries = snapshot.warmup.queue.map((id) => snapshot.warmup.entries.find((entry) => entry.id === id)).filter((entry) => entry !== undefined)
  const diagnosticValue = (category: string, value: string) => t(`spa_loader.${category}.${value}`)

  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header className="flex items-end justify-between gap-4 border-b border-border pb-4">
        <Page.HeadingGroup>
          <Text as="p" muted variant="label">{t("section_label")}</Text>
          <Page.Title>{t("spa_loader.heading")}</Page.Title>
          <Page.Description>{t("spa_loader.description")}</Page.Description>
        </Page.HeadingGroup>
        <div className="flex gap-2">
          <Button onClick={() => spaLoaderDiagnostics.warmEverythingNow()}>{t("spa_loader.warm_now")}</Button>
          <Button onClick={() => spaLoaderDiagnostics.clearWarmupState()} variant="secondary">{t("spa_loader.clear")}</Button>
        </div>
      </Page.Header>

      <Section.Root>
        <Section.Header><Section.Title>{t("spa_loader.queue")}</Section.Title></Section.Header>
        <Section.Body className="space-y-2">
          <Text>{t("spa_loader.loading_now")}: {snapshot.warmup.loading ?? t("spa_loader.none")}</Text>
          <Text>{t("spa_loader.pause_reasons")}: {snapshot.warmup.pauseReasons.length ? snapshot.warmup.pauseReasons.map((reason) => t(`spa_loader.reasons.${reason}`)).join(", ") : t("spa_loader.none")}</Text>
          <Text>{t("spa_loader.queued_order")}: {queuedEntries.map((entry) => t("spa_loader.queue_entry", { id: entry.id, group: entry.group ?? t("spa_loader.none"), priority: entry.priority })).join(" → ") || t("spa_loader.none")}</Text>
          {snapshot.warmup.stoppedAfterFailure ? <Text tone="danger">{t("spa_loader.stopped")}</Text> : null}
        </Section.Body>
      </Section.Root>

      <Section.Root>
        <Section.Header><Section.Title>{t("spa_loader.registry")}</Section.Title></Section.Header>
        <Section.Body className="space-y-4">
          <FilterBar buildLink={filterLink} filter={filterTree} filterSchema={schema} pathname={pathname} search={search} />
          <DataTable.Root density="compact">
            <DataTable.Header><DataTable.Row>{["id", "group", "priority", "state", "size", "source", "started", "duration"].map((key) => <DataTable.HeadCell key={key}>{t(`spa_loader.${key}`)}</DataTable.HeadCell>)}</DataTable.Row></DataTable.Header>
            <DataTable.Body>{entries.map((entry) => <DataTable.Row key={entry.id}>
              <DataTable.Cell className="font-mono">{entry.id}</DataTable.Cell><DataTable.Cell>{entry.group ?? "—"}</DataTable.Cell><DataTable.Cell>{entry.priority}</DataTable.Cell><DataTable.Cell>{t(`spa_loader.states.${entry.state}`)}</DataTable.Cell><DataTable.Cell>{formatBytes(entry.size)}</DataTable.Cell><DataTable.Cell>{entry.source ? t(`spa_loader.sources.${entry.source}`) : "—"}</DataTable.Cell><DataTable.Cell>{entry.startedAt === null ? "—" : `${Math.round(entry.startedAt)} ms`}</DataTable.Cell><DataTable.Cell>{entry.durationMs === null ? "—" : `${Math.round(entry.durationMs)} ms`}</DataTable.Cell>
            </DataTable.Row>)}</DataTable.Body>
          </DataTable.Root>
        </Section.Body>
      </Section.Root>

      <div className="grid gap-6 xl:grid-cols-2">
        <DiagnosticSection title={t("spa_loader.timeline")} rows={[
          ...(startup?.milestones ?? []).map((item) => [item.name, `${Math.round(item.at_ms)} ms`]),
          ...(startup?.progress_samples ?? []).map((item) => [t("spa_loader.progress_sample"), `${Math.round(item.at)} ms · ${formatBytes(item.bytes)}`]),
          ...(startup?.progress?.speed ? [[t("spa_loader.speed"), `${formatBytes(startup.progress.speed)}/s`]] : []),
          ...(startup?.revision.changed ? [[t("spa_loader.revision_change"), `${startup.revision.previous ?? t("spa_loader.none")} → ${startup.revision.page}`]] : []),
          ...(startup?.current_state ? [[t("spa_loader.current_state"), diagnosticValue("event_kinds", startup.current_state)]] : []),
          ...(startup?.last_problem_state ? [[t("spa_loader.last_problem_state"), diagnosticValue("event_kinds", startup.last_problem_state)]] : []),
          ...(startup ? [[t("spa_loader.retry_attempts"), String(startup.maximum_auto_retry_attempt)]] : [])
        ]} empty={t("spa_loader.no_data")} />
        <DiagnosticSection title={t("spa_loader.startup_assets")} rows={[
          ...(startup?.budget ? [[t("spa_loader.budget"), `${formatBytes(startup.assets.reduce((total, asset) => total + (asset.budget_size ?? 0), 0))} / ${formatBytes(startup.budget.bytes)}`]] : []),
          ...(startup?.assets ?? []).map((item) => {
            const timing = formatTiming(item.timing, { request: t("spa_loader.timing_request"), response: t("spa_loader.timing_response"), end: t("spa_loader.timing_end") })
            return [item.path, `${formatBytes(item.bytes)} / ${formatBytes(item.wire_size)}${item.budget_size !== null && startup?.budget ? ` · ${Math.round((item.budget_size / startup.budget.bytes) * 100)}%` : ""} · ${diagnosticValue("asset_sources", item.source)}${timing ? ` · ${timing}` : ""}`]
          })
        ]} empty={t("spa_loader.no_data")} />
        <DiagnosticSection title={t("spa_loader.service_worker")} rows={startup ? [[t("spa_loader.present"), diagnosticValue("booleans", String(startup.service_worker.present))], [t("spa_loader.controlled"), diagnosticValue("booleans", String(startup.service_worker.controlled))], [t("spa_loader.registration"), startup.service_worker.registration ? diagnosticValue("worker_states", startup.service_worker.registration.active ?? startup.service_worker.registration.waiting ?? startup.service_worker.registration.installing ?? "unknown") : t("spa_loader.none")], [t("spa_loader.revision"), `${startup.service_worker.worker_revision ?? "?"} / ${startup.revision.page}`], [t("spa_loader.counted"), startup.service_worker.counted_requests.join(", ") || t("spa_loader.none")]] : []} empty={t("spa_loader.no_data")} />
        <DiagnosticSection title={t("spa_loader.recovery")} rows={(startup?.events ?? []).map((item) => [diagnosticValue("event_kinds", item.kind), [item.outcome ? t(`spa_loader.outcomes.${item.outcome}`) : null, item.attempt ? `#${item.attempt}` : null, item.revision ?? null, `${Math.round(item.at_ms)} ms`].filter(Boolean).join(" · ")])} empty={t("spa_loader.no_events")} />
      </div>
    </Page.Root>
  )
}

function DiagnosticSection({ title, rows, empty }: { title: string; rows: string[][]; empty: string }) {
  return <Section.Root><Section.Header><Section.Title>{title}</Section.Title></Section.Header><Section.Body>{rows.length ? <dl className="space-y-2">{rows.map(([label, value], index) => <div className="flex justify-between gap-4" key={`${label}-${index}`}><dt className="font-mono text-sm">{label}</dt><dd className="text-right text-sm text-muted-foreground">{value}</dd></div>)}</dl> : <Text muted>{empty}</Text>}</Section.Body></Section.Root>
}

export default AdminSpaLoader
