import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EmptyState, numberValue } from "@app/routes/chat/toolCardUi"
import { formatFailureRate, formatMs, parseReasons, parseTestIdentityRef, ReasonBadges, t, TableShell, TestIdentityLink, TestStatusPill, type TestIdentityRef } from "../testInsightToolCard"

// Plugin-owned tool card for list_repository_test_insights (the pending-action tool-card work). Lives
// entirely inside the test_insights plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
type TestRow = TestIdentityRef & {
  lastStatus: string | null
  failureRate: number | null
  avgDurationMs: number | null
  lastDurationMs: number | null
  reasons: string[]
}

function parseRow(value: unknown): TestRow | null {
  const ref = parseTestIdentityRef(value)
  if (!ref) return null

  return {
    ...ref,
    lastStatus: displayValue((value as Record<string, unknown>).last_status),
    failureRate: numberValue((value as Record<string, unknown>).failure_rate),
    avgDurationMs: numberValue((value as Record<string, unknown>).avg_duration_ms),
    lastDurationMs: numberValue((value as Record<string, unknown>).last_duration_ms),
    reasons: parseReasons(value, "interesting_reasons")
  }
}

function testRows(context: ToolCardContext): TestRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tests)) return null

  return parsed.tests.flatMap((test) => {
    const row = parseRow(test)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = testRows(context)
  if (!rows) return null

  return t("tool_tests_summary", { count: rows.length })
}

function renderExpanded(context: ToolCardContext) {
  const rows = testRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>{t("tool_list_empty")}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_test")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_suite_file")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_category")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_status")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_failure_rate")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_col_avg_last")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="max-w-[16rem] px-2 py-1 text-gray-800 dark:text-gray-200">
                <TestIdentityLink test={row} />
              </td>
              <td className="max-w-[14rem] truncate px-2 py-1 text-gray-500 dark:text-gray-400" title={row.filePath ?? row.suiteName ?? undefined}>
                {row.filePath || row.suiteName || "—"}
              </td>
              <td className="whitespace-nowrap px-2 py-1"><ReasonBadges reasons={row.reasons} /></td>
              <td className="whitespace-nowrap px-2 py-1"><TestStatusPill status={row.lastStatus} /></td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{formatFailureRate(row.failureRate)}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{formatMs(row.avgDurationMs)} / {formatMs(row.lastDurationMs)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableShell>
  )
}

const listRepositoryTestInsightsToolCard: ToolCardRenderer = {
  toolName: "list_repository_test_insights",
  collapsedSummary,
  renderExpanded
}

export default listRepositoryTestInsightsToolCard
