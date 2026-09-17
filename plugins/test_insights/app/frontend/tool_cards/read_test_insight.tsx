import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, numberValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import {
  FailureSnippet,
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
  type TestIdentityRef
} from "../testInsightToolCard"

// Plugin-owned tool card for read_test_insight (the pending-action tool-card work). Lives entirely
// inside the test_insights plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
type TestDetail = TestIdentityRef & {
  fingerprint: string | null
  lastStatus: string | null
  failureRate: number | null
  avgDurationMs: number | null
  recentFailedCount: number | null
  recentPassedCount: number | null
  recentTotalCount: number | null
  reasons: string[]
}

type HistoryEntry = {
  key: string
  status: string | null
  durationMs: number | null
  createdAt: string | null
  graderName: string | null
  run: ReturnType<typeof parseRunJobRef>
  job: ReturnType<typeof parseRunJobRef>
  failure: ReturnType<typeof parseFailure>
}

type ReadTestInsightCard = {
  test: TestDetail
  historyLimit: number | null
  history: HistoryEntry[]
}

function parseTestDetail(value: unknown): TestDetail | null {
  const ref = parseTestIdentityRef(value)
  if (!ref || !isPlainObject(value)) return null

  return {
    ...ref,
    fingerprint: displayValue(value.fingerprint),
    lastStatus: displayValue(value.last_status),
    failureRate: numberValue(value.failure_rate),
    avgDurationMs: numberValue(value.avg_duration_ms),
    recentFailedCount: numberValue(value.recent_failure_count),
    recentPassedCount: numberValue(value.recent_pass_count),
    recentTotalCount: numberValue(value.recent_total_count),
    reasons: parseReasons(value, "reasons")
  }
}

function parseHistoryEntry(value: unknown, index: number): HistoryEntry | null {
  if (!isPlainObject(value)) return null

  const testCase = isPlainObject(value.test_case) ? value.test_case : null
  const testRun = isPlainObject(value.test_run) ? value.test_run : null

  return {
    key: displayValue(testCase?.id) ?? String(index),
    status: displayValue(testCase?.status),
    durationMs: numberValue(testCase?.duration_ms),
    createdAt: displayValue(testCase?.created_at),
    graderName: displayValue(testRun?.grader_name),
    run: parseRunJobRef(value.run),
    job: parseRunJobRef(value.job),
    failure: parseFailure(value.failure)
  }
}

function parseCard(context: ToolCardContext): ReadTestInsightCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const test = parseTestDetail(parsed.test)
  if (!test) return null

  const history = Array.isArray(parsed.history)
    ? parsed.history.flatMap((entry, index) => { const parsedEntry = parseHistoryEntry(entry, index); return parsedEntry ? [parsedEntry] : [] })
    : []

  return {
    test,
    historyLimit: numberValue(parsed.history_limit),
    history
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return `${card.test.name} (${card.test.lastStatus ?? t("unknown")})`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <TestIdentityLink test={card.test} />
        <TestStatusPill status={card.test.lastStatus} />
        <ReasonBadges reasons={card.test.reasons} />
      </div>
      {card.test.suiteName || card.test.filePath ? (
        <div className="text-gray-500 dark:text-gray-400">{[ card.test.suiteName, card.test.filePath ].filter(Boolean).join(" · ")}</div>
      ) : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("tool_test_id")} value={card.test.id} />
        {card.test.fingerprint ? <Row label={t("tool_fingerprint")} value={card.test.fingerprint.slice(0, 12)} /> : null}
        <Row label={t("tool_col_failure_rate")} value={formatFailureRate(card.test.failureRate)} />
        <Row label={t("tool_avg_duration")} value={formatMs(card.test.avgDurationMs)} />
        {card.test.recentTotalCount != null ? (
          <Row label={t("tool_recent_record")} value={t("tool_recent_record_value", { failed: card.test.recentFailedCount ?? 0, passed: card.test.recentPassedCount ?? 0, total: card.test.recentTotalCount })} />
        ) : null}
      </dl>
      {card.history.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_recent_executions")}{card.historyLimit != null ? t("tool_recent_executions_limit", { count: card.historyLimit }) : ""}</SectionLabel>
          <ul className="mt-1 space-y-2 rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
            {card.history.map((entry) => (
              <li className="border-b border-gray-100 pb-2 last:border-0 last:pb-0 dark:border-gray-800" key={entry.key}>
                <div className="flex flex-wrap items-center gap-2">
                  <TestStatusPill status={entry.status} />
                  <span className="font-mono text-gray-600 dark:text-gray-300">{formatMs(entry.durationMs)}</span>
                  {entry.createdAt ? <span className="text-gray-400 dark:text-gray-500">{entry.createdAt}</span> : null}
                  {entry.graderName ? <span className="text-gray-400 dark:text-gray-500">{entry.graderName}</span> : null}
                  <RefLink target={entry.run} />
                  <RefLink target={entry.job} />
                </div>
                {entry.failure ? <div className="mt-1"><FailureSnippet failure={entry.failure} /></div> : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </CardShell>
  )
}

const readTestInsightToolCard: ToolCardRenderer = {
  toolName: "read_test_insight",
  collapsedSummary,
  renderExpanded
}

export default readTestInsightToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "flaky_test_with_history",
    label: "Flaky test with recent history",
    input: { test_identity_id: 812 },
    parsedResult: {
      test: {
        id: "812",
        name: "keeps the landing queue unblocked after a transient GitHub 500",
        suite_name: "LandingQueueProcessor",
        file_path: "spec/services/landing_queue_processor_spec.rb",
        links: { app_path: "/test_insights/identities/812" },
        last_status: "flaky",
        failure_rate: 0.18,
        avg_duration_ms: 842,
        recent_failure_count: 3,
        recent_pass_count: 14,
        recent_total_count: 17,
        reasons: ["timing", "external_dependency"]
      },
      history_limit: 5,
      history: [
        {
          test_case: { id: 1, status: "failed", duration_ms: 950, created_at: "2026-09-15T10:02:00Z" },
          test_run: { grader_name: "rspec" },
          run: { slug: "RUN-201", path: "/admin/runs/201", title: "RUN-201" },
          job: { slug: "JOB-71", path: "/jobs/71", title: "JOB-71" },
          failure: { message: "expected 1 retryable job, got 0", backtrace: "spec/services/landing_queue_processor_spec.rb:112:in 'block'" }
        },
        {
          test_case: { id: 2, status: "passed", duration_ms: 780, created_at: "2026-09-14T09:41:00Z" },
          test_run: { grader_name: "rspec" },
          run: { slug: "RUN-198", path: "/admin/runs/198", title: "RUN-198" },
          job: { slug: "JOB-68", path: "/jobs/68", title: "JOB-68" }
        }
      ]
    }
  },
  {
    id: "malformed_missing_test",
    label: "Malformed: missing test key",
    description: "No `test` object in the payload -- renderExpanded/collapsedSummary both return null so the generic fallback body renders instead.",
    input: { test_identity_id: 999999 },
    parsedResult: { error: "Test identity not found" }
  }
]
