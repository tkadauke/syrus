import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, displayValue, EmptyState, numberValue } from "@app/routes/chat/toolCardUi"
import { formatMs, parseTestIdentityRef, TableShell, TestIdentityLink, type TestIdentityRef } from "../testInsightToolCard"

// Plugin-owned tool card for compare_test_runtime (EPIC-292). Lives entirely
// inside the test_insights plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
const REGRESSION_THRESHOLD_PERCENT = 10

type DurationStats = {
  avgDurationMs: number | null
  p95DurationMs: number | null
}

type Delta = { ms: number; percent: number | null } | null

type ComparisonRow = {
  test: TestIdentityRef
  baseline: DurationStats
  comparison: DurationStats
  avgDelta: Delta
}

type SourceDescriptor = { label: string }

function parseStats(value: unknown): DurationStats {
  if (!isPlainObject(value)) return { avgDurationMs: null, p95DurationMs: null }

  return {
    avgDurationMs: numberValue(value.avg_duration_ms),
    p95DurationMs: numberValue(value.p95_duration_ms)
  }
}

function parseDelta(value: unknown): Delta {
  if (!isPlainObject(value)) return null
  const ms = numberValue(value.ms)
  if (ms == null) return null

  return { ms, percent: numberValue(value.percent) }
}

function parseRow(value: unknown): ComparisonRow | null {
  if (!isPlainObject(value)) return null
  const test = parseTestIdentityRef(value.test)
  if (!test) return null

  const delta = isPlainObject(value.delta) ? value.delta : null

  return {
    test,
    baseline: parseStats(value.baseline),
    comparison: parseStats(value.comparison),
    avgDelta: parseDelta(delta?.avg_duration_ms)
  }
}

function describeSource(value: unknown): SourceDescriptor {
  if (!isPlainObject(value)) return { label: "unknown" }

  const type = displayValue(value.type)
  if (type === "run") return { label: displayValue(value.run_slug) ?? `run ${displayValue(value.run_id) ?? "?"}` }
  if (type === "job") return { label: displayValue(value.job_slug) ?? `job ${displayValue(value.job_id) ?? "?"}` }
  if (type === "window") {
    const starts = displayValue(value.starts_at)
    const ends = displayValue(value.ends_at)
    return { label: starts && ends ? `${starts} → ${ends}` : "time window" }
  }

  return { label: displayValue(value.label) ?? "unknown" }
}

type CompareCard = {
  graderName: string | null
  baseline: SourceDescriptor
  comparison: SourceDescriptor
  rows: ComparisonRow[]
}

function parseCard(context: ToolCardContext): CompareCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tests)) return null

  return {
    graderName: displayValue(parsed.grader_name),
    baseline: describeSource(parsed.baseline),
    comparison: describeSource(parsed.comparison),
    rows: parsed.tests.flatMap((test) => {
      const row = parseRow(test)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return `${card.rows.length} test${card.rows.length === 1 ? "" : "s"}: ${card.baseline.label} vs ${card.comparison.label}`
}

function deltaTone(delta: Delta): "regressed" | "improved" | "flat" {
  if (!delta || delta.percent == null) return "flat"
  if (delta.percent >= REGRESSION_THRESHOLD_PERCENT) return "regressed"
  if (delta.percent <= -REGRESSION_THRESHOLD_PERCENT) return "improved"
  return "flat"
}

const DELTA_CLASSES: Record<ReturnType<typeof deltaTone>, string> = {
  regressed: "text-red-700 dark:text-red-300",
  improved: "text-emerald-700 dark:text-emerald-300",
  flat: "text-gray-600 dark:text-gray-300"
}

function DeltaCell({ delta }: { delta: Delta }) {
  if (!delta) return <span className="text-gray-400 dark:text-gray-500">—</span>

  const tone = deltaTone(delta)
  const sign = delta.ms > 0 ? "+" : ""

  return (
    <span className={`font-mono ${DELTA_CLASSES[tone]}`}>
      {sign}{Math.round(delta.ms)}ms{delta.percent != null ? ` (${sign}${delta.percent}%)` : ""}
    </span>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  if (card.rows.length === 0) return <EmptyState>No matching tests to compare.</EmptyState>

  return (
    <div className="mt-1 space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
        <Badge>baseline: {card.baseline.label}</Badge>
        <Badge>comparison: {card.comparison.label}</Badge>
        {card.graderName ? <Badge>{card.graderName}</Badge> : null}
      </div>
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">Test</th>
              <th className="px-2 py-1 font-semibold" scope="col">Baseline avg / p95</th>
              <th className="px-2 py-1 font-semibold" scope="col">Comparison avg / p95</th>
              <th className="px-2 py-1 font-semibold" scope="col">Avg delta</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {card.rows.map((row) => (
              <tr key={row.test.id}>
                <td className="max-w-[16rem] px-2 py-1 text-gray-800 dark:text-gray-200">
                  <TestIdentityLink test={row.test} />
                </td>
                <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">
                  {formatMs(row.baseline.avgDurationMs)} / {formatMs(row.baseline.p95DurationMs)}
                </td>
                <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">
                  {formatMs(row.comparison.avgDurationMs)} / {formatMs(row.comparison.p95DurationMs)}
                </td>
                <td className="whitespace-nowrap px-2 py-1"><DeltaCell delta={row.avgDelta} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </TableShell>
    </div>
  )
}

const compareTestRuntimeToolCard: ToolCardRenderer = {
  toolName: "compare_test_runtime",
  collapsedSummary,
  renderExpanded
}

export default compareTestRuntimeToolCard
