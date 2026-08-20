import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { RepositoryTabs } from "../../components/RepositoryTabs"
import { withRoutePrefix } from "../../lib/routing"
import { fetchRepositoryTestDetail, fetchRepositoryTests, type RepositoryTestDetailPayload, type RepositoryTestDurationPoint, type RepositoryTestHistoryItem, type RepositoryTestIdentity, type RepositoryTestsPayload } from "../../api/repositories"
import { errorMessage } from "../../lib/errorMessage"
import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useNavigate } from "react-router-dom"
import { useEffect, useMemo, useState } from "react"
import { PanelMessage } from "./shared"

export function RepositoryTestsRoute({ repositoryId, prefix, selectedTestId }: { repositoryId: string; prefix: string; selectedTestId: string | null }) {
  const [query, setQuery] = useState("")
  const debouncedQuery = useDebouncedValue(query, 250)
  const navigate = useNavigate()
  const tests = useQuery({
    queryKey: ["repositories", repositoryId, "tests", debouncedQuery],
    queryFn: () => fetchRepositoryTests(repositoryId, debouncedQuery),
    placeholderData: keepPreviousData
  })
  const testDetail = useQuery({
    queryKey: ["repositories", repositoryId, "tests", selectedTestId],
    queryFn: () => fetchRepositoryTestDetail(repositoryId, selectedTestId!),
    enabled: !!selectedTestId
  })

  const shell = testDetail.data || tests.data

  if (tests.isPending && !shell) {
    return <PanelMessage>Loading tests...</PanelMessage>
  }

  if (tests.isError && !tests.data) {
    return <PanelMessage tone="error">{errorMessage(tests.error, "Unable to load tests.")}</PanelMessage>
  }

  if (!shell) return null

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <a className="hover:underline" href={shell.repository.github_url} rel="noopener" target="_blank">{shell.repository.slug}</a>
        </h1>
      </header>

      <RepositoryTabs active="tests" prefix={prefix} tabs={shell.tabs} />

      <section className="space-y-4">
        <div className="flex flex-wrap items-end gap-3">
          <label className="block min-w-[18rem] flex-1 text-sm font-medium text-gray-700 dark:text-gray-300">
            Search tests
            <input
              className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
              onChange={(event) => setQuery(event.target.value)}
              placeholder="name, suite, or file"
              value={query}
            />
          </label>
          {selectedTestId ? (
            <button
              className="rounded border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
              onClick={() => navigate(withRoutePrefix(`/repositories/${repositoryId}?tab=tests`, prefix))}
              type="button"
            >
              Back to tests
            </button>
          ) : null}
        </div>

        {selectedTestId ? (
          <TestDetailPanel detail={testDetail.data} error={testDetail.error} isError={testDetail.isError} isPending={testDetail.isPending} prefix={prefix} />
        ) : (
          <TestList error={tests.error} isError={tests.isError} isFetching={tests.isFetching} payload={tests.data} prefix={prefix} query={debouncedQuery} />
        )}
      </section>
    </>
  )
}

function TestList({ error, isError, isFetching, payload, prefix, query }: { error: unknown; isError: boolean; isFetching: boolean; payload?: RepositoryTestsPayload; prefix: string; query: string }) {
  if (!payload) return null
  if (payload.tests.length === 0) {
    return <PanelMessage>{query ? "No tests match this search." : "No test history yet. Search by name once tests have been ingested."}</PanelMessage>
  }

  return (
    <div className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex items-center justify-between border-b border-gray-200 px-4 py-2 text-xs text-gray-500 dark:border-gray-700 dark:text-gray-400">
        <span>{query ? "Search results" : "Interesting tests"}</span>
        {isFetching ? <span>Updating results...</span> : null}
        {isError ? <span className="text-red-600 dark:text-red-300">{errorMessage(error, "Unable to refresh results.")}</span> : null}
      </div>
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Test</th>
            <th className="hidden px-4 py-2 md:table-cell">Suite</th>
            <th className="px-4 py-2">Recent failures</th>
            <th className="hidden px-4 py-2 sm:table-cell">Duration</th>
            <th className="hidden px-4 py-2 sm:table-cell">Last seen</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
          {payload.tests.map((test) => (
            <tr className="text-gray-700 dark:text-gray-300" key={test.id}>
              <td className="max-w-md px-4 py-3">
                <Link className="font-medium text-blue-700 hover:underline dark:text-blue-300" to={withRoutePrefix(`/repositories/${payload.repository.id}?tab=tests&test_id=${test.id}`, prefix)}>
                  {test.name}
                </Link>
                {test.interesting_reasons.length > 0 ? (
                  <div className="mt-2 flex flex-wrap gap-1">
                    {test.interesting_reasons.map((reason) => <ReasonBadge key={reason} reason={reason} />)}
                  </div>
                ) : null}
                {test.file_path ? <div className="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">{test.file_path}</div> : null}
              </td>
              <td className="hidden max-w-xs truncate px-4 py-3 text-gray-500 dark:text-gray-400 md:table-cell" title={test.suite_name}>{test.suite_name}</td>
              <td className="whitespace-nowrap px-4 py-3">
                <span className={`inline-flex rounded border px-2 py-0.5 text-xs font-medium ${test.failed_count > 0 ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300" : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"}`}>
                  {test.failed_count}/{test.total_count}
                </span>
              </td>
              <td className="hidden whitespace-nowrap px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell">{formatDuration(test.avg_duration_ms)}</td>
              <td className="hidden whitespace-nowrap px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell">{test.last_seen_at ? <RelativeTimestamp value={test.last_seen_at} /> : "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ReasonBadge({ reason }: { reason: string }) {
  const classes = reason === "failing"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
    : reason === "flaky"
      ? "border-yellow-200 bg-yellow-50 text-yellow-800 dark:border-yellow-900 dark:bg-yellow-950 dark:text-yellow-300"
      : "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-300"

  return <span className={`inline-flex rounded border px-1.5 py-0.5 text-[11px] font-medium ${classes}`}>{reason}</span>
}

function TestDetailPanel({ detail, error, isError, isPending, prefix }: { detail?: RepositoryTestDetailPayload; error: unknown; isError: boolean; isPending: boolean; prefix: string }) {
  if (isPending) return <PanelMessage>Loading test history...</PanelMessage>
  if (isError) return <PanelMessage tone="error">{errorMessage(error, "Unable to load test history.")}</PanelMessage>
  if (!detail) return null

  return (
    <div className="space-y-4">
      <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="break-words text-xl font-semibold text-gray-900 dark:text-gray-100">{detail.test.name}</h2>
            <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{detail.test.suite_name}</p>
            {detail.test.file_path ? <p className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{detail.test.file_path}</p> : null}
          </div>
          <span className="rounded border border-gray-200 bg-gray-50 px-2 py-1 font-mono text-xs text-gray-500 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-400">{detail.test.fingerprint.slice(0, 12)}</span>
        </div>
        <DurationChart points={detail.duration_points} />
      </section>

      <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="bg-gray-50 text-left text-xs uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">Time</th>
              <th className="px-4 py-2">Status</th>
              <th className="hidden px-4 py-2 sm:table-cell">Duration</th>
              <th className="px-4 py-2">Run</th>
              <th className="hidden px-4 py-2 lg:table-cell">Failure</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
            {detail.history.map((item) => <HistoryRow item={item} key={item.id} prefix={prefix} />)}
          </tbody>
        </table>
      </section>
    </div>
  )
}

function HistoryRow({ item, prefix }: { item: RepositoryTestHistoryItem; prefix: string }) {
  return (
    <tr className="text-gray-700 dark:text-gray-300">
      <td className="whitespace-nowrap px-4 py-3">{item.created_at ? <RelativeTimestamp value={item.created_at} /> : "—"}</td>
      <td className="px-4 py-3"><StatusBadge status={item.status} /></td>
      <td className="hidden whitespace-nowrap px-4 py-3 text-gray-500 dark:text-gray-400 sm:table-cell">{formatDuration(item.duration_ms)}</td>
      <td className="px-4 py-3">
        <Link className="font-medium text-blue-700 hover:underline dark:text-blue-300" to={withRoutePrefix(item.run.path, prefix)}>{item.run.slug}</Link>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{item.job.slug} · {item.grader_name}</div>
      </td>
      <td className="hidden max-w-md truncate px-4 py-3 text-gray-500 dark:text-gray-400 lg:table-cell" title={item.failure_message || ""}>{item.failure_message || "—"}</td>
    </tr>
  )
}

function DurationChart({ points }: { points: RepositoryTestDurationPoint[] }) {
  const chart = useMemo(() => buildChart(points), [points])
  if (!chart) {
    return <div className="mt-4 rounded border border-gray-200 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400">No duration samples yet.</div>
  }

  return (
    <div className="mt-4">
      <div className="mb-2 flex items-center justify-between text-xs text-gray-500 dark:text-gray-400">
        <span>Duration over time</span>
        <span>{formatDuration(chart.maxDuration)}</span>
      </div>
      <svg className="h-40 w-full overflow-visible" role="img" viewBox="0 0 640 160">
        <polyline fill="none" points={chart.points} stroke="currentColor" strokeWidth="2" className="text-blue-600 dark:text-blue-400" />
        {chart.dots.map((dot) => (
          <circle className={dot.status === "failed" || dot.status === "error" ? "fill-red-500" : "fill-blue-500"} cx={dot.x} cy={dot.y} key={dot.key} r="3" />
        ))}
      </svg>
    </div>
  )
}

function buildChart(points: RepositoryTestDurationPoint[]) {
  const usable = points.filter((point) => point.duration_ms != null)
  if (usable.length === 0) return null
  const maxDuration = Math.max(...usable.map((point) => point.duration_ms), 1)
  const width = 640
  const height = 150
  const xStep = usable.length > 1 ? width / (usable.length - 1) : width
  const dots = usable.map((point, index) => {
    const x = usable.length > 1 ? index * xStep : width / 2
    const y = height - (point.duration_ms / maxDuration) * (height - 12) + 6
    return { key: point.test_case_id, x, y, status: point.status }
  })

  return {
    maxDuration,
    dots,
    points: dots.map((dot) => `${dot.x},${dot.y}`).join(" ")
  }
}

function StatusBadge({ status }: { status: RepositoryTestHistoryItem["status"] }) {
  const classes = status === "passed"
    ? "border-green-200 bg-green-50 text-green-700 dark:border-green-900 dark:bg-green-950 dark:text-green-300"
    : status === "skipped"
      ? "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"
      : "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
  return <span className={`inline-flex rounded border px-2 py-0.5 text-xs font-medium ${classes}`}>{status}</span>
}

function formatDuration(value: number | null | undefined) {
  if (value == null) return "—"
  if (value < 1000) return `${value}ms`
  return `${(value / 1000).toFixed(2)}s`
}

function useDebouncedValue<T>(value: T, delayMs: number) {
  const [debouncedValue, setDebouncedValue] = useState(value)

  useEffect(() => {
    const timeout = window.setTimeout(() => setDebouncedValue(value), delayMs)
    return () => window.clearTimeout(timeout)
  }, [delayMs, value])

  return debouncedValue
}
