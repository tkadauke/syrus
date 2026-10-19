import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference, InternalLink, numberValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import {
  formatFailureRate,
  formatMs,
  parseReasons,
  parseRunJobRef,
  ReasonBadges,
  RefLink,
  t,
  TestIdentityLink,
  TestStatusPill,
  type TestIdentityRef
} from "../testInsightToolCard"

type RepositoryRef = { id: string; slug: string; githubUrl: string | null }
type RuntimeSummary = { sampleCount: number | null; p50: number | null; p95: number | null }
type TestRow = TestIdentityRef & {
  lastStatus: string | null
  lastSeenAt: string | null
  lastFailedAt: string | null
  lastDurationMs: number | null
  avgDurationMs: number | null
  totalCount: number | null
  failedCount: number | null
  passedCount: number | null
  failureRate: number | null
  fingerprint: string | null
  reasons: string[]
  runtime: RuntimeSummary | null
  run: ReturnType<typeof parseRunJobRef>
  job: ReturnType<typeof parseRunJobRef>
  workflow: ReturnType<typeof parseRunJobRef>
  error: string | null
}
type ListCard = { repository: RepositoryRef | null; rows: TestRow[]; settings: Array<[string, string]> }

function parseRepository(value: unknown): RepositoryRef | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  if (!id || !slug) return null
  return { id, slug, githubUrl: displayValue(value.github_url) }
}

function parseRow(value: unknown, index: number): TestRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id) ?? String(index)
  const name = displayValue(value.name)
  const error = displayValue(value.error_serializing)
  if (!name && !error) return null
  const links = isPlainObject(value.links) ? value.links : null
  const runtime = isPlainObject(value.runtime_summary) ? value.runtime_summary : null
  const latest = isPlainObject(value.latest) ? value.latest : null
  return {
    id,
    name: name ?? t("tool_unavailable_test"),
    suiteName: displayValue(value.suite_name),
    filePath: displayValue(value.file_path),
    appPath: links ? displayValue(links.app_path) : null,
    lastStatus: displayValue(value.last_status),
    lastSeenAt: displayValue(value.last_seen_at),
    lastFailedAt: displayValue(value.last_failed_at),
    lastDurationMs: numberValue(value.last_duration_ms),
    avgDurationMs: numberValue(value.avg_duration_ms),
    totalCount: numberValue(value.total_count),
    failedCount: numberValue(value.failed_count),
    passedCount: numberValue(value.passed_count),
    failureRate: numberValue(value.failure_rate),
    fingerprint: displayValue(value.fingerprint),
    reasons: parseReasons(value, "interesting_reasons"),
    runtime: runtime
      ? { sampleCount: numberValue(runtime.sample_count), p50: numberValue(runtime.p50_duration_ms), p95: numberValue(runtime.p95_duration_ms) }
      : null,
    run: parseRunJobRef(latest?.run),
    job: parseRunJobRef(latest?.job),
    workflow: parseRunJobRef(latest?.workflow),
    error
  }
}

function settingEntries(parsed: Record<string, unknown>, input: Record<string, unknown> | undefined): Array<[string, string]> {
  const entries: Array<[string, string]> = []
  for (const key of ["filter", "sort", "direction", "query", "grader_name", "lookback", "summary_window", "limit"] as const) {
    const value = displayValue(parsed[key])
    if (value) entries.push([t(`tool_setting_${key}`), value])
  }
  const filters = isPlainObject(parsed.filters) ? parsed.filters : isPlainObject(input?.filters) ? input.filters : null
  if (filters) {
    for (const [key, raw] of Object.entries(filters)) {
      const value = displayValue(raw)
      if (value) entries.push([key.replaceAll("_", " "), value])
    }
  }
  return entries
}

function parseCard(context: ToolCardContext): ListCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tests)) return null
  return {
    repository: parseRepository(parsed.repository),
    rows: parsed.tests.flatMap((test, index) => {
      const row = parseRow(test, index)
      return row ? [row] : []
    }),
    settings: settingEntries(parsed, context.input)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  return card.repository
    ? t("tool_repository_tests_summary", { count: card.rows.length, repository: card.repository.slug })
    : t("tool_tests_summary", { count: card.rows.length })
}

function fileHref(repository: RepositoryRef | null, filePath: string | null) {
  if (!repository?.githubUrl || !filePath) return null
  return `${repository.githubUrl}/blob/HEAD/${filePath.split("/").map(encodeURIComponent).join("/")}`
}

function TestRowCard({ row, repository }: { row: TestRow; repository: RepositoryRef | null }) {
  const href = fileHref(repository, row.filePath)
  return (
    <li className="min-w-0 space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface p-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <TestIdentityLink test={row} />
        <TestStatusPill status={row.lastStatus} />
        <ReasonBadges reasons={row.reasons} />
      </div>
      {row.error ? (
        <div className="break-words rounded bg-danger-surface px-2 py-1 text-danger-text">
          {t("tool_serialization_error")}: {row.error}
        </div>
      ) : null}
      {row.suiteName || row.filePath ? (
        <div className="min-w-0 break-words text-text-muted">
          {row.suiteName}
          {row.suiteName && row.filePath ? " · " : null}
          {row.filePath ? href ? <InternalLink href={href}>{row.filePath}</InternalLink> : row.filePath : null}
        </div>
      ) : null}
      <dl className="grid min-w-0 grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-4">
        <Row label={t("tool_col_failure_rate")} value={formatFailureRate(row.failureRate)} />
        <Row label={t("tool_avg_duration")} value={formatMs(row.avgDurationMs)} />
        <Row label={t("tool_last_duration")} value={formatMs(row.lastDurationMs)} />
        <Row
          label={t("tool_recent_record")}
          value={
            row.totalCount == null ? "—" : t("tool_recent_record_value", { failed: row.failedCount ?? 0, passed: row.passedCount ?? 0, total: row.totalCount })
          }
        />
        <Row label={t("tool_last_seen")} value={row.lastSeenAt ?? "—"} />
        <Row label={t("tool_last_failed")} value={row.lastFailedAt ?? "—"} />
        <Row
          label={t("tool_runtime_p50_p95")}
          value={row.runtime ? `${formatMs(row.runtime.p50)} / ${formatMs(row.runtime.p95)} (${row.runtime.sampleCount ?? 0})` : "—"}
        />
        <Row label={t("tool_fingerprint")} value={row.fingerprint ?? "—"} />
      </dl>
      {row.run || row.job || row.workflow ? (
        <div className="flex flex-wrap items-center gap-2">
          <RefLink target={row.run} />
          <RefLink target={row.workflow} />
          <RefLink target={row.job} />
        </div>
      ) : null}
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  return (
    <CardShell>
      {card.repository ? <EntityReference id={card.repository.id} kind="repository" repositorySlug={card.repository.slug} slug={card.repository.slug} /> : null}
      {card.settings.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_query_settings")}</SectionLabel>
          <dl className="mt-1 grid min-w-0 grid-cols-2 gap-x-3 gap-y-2 sm:grid-cols-4">
            {card.settings.map(([label, value]) => (
              <Row key={label} label={label} value={value} />
            ))}
          </dl>
        </div>
      ) : null}
      {card.rows.length === 0 ? (
        <EmptyState>{t("tool_list_empty")}</EmptyState>
      ) : (
        <ul className="space-y-2">
          {card.rows.map((row) => (
            <TestRowCard key={row.id} repository={card.repository} row={row} />
          ))}
        </ul>
      )}
    </CardShell>
  )
}

const listRepositoryTestInsightsToolCard: ToolCardRenderer = { toolName: "list_repository_test_insights", collapsedSummary, renderExpanded }
export default listRepositoryTestInsightsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_tests",
    label: "Repository tests with runtime and latest references",
    input: { repository: "acme/widgets", filter: "failing" },
    parsedResult: {
      repository: { id: 7, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" },
      filter: "failing",
      sort: "last_failed",
      direction: "desc",
      lookback: 50,
      summary_window: 100,
      limit: 25,
      tests: [
        {
          id: 42,
          suite_name: "WidgetSpec",
          name: "renders a widget",
          file_path: "spec/widgets/widget_spec.rb",
          fingerprint: "abc123",
          last_status: "failed",
          last_seen_at: "2026-10-18T10:00:00Z",
          last_failed_at: "2026-10-18T10:00:00Z",
          last_duration_ms: 1200,
          total_count: 10,
          failed_count: 2,
          passed_count: 8,
          failure_rate: 0.2,
          avg_duration_ms: 1000,
          runtime_summary: { sample_count: 10, p50_duration_ms: 900, p95_duration_ms: 1400 },
          interesting_reasons: ["failing", "slow"],
          links: { app_path: "/repositories/7?tab=tests&test_id=42" },
          latest: { run: { slug: "RUN-9", path: "/jobs/3?tab=workflows#run-9" }, job: { slug: "JOB-3", path: "/jobs/3" } }
        }
      ]
    }
  },
  {
    id: "degraded_and_pending",
    label: "Degraded and pending rows",
    parsedResult: {
      repository: { id: 7, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" },
      tests: [
        { id: 43, name: "queued test", last_status: "pending" },
        { id: 44, error_serializing: "broken association" }
      ]
    }
  },
  {
    id: "empty",
    label: "No matching tests",
    parsedResult: { repository: { id: 7, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" }, tests: [] }
  }
]
