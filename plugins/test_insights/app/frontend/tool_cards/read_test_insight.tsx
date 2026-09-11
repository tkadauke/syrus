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
    ? parsed.history.flatMap((entry, index) => {
        const parsedEntry = parseHistoryEntry(entry, index)
        return parsedEntry ? [parsedEntry] : []
      })
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

  return `${card.test.name} (${card.test.lastStatus ?? "unknown"})`
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
        <div className="text-gray-500 dark:text-gray-400">{[card.test.suiteName, card.test.filePath].filter(Boolean).join(" · ")}</div>
      ) : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Test ID" value={card.test.id} />
        {card.test.fingerprint ? <Row label="Fingerprint" value={card.test.fingerprint.slice(0, 12)} /> : null}
        <Row label="Failure rate" value={formatFailureRate(card.test.failureRate)} />
        <Row label="Avg duration" value={formatMs(card.test.avgDurationMs)} />
        {card.test.recentTotalCount != null ? (
          <Row
            label="Recent record"
            value={`${card.test.recentFailedCount ?? 0} failed / ${card.test.recentPassedCount ?? 0} passed of ${card.test.recentTotalCount}`}
          />
        ) : null}
      </dl>
      {card.history.length > 0 ? (
        <div>
          <SectionLabel>Recent executions{card.historyLimit != null ? ` (up to ${card.historyLimit})` : ""}</SectionLabel>
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
                {entry.failure ? (
                  <div className="mt-1">
                    <FailureSnippet failure={entry.failure} />
                  </div>
                ) : null}
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
