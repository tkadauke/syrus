import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { PanelMessage } from "@app/components/PanelMessage"
import { SectionHeading } from "@app/components/Heading"
import { useT } from "@app/hooks/useT"
import { fetchJobTestResults, type JobTestCase, type JobTestRun, type JobTestSuite } from "../api/jobTests"

function TestCaseRow({ testCase }: { testCase: JobTestCase }) {
  const { t } = useT("test_insights")
  const [expanded, setExpanded] = useState(false)
  const hasDetail = (testCase.failure_message || testCase.failure_backtrace || testCase.output) && (testCase.status === "failed" || testCase.status === "error")

  return (
    <div>
      <div
        className={`flex items-start gap-2 px-4 py-2 text-sm ${testCase.status === "skipped" ? "text-gray-400 dark:text-gray-500" : "text-gray-800 dark:text-gray-200"}`}
      >
        <span className="mt-0.5 shrink-0 font-mono text-xs"><TestStatusIcon status={testCase.status} /></span>
        <span className="min-w-0 flex-1 break-words">{testCase.name}</span>
        <FlakinessBadge testCase={testCase} />
        {testCase.duration_ms != null ? (
          <span className="shrink-0 text-xs text-gray-400 dark:text-gray-500">{formatTestDuration(testCase.duration_ms)}</span>
        ) : null}
        {hasDetail ? (
          <button
            aria-expanded={expanded}
            className="shrink-0 text-xs text-brand hover:underline"
            onClick={() => setExpanded((v) => !v)}
            type="button"
          >
            {expanded ? t("tests_hide_detail") : t("tests_show_detail")}
          </button>
        ) : null}
      </div>
      {expanded && hasDetail ? (
        <div className="mx-4 mb-2 space-y-2 rounded bg-gray-50 p-3 text-xs dark:bg-gray-800">
          {testCase.failure_message ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_failure_message")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-red-700 dark:text-red-400">{testCase.failure_message}</pre>
            </div>
          ) : null}
          {testCase.failure_backtrace ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_failure_backtrace")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400">{testCase.failure_backtrace}</pre>
            </div>
          ) : null}
          {testCase.output ? (
            <div>
              <p className="font-medium text-gray-700 dark:text-gray-300">{t("tests_output")}</p>
              <pre className="mt-1 whitespace-pre-wrap break-words font-mono text-gray-600 dark:text-gray-400">{testCase.output}</pre>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

function SuiteGroup({ suite }: { suite: JobTestSuite }) {
  const { t } = useT("test_insights")
  const hasFailures = suite.failed_count > 0 || suite.error_count > 0
  const [expanded, setExpanded] = useState(hasFailures)
  const [showSkipped, setShowSkipped] = useState(false)

  const nonSkipped = suite.test_cases.filter((tc) => tc.status !== "skipped")
  const skipped = suite.test_cases.filter((tc) => tc.status === "skipped")

  return (
    <div className="border-t border-gray-100 first:border-t-0 dark:border-gray-800">
      <button
        aria-expanded={expanded}
        className="flex w-full items-center justify-between px-4 py-2 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800/50"
        onClick={() => setExpanded((v) => !v)}
        type="button"
      >
        <span className="font-medium text-gray-800 dark:text-gray-200">{suite.suite_name}</span>
        <span className="flex items-center gap-3 text-xs">
          {suite.failed_count > 0 ? <span className="text-red-600 dark:text-red-400">{suite.failed_count} failed</span> : null}
          {suite.error_count > 0 ? <span className="text-red-600 dark:text-red-400">{suite.error_count} error</span> : null}
          {suite.passed_count > 0 ? <span className="text-emerald-600 dark:text-emerald-400">{suite.passed_count} passed</span> : null}
          {suite.skipped_count > 0 ? <span className="text-gray-400 dark:text-gray-500">{suite.skipped_count} skipped</span> : null}
          <span className={`transition-transform ${expanded ? "rotate-90" : ""} text-gray-400 dark:text-gray-500`}>›</span>
        </span>
      </button>
      {expanded ? (
        <div className="divide-y divide-gray-50 dark:divide-gray-800/50">
          {nonSkipped.map((tc) => <TestCaseRow key={tc.id} testCase={tc} />)}
          {skipped.length > 0 ? (
            <div>
              <button
                className="px-4 py-1.5 text-xs text-gray-400 hover:underline dark:text-gray-500"
                onClick={() => setShowSkipped((v) => !v)}
                type="button"
              >
                {showSkipped ? t("tests_hide_skipped") : `${t("tests_show_skipped")} (${skipped.length})`}
              </button>
              {showSkipped ? skipped.map((tc) => <TestCaseRow key={tc.id} testCase={tc} />) : null}
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}

function TestRunSection({ testRun }: { testRun: JobTestRun }) {
  const { t } = useT("test_insights")
  const allPassing = testRun.failed_count === 0 && testRun.error_count === 0

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-wrap items-center justify-between gap-3 p-4">
        <SectionHeading>{testRun.grader_name}</SectionHeading>
        <div className="flex flex-wrap items-center gap-3 text-xs">
          <span className="text-emerald-600 dark:text-emerald-400">{testRun.passed_count} passed</span>
          {testRun.failed_count > 0 ? <span className="font-medium text-red-600 dark:text-red-400">{testRun.failed_count} failed</span> : null}
          {testRun.error_count > 0 ? <span className="font-medium text-red-600 dark:text-red-400">{testRun.error_count} error</span> : null}
          {testRun.skipped_count > 0 ? <span className="text-gray-400 dark:text-gray-500">{testRun.skipped_count} skipped</span> : null}
          {testRun.duration_ms != null ? <span className="text-gray-400 dark:text-gray-500">{formatTestDuration(testRun.duration_ms)}</span> : null}
          <span className="text-gray-400 dark:text-gray-500">{testRun.total_count} total</span>
        </div>
      </div>
      {allPassing ? (
        <p className="border-t border-gray-100 px-4 py-3 text-sm text-emerald-600 dark:border-gray-800 dark:text-emerald-400">{t("tests_all_passing")}</p>
      ) : (
        <div className="border-t border-gray-100 dark:border-gray-800">
          {testRun.suites.map((suite) => <SuiteGroup key={suite.suite_name} suite={suite} />)}
        </div>
      )}
    </section>
  )
}

function TestsPanel({ jobId }: { jobId: number }) {
  const { t } = useT("test_insights")
  const { data, isPending, isError } = useQuery({
    queryKey: ["jobs", String(jobId), "test_results"],
    queryFn: () => fetchJobTestResults(`/api/v1/app/jobs/${jobId}/test_results`)
  })

  if (isPending) return <PanelMessage>{t("common:loading")}</PanelMessage>
  if (isError) return <PanelMessage tone="error">{t("tests_load_error")}</PanelMessage>
  if (!data || data.test_runs.length === 0) return <PanelMessage>{t("tests_empty")}</PanelMessage>

  return (
    <div className="space-y-4">
      {data.test_runs.map((testRun) => <TestRunSection key={testRun.id} testRun={testRun} />)}
    </div>
  )
}

function TestStatusIcon({ status }: { status: JobTestCase["status"] }) {
  if (status === "passed") return <span aria-hidden="true" className="text-emerald-600 dark:text-emerald-400">✓</span>
  if (status === "failed" || status === "error") return <span aria-hidden="true" className="text-red-600 dark:text-red-400">✗</span>
  return <span aria-hidden="true" className="text-gray-400 dark:text-gray-500">−</span>
}


function FlakinessSparkline({ statuses }: { statuses: Array<"passed" | "failed" | "skipped" | "error"> }) {
  return (
    <span aria-hidden="true" className="inline-flex items-center gap-0.5">
      {statuses.map((s, i) => (
        <span
          key={i}
          className={`inline-block h-2 w-2 rounded-sm ${
            s === "passed"
              ? "bg-emerald-400 dark:bg-emerald-500"
              : s === "failed" || s === "error"
                ? "bg-red-400 dark:bg-red-500"
                : "bg-gray-300 dark:bg-gray-600"
          }`}
        />
      ))}
    </span>
  )
}


function FlakinessBadge({ testCase }: { testCase: JobTestCase }) {
  const { t } = useT("test_insights")
  const score = testCase.flakiness_score
  const failed = testCase.flakiness_failed_count
  const total = testCase.flakiness_total_count
  const statuses = testCase.flakiness_run_statuses

  if (score == null || score <= 0 || score >= 1.0 || failed == null || total == null) return null

  return (
    <span
      className="inline-flex shrink-0 items-center gap-1 rounded border border-amber-300 bg-amber-50 px-1.5 py-0.5 text-xs font-medium text-amber-700 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300"
      title={t("tests_flaky_tooltip", { failed, total })}
    >
      {t("tests_flaky_label")}
      <span className="font-normal opacity-75">{failed}/{total}</span>
      {statuses && statuses.length > 1 ? <FlakinessSparkline statuses={statuses} /> : null}
    </span>
  )
}


function formatTestDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`
  const minutes = Math.floor(ms / 60000)
  const seconds = Math.round((ms % 60000) / 1000)
  return `${minutes}m ${seconds}s`
}

// Rendered into the job.detail.tab ui_slot.
export default function JobTests({ job }: { job?: { id: number } }) {
  if (!job?.id) return null

  return <TestsPanel jobId={job.id} />
}
