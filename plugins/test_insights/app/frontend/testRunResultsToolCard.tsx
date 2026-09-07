import { Fragment } from "react"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, numberValue, SectionLabel } from "@app/routes/chat/toolCardUi"
import { FailureSnippet, Flakiness, formatMs, parseFailure, TableShell, TestStatusPill } from "./testInsightToolCard"

// Shared presentation for read_job_test_results and read_run_test_results
// (EPIC-292): both tools return the identical `{job_id, job_slug,
// workflow_id, run_id, grader_name, test_runs: [...], truncation}` shape
// from TestInsights::RunResults (see
// plugins/test_insights/app/services/test_insights/run_results.rb) -- only
// whether `run_id` is populated differs. Lives outside `tool_cards/` on
// purpose: core's pluginToolCards.tsx glob treats every non-test .tsx under
// `tool_cards/` as a card module and would warn about the missing default
// export.
export type TestCaseRow = {
  id: string
  name: string
  suiteName: string | null
  filePath: string | null
  status: string | null
  durationMs: number | null
  flakiness: unknown
  failure: ReturnType<typeof parseFailure>
}

function parseTestCaseRow(value: unknown): TestCaseRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const name = displayValue(value.name)
  if (!id || !name) return null

  return {
    id,
    name,
    suiteName: displayValue(value.suite_name),
    filePath: displayValue(value.file_path),
    status: displayValue(value.status),
    durationMs: numberValue(value.duration_ms),
    flakiness: value.flakiness,
    failure: parseFailure(value.failure)
  }
}

function parseTestCaseRows(value: unknown): TestCaseRow[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const row = parseTestCaseRow(entry)
    return row ? [row] : []
  })
}

export type TestRunRow = {
  id: string
  graderName: string | null
  totalCount: number | null
  passedCount: number | null
  failedCount: number | null
  skippedCount: number | null
  errorCount: number | null
  durationMs: number | null
  failedErrorCases: TestCaseRow[]
  failedErrorCasesOmitted: number | null
  slowCases: TestCaseRow[]
  slowCasesOmitted: number | null
}

function parseTestRunRow(value: unknown): TestRunRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    id,
    graderName: displayValue(value.grader_name),
    totalCount: numberValue(value.total_count),
    passedCount: numberValue(value.passed_count),
    failedCount: numberValue(value.failed_count),
    skippedCount: numberValue(value.skipped_count),
    errorCount: numberValue(value.error_count),
    durationMs: numberValue(value.duration_ms),
    failedErrorCases: parseTestCaseRows(value.failed_error_cases),
    failedErrorCasesOmitted: numberValue(value.failed_error_cases_omitted),
    slowCases: parseTestCaseRows(value.slow_cases),
    slowCasesOmitted: numberValue(value.slow_cases_omitted)
  }
}

export type RunResultsPayload = {
  jobSlug: string | null
  runId: string | null
  graderName: string | null
  testRuns: TestRunRow[]
}

export function parseRunResultsPayload(context: ToolCardContext): RunResultsPayload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.test_runs)) return null

  return {
    jobSlug: displayValue(parsed.job_slug),
    runId: displayValue(parsed.run_id),
    graderName: displayValue(parsed.grader_name),
    testRuns: parsed.test_runs.flatMap((testRun) => {
      const row = parseTestRunRow(testRun)
      return row ? [row] : []
    })
  }
}

export function runResultsSummary(payload: RunResultsPayload): string {
  if (payload.testRuns.length === 0) return "no test results"

  const totalFailed = payload.testRuns.reduce((sum, testRun) => sum + (testRun.failedCount ?? 0) + (testRun.errorCount ?? 0), 0)
  const totalCount = payload.testRuns.reduce((sum, testRun) => sum + (testRun.totalCount ?? 0), 0)
  return `${totalFailed} failed of ${totalCount} across ${payload.testRuns.length} grader${payload.testRuns.length === 1 ? "" : "s"}`
}

export function RunResultsBody({ payload }: { payload: RunResultsPayload }) {
  if (payload.testRuns.length === 0) return <EmptyState>No test results recorded yet.</EmptyState>

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {payload.jobSlug ? <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{payload.jobSlug}</span> : null}
        {payload.runId ? <span className="font-mono text-gray-600 dark:text-gray-300">RUN-{payload.runId}</span> : null}
        {payload.graderName ? <Badge>{payload.graderName}</Badge> : null}
      </div>
      {payload.testRuns.map((testRun) => <TestRunSection key={testRun.id} testRun={testRun} />)}
    </CardShell>
  )
}

function TestRunSection({ testRun }: { testRun: TestRunRow }) {
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{testRun.graderName ?? "grader"}</Badge>
        <span className="text-gray-600 dark:text-gray-300">
          {testRun.passedCount ?? 0} passed · {testRun.failedCount ?? 0} failed · {testRun.errorCount ?? 0} errors · {testRun.skippedCount ?? 0} skipped
        </span>
        <span className="font-mono text-gray-500 dark:text-gray-400">{formatMs(testRun.durationMs)}</span>
      </div>
      {testRun.failedErrorCases.length > 0 ? (
        <TestCaseTable cases={testRun.failedErrorCases} omitted={testRun.failedErrorCasesOmitted} showFailures title="Failed / error cases" />
      ) : null}
      {testRun.slowCases.length > 0 ? (
        <TestCaseTable cases={testRun.slowCases} omitted={testRun.slowCasesOmitted} title="Slow cases" />
      ) : null}
    </div>
  )
}

function TestCaseTable({ cases, omitted, showFailures = false, title }: { cases: TestCaseRow[]; omitted?: number | null; showFailures?: boolean; title: string }) {
  return (
    <div>
      <SectionLabel>{title}{omitted ? ` (${omitted} more omitted)` : ""}</SectionLabel>
      <TableShell>
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">Test</th>
              <th className="px-2 py-1 font-semibold" scope="col">Status</th>
              <th className="px-2 py-1 font-semibold" scope="col">Duration</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {cases.map((testCase) => (
              <Fragment key={testCase.id}>
                <tr>
                  <td className="max-w-[16rem] truncate px-2 py-1 text-gray-800 dark:text-gray-200" title={testCase.name}>
                    {testCase.name} <Flakiness flakiness={testCase.flakiness} />
                  </td>
                  <td className="whitespace-nowrap px-2 py-1"><TestStatusPill status={testCase.status} /></td>
                  <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{formatMs(testCase.durationMs)}</td>
                </tr>
                {showFailures && testCase.failure ? (
                  <tr>
                    <td className="px-2 py-1" colSpan={3}><FailureSnippet failure={testCase.failure} /></td>
                  </tr>
                ) : null}
              </Fragment>
            ))}
          </tbody>
        </table>
      </TableShell>
    </div>
  )
}
