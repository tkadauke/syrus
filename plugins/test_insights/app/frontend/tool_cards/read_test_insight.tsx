import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { CardShell, displayValue, EmptyState, EntityReference, InternalLink, numberValue, SectionLabel } from "@app/routes/chat/toolCardUi"
import {
  formatFailureRate,
  formatMs,
  parseFailure,
  parseReasons,
  parseRunJobRef,
  parseTestIdentityRef,
  ReasonBadges,
  RefLink,
  t,
  TestIdentityLink,
  TestStatusPill,
  type FailureSnippetData,
  type RunJobRef,
  type TestIdentityRef
} from "../testInsightToolCard"

type RepositoryRef = { id: string; slug: string; githubUrl: string | null }
type DurationPoint = { key: string; durationMs: number }
type TestDetail = TestIdentityRef & {
  fingerprint: string | null
  lastStatus: string | null
  failureRate: number | null
  avgDurationMs: number | null
  lastSeenAt: string | null
  lastFailedAt: string | null
  lastPassedAt: string | null
  lastDurationMs: number | null
  recentFailedCount: number | null
  recentPassedCount: number | null
  recentTotalCount: number | null
  reasons: string[]
}
type HistoryEntry = {
  key: string
  status: string | null
  classification: string | null
  durationMs: number | null
  createdAt: string | null
  graderName: string | null
  totalCount: number | null
  passedCount: number | null
  failedCount: number | null
  skippedCount: number | null
  errorCount: number | null
  runDurationMs: number | null
  run: RunJobRef | null
  job: RunJobRef | null
  failure: FailureSnippetData | null
  error: string | null
}
type Card = {
  repository: RepositoryRef | null
  test: TestDetail
  historyLimit: number | null
  history: HistoryEntry[]
  durationPoints: DurationPoint[]
  graderNames: string[]
  relatedRuns: RunJobRef[]
  relatedJobs: RunJobRef[]
  includeFailures: boolean | null
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-medium uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className="whitespace-pre-wrap break-all font-mono text-xs text-text-primary">{value}</dd>
    </div>
  )
}

function parseRepository(value: unknown): RepositoryRef | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id),
    slug = displayValue(value.slug)
  return id && slug ? { id, slug, githubUrl: displayValue(value.github_url) } : null
}

function parseTest(value: unknown): TestDetail | null {
  const ref = parseTestIdentityRef(value)
  if (!ref || !isPlainObject(value)) return null
  return {
    ...ref,
    fingerprint: displayValue(value.fingerprint),
    lastStatus: displayValue(value.last_status),
    failureRate: numberValue(value.failure_rate),
    avgDurationMs: numberValue(value.avg_duration_ms),
    lastSeenAt: displayValue(value.last_seen_at),
    lastFailedAt: displayValue(value.last_failed_at),
    lastPassedAt: displayValue(value.last_passed_at),
    lastDurationMs: numberValue(value.last_duration_ms),
    recentFailedCount: numberValue(value.recent_failure_count),
    recentPassedCount: numberValue(value.recent_pass_count),
    recentTotalCount: numberValue(value.recent_total_count),
    reasons: parseReasons(value, "reasons")
  }
}

function parseHistory(value: unknown, index: number): HistoryEntry | null {
  if (!isPlainObject(value)) return null
  const testCase = isPlainObject(value.test_case) ? value.test_case : null
  const testRun = isPlainObject(value.test_run) ? value.test_run : null
  const error = displayValue(value.error_serializing)
  if (!testCase && !error) return null
  return {
    key: displayValue(testCase?.id) ?? `degraded-${index}`,
    status: displayValue(testCase?.status),
    classification: displayValue(testCase?.classification),
    durationMs: numberValue(testCase?.duration_ms),
    createdAt: displayValue(testCase?.created_at),
    graderName: displayValue(testRun?.grader_name),
    totalCount: numberValue(testRun?.total_count),
    passedCount: numberValue(testRun?.passed_count),
    failedCount: numberValue(testRun?.failed_count),
    skippedCount: numberValue(testRun?.skipped_count),
    errorCount: numberValue(testRun?.error_count),
    runDurationMs: numberValue(testRun?.duration_ms),
    run: parseRunJobRef(value.run),
    job: parseRunJobRef(value.job),
    failure: parseFailure(value.failure),
    error
  }
}

function strings(value: unknown) {
  return Array.isArray(value)
    ? value.flatMap((item) => {
        const text = displayValue(item)
        return text ? [text] : []
      })
    : []
}
function relatedRef(slug: string, history: HistoryEntry[]): RunJobRef {
  const historyRef = history.flatMap((entry) => [entry.run, entry.job]).find((reference) => reference?.slug === slug)
  if (historyRef) return historyRef

  const jobId = slug.match(/^JOB-(\d+)$/)?.[1]
  return { slug, title: null, path: jobId ? `/jobs/${jobId}` : null }
}

function parseCard(context: ToolCardContext): Card | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const test = parseTest(parsed.test)
  if (!test) return null
  const related = isPlainObject(parsed.related) ? parsed.related : null
  const history = Array.isArray(parsed.history) ? parsed.history.flatMap((item, index) => parseHistory(item, index) ?? []) : []
  return {
    repository: parseRepository(parsed.repository),
    test,
    historyLimit: numberValue(parsed.history_limit),
    history,
    durationPoints: Array.isArray(parsed.duration_points)
      ? parsed.duration_points.flatMap((item, index) => {
          if (!isPlainObject(item)) return []
          const durationMs = numberValue(item.duration_ms)
          return durationMs == null ? [] : [{ key: displayValue(item.test_case_id) ?? String(index), durationMs }]
        })
      : [],
    graderNames: strings(related?.grader_names),
    relatedRuns: strings(related?.run_refs).map((slug) => relatedRef(slug, history)),
    relatedJobs: strings(related?.job_refs).map((slug) => relatedRef(slug, history)),
    includeFailures: typeof context.input?.include_failures === "boolean" ? context.input.include_failures : null
  }
}

function fileHref(repository: RepositoryRef | null, path: string | null) {
  return repository?.githubUrl && path ? `${repository.githubUrl}/blob/HEAD/${path.split("/").map(encodeURIComponent).join("/")}` : null
}

function RuntimeSparkline({ points }: { points: DurationPoint[] }) {
  if (!points.length) return <EmptyState>{t("tool_no_runtime_samples")}</EmptyState>
  const width = 240,
    height = 44,
    values = points.map(({ durationMs }) => durationMs),
    min = Math.min(...values),
    max = Math.max(...values)
  const coordinates = points
    .map(
      ({ durationMs }, index) =>
        `${points.length === 1 ? width / 2 : (index / (points.length - 1)) * width},${max === min ? height / 2 : height - 4 - ((durationMs - min) / (max - min)) * (height - 8)}`
    )
    .join(" ")
  return (
    <div className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <svg
        aria-label={t("tool_runtime_chart", { count: points.length })}
        className="h-11 w-full text-brand"
        preserveAspectRatio="none"
        role="img"
        viewBox={`0 0 ${width} ${height}`}
      >
        <polyline className="fill-none stroke-current" points={coordinates} strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
      </svg>
      <div className="flex flex-wrap justify-between gap-1 text-2xs text-text-muted">
        <span>{formatMs(min)}</span>
        <span>{formatMs(max)}</span>
      </div>
    </div>
  )
}

function failureText(value: unknown) {
  return typeof value === "string" ? value : isPlainObject(value) ? (displayValue(value.text) ?? "") : ""
}
function FailurePreview({ failure }: { failure: FailureSnippetData }) {
  const entries = [
    [t("tool_failure_message"), failureText(failure.message)],
    [t("tool_backtrace"), failureText(failure.backtrace)],
    [t("tool_output"), failureText(failure.output)]
  ].filter((entry): entry is [string, string] => Boolean(entry[1]))
  return (
    <div className="space-y-2">
      {entries.map(([title, text]) => (
        <TextPreview key={title} maxLines={4} modalLabel={title} text={text} title={title} />
      ))}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (card) return `${card.test.name} (${card.test.lastStatus ?? t("unknown")})`
  const id = displayValue(context.input?.test_identity_id)
  return context.resultError && id ? t("tool_test_error_summary", { id }) : null
}
function renderError(context: ToolCardContext) {
  if (!context.resultError) return null
  const message = isPlainObject(context.parsedResult) ? displayValue(context.parsedResult.error) : null
  const id = displayValue(context.input?.test_identity_id)
  return (
    <CardShell>
      <div className="break-words rounded bg-danger-surface px-2 py-1 text-danger-text">
        {message ?? displayValue(context.resultBody) ?? t("tool_unknown_error")}
      </div>
      {id ? (
        <dl>
          <DetailRow label={t("tool_test_id")} value={id} />
        </dl>
      ) : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return renderError(context)
  const href = fileHref(card.repository, card.test.filePath)
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <TestIdentityLink test={card.test} />
        <TestStatusPill status={card.test.lastStatus} />
        <ReasonBadges reasons={card.test.reasons} />
      </div>
      {card.repository ? <EntityReference id={card.repository.id} kind="repository" repositorySlug={card.repository.slug} slug={card.repository.slug} /> : null}
      {card.test.suiteName || card.test.filePath ? (
        <div className="min-w-0 break-words text-text-muted">
          {card.test.suiteName}
          {card.test.suiteName && card.test.filePath ? " · " : null}
          {card.test.filePath ? href ? <InternalLink href={href}>{card.test.filePath}</InternalLink> : card.test.filePath : null}
        </div>
      ) : null}
      <dl className="grid min-w-0 grid-cols-1 gap-x-3 gap-y-2 sm:grid-cols-2 xl:grid-cols-3">
        <DetailRow label={t("tool_test_id")} value={card.test.id} />
        {card.test.fingerprint ? <DetailRow label={t("tool_fingerprint")} value={card.test.fingerprint} /> : null}
        <DetailRow label={t("tool_col_failure_rate")} value={formatFailureRate(card.test.failureRate)} />
        <DetailRow label={t("tool_avg_duration")} value={formatMs(card.test.avgDurationMs)} />
        <DetailRow label={t("tool_last_duration")} value={formatMs(card.test.lastDurationMs)} />
        <DetailRow label={t("tool_last_seen")} value={card.test.lastSeenAt ?? "—"} />
        <DetailRow label={t("tool_last_failed")} value={card.test.lastFailedAt ?? "—"} />
        <DetailRow label={t("tool_last_passed")} value={card.test.lastPassedAt ?? "—"} />
        {card.test.recentTotalCount != null ? (
          <DetailRow
            label={t("tool_recent_record")}
            value={t("tool_recent_record_value", {
              failed: card.test.recentFailedCount ?? 0,
              passed: card.test.recentPassedCount ?? 0,
              total: card.test.recentTotalCount
            })}
          />
        ) : null}
        {card.includeFailures != null ? <DetailRow label={t("tool_include_failures")} value={card.includeFailures ? t("tool_yes") : t("tool_no")} /> : null}
      </dl>
      <div>
        <SectionLabel>{t("tool_runtime")}</SectionLabel>
        <RuntimeSparkline points={card.durationPoints} />
      </div>
      {card.graderNames.length || card.relatedRuns.length || card.relatedJobs.length ? (
        <div>
          <SectionLabel>{t("tool_related")}</SectionLabel>
          <div className="mt-1 flex flex-wrap items-center gap-2">
            {card.graderNames.map((name) => (
              <span className="break-all font-mono text-xs text-text-muted" key={name}>
                {name}
              </span>
            ))}
            {card.relatedRuns.map((ref) => (
              <RefLink key={ref.slug} target={ref} />
            ))}
            {card.relatedJobs.map((ref) => (
              <RefLink key={ref.slug} target={ref} />
            ))}
          </div>
        </div>
      ) : null}
      <div>
        <SectionLabel>
          {t("tool_recent_executions")}
          {card.historyLimit != null ? t("tool_recent_executions_limit", { count: card.historyLimit }) : ""}
        </SectionLabel>
        {card.history.length === 0 ? (
          <EmptyState>{t("tool_history_empty")}</EmptyState>
        ) : (
          <ul className="mt-1 space-y-2">
            {card.history.map((entry) => (
              <li className="min-w-0 space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface p-2" key={entry.key}>
                {entry.error ? (
                  <div className="break-words rounded bg-danger-surface px-2 py-1 text-danger-text">
                    {t("tool_serialization_error")}: {entry.error}
                  </div>
                ) : (
                  <>
                    <div className="flex min-w-0 flex-wrap items-center gap-2">
                      <TestStatusPill status={entry.status} />
                      {entry.classification ? <span className="break-all font-mono text-xs text-text-muted">{entry.classification}</span> : null}
                      <span className="font-mono text-xs text-text-muted">{formatMs(entry.durationMs)}</span>
                      {entry.createdAt ? <span className="break-all text-xs text-text-muted">{entry.createdAt}</span> : null}
                      <RefLink target={entry.run} />
                      <RefLink target={entry.job} />
                    </div>
                    <dl className="grid min-w-0 grid-cols-1 gap-x-3 gap-y-2 sm:grid-cols-2 xl:grid-cols-3">
                      {entry.graderName ? <DetailRow label={t("tool_setting_grader_name")} value={entry.graderName} /> : null}
                      {entry.totalCount != null ? (
                        <DetailRow
                          label={t("tool_test_run_counts")}
                          value={t("tool_test_run_counts_value", {
                            passed: entry.passedCount ?? 0,
                            failed: entry.failedCount ?? 0,
                            skipped: entry.skippedCount ?? 0,
                            errors: entry.errorCount ?? 0,
                            total: entry.totalCount
                          })}
                        />
                      ) : null}
                      {entry.runDurationMs != null ? <DetailRow label={t("tool_test_run_duration")} value={formatMs(entry.runDurationMs)} /> : null}
                    </dl>
                    {entry.failure ? <FailurePreview failure={entry.failure} /> : null}
                  </>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </CardShell>
  )
}

const card: ToolCardRenderer = { toolName: "read_test_insight", collapsedSummary, renderExpanded }
export default card

export const examples: ToolCardExample[] = [
  {
    id: "full_detail",
    label: "Runtime, related references, and rich history",
    input: { test_identity_id: 812, include_failures: true },
    parsedResult: {
      repository: { id: 7, slug: "acme/widgets", github_url: "https://github.com/acme/widgets" },
      test: {
        id: 812,
        name: "keeps the queue unblocked",
        suite_name: "QueueSpec",
        file_path: "spec/queue_spec.rb",
        fingerprint: "abc123",
        last_status: "failed",
        last_seen_at: "2026-10-18T10:00:00Z",
        last_failed_at: "2026-10-18T10:00:00Z",
        last_passed_at: "2026-10-17T10:00:00Z",
        last_duration_ms: 950,
        failure_rate: 0.5,
        avg_duration_ms: 800,
        recent_failure_count: 1,
        recent_pass_count: 1,
        recent_total_count: 2,
        reasons: ["failing"],
        links: { app_path: "/repositories/7?tab=tests&test_id=812" }
      },
      history_limit: 25,
      duration_points: [
        { test_case_id: 1, duration_ms: 700 },
        { test_case_id: 2, duration_ms: 950 }
      ],
      related: { grader_names: ["rspec"], run_refs: ["RUN-201"], job_refs: ["JOB-71"] },
      history: [
        {
          test_case: { id: 2, status: "failed", classification: "wip_repair_failure", duration_ms: 950, created_at: "2026-10-18T10:00:00Z" },
          test_run: { grader_name: "rspec", total_count: 20, passed_count: 18, failed_count: 1, skipped_count: 0, error_count: 1, duration_ms: 12000 },
          run: { slug: "RUN-201", path: "/admin/runs/201" },
          job: { slug: "JOB-71", path: "/jobs/71" },
          failure: { message: { text: "Expected true to be false", truncated: false } }
        }
      ]
    }
  },
  {
    id: "without_failures_empty",
    label: "Failures omitted and no history",
    input: { test_identity_id: 813, include_failures: false },
    parsedResult: { test: { id: 813, name: "pending test", last_status: "pending" }, history: [], duration_points: [], related: {} }
  },
  { id: "error", label: "Error response", input: { test_identity_id: 999999 }, parsedResult: { error: "Test identity not found" }, resultError: true },
  {
    id: "degraded_history",
    label: "Degraded history row",
    input: { test_identity_id: 812 },
    parsedResult: { test: { id: 812, name: "partially available" }, history: [{ test_case: { id: 9 }, error_serializing: "missing run association" }] }
  }
]
