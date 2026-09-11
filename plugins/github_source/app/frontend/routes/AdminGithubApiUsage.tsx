import { useQuery } from "@tanstack/react-query"
import { Select } from "@app/components/Select"
import { useState } from "react"
import { fetchGithubApiUsage, type GithubApiUsageOperationRow, type GithubApiUsageRepositoryRow } from "../api/githubApiUsage"

function number(value: number | null | undefined) {
  return typeof value === "number" ? value.toLocaleString() : "-"
}

function time(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export default function AdminGithubApiUsage() {
  const [hours, setHours] = useState(24)
  const query = useQuery({
    queryKey: ["admin", "github_api_usage", hours],
    queryFn: () => fetchGithubApiUsage(hours),
    refetchInterval: 60_000
  })
  const payload = query.data

  return (
    <main className="mx-auto max-w-7xl px-6 py-8">
      <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-semibold text-gray-950 dark:text-gray-50">GitHub API Usage</h1>
          <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">Hourly rollups by credential, operation, repository, and rate-limit resource.</p>
        </div>
        <label className="text-sm font-medium text-gray-700 dark:text-gray-200">
          Window
          <Select
            className="ml-2"
            fullWidth={false}
            value={hours}
            onChange={(event) => setHours(Number(event.target.value))}
          >
            <option value={1}>1 hour</option>
            <option value={6}>6 hours</option>
            <option value={24}>24 hours</option>
            <option value={72}>3 days</option>
            <option value={168}>7 days</option>
          </Select>
        </label>
      </div>

      {query.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">Loading...</p> : null}
      {query.isError ? <p className="text-sm text-red-700 dark:text-red-300">Could not load GitHub API usage.</p> : null}

      {payload ? (
        <div className="space-y-6">
          <section className="grid gap-4 md:grid-cols-3">
            <Metric label="Requests" value={payload.totals.requests} />
            <Metric label="Rate limited" value={payload.totals.rate_limited} />
            <Metric label="Generated" value={time(payload.generated_at)} />
          </section>

          {payload.recent_rate_limits.length ? (
            <section className="rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-900/60 dark:bg-red-950/20">
              <h2 className="text-lg font-semibold text-red-900 dark:text-red-100">Recent Rate Limits</h2>
              <UsageTable rows={payload.recent_rate_limits} showRepo />
            </section>
          ) : null}

          <section className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-950">
            <h2 className="text-lg font-semibold text-gray-950 dark:text-gray-50">By Operation</h2>
            <UsageTable rows={payload.by_operation} />
          </section>

          <section className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-950">
            <h2 className="text-lg font-semibold text-gray-950 dark:text-gray-50">By Repository</h2>
            <RepositoryTable rows={payload.by_repository} />
          </section>
        </div>
      ) : null}
    </main>
  )
}

function Metric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-950">
      <div className="text-sm font-medium text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-gray-950 dark:text-gray-50">{typeof value === "number" ? number(value) : value}</div>
    </div>
  )
}

function UsageTable({ rows, showRepo = false }: { rows: (GithubApiUsageOperationRow & { repo_slug?: string | null })[]; showRepo?: boolean }) {
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="min-w-full text-left text-sm">
        <thead className="text-xs uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="py-2 pr-4">Credential</th>
            {showRepo ? <th className="py-2 pr-4">Repository</th> : null}
            <th className="py-2 pr-4">Operation</th>
            <th className="py-2 pr-4">Resource</th>
            <th className="py-2 pr-4">Requests</th>
            <th className="py-2 pr-4">Limited</th>
            <th className="py-2 pr-4">Min remaining</th>
            <th className="py-2 pr-4">Last seen</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row, index) => (
            <tr key={`${row.auth_source}-${row.operation}-${row.resource}-${row.repo_slug ?? ""}-${index}`}>
              <td className="py-2 pr-4 font-mono text-xs text-gray-600 dark:text-gray-300">{row.auth_source}</td>
              {showRepo ? <td className="py-2 pr-4 font-mono text-xs text-gray-600 dark:text-gray-300">{row.repo_slug || "-"}</td> : null}
              <td className="py-2 pr-4 font-medium text-gray-900 dark:text-gray-100">{row.operation}</td>
              <td className="py-2 pr-4 text-gray-600 dark:text-gray-300">{row.resource}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.requests)}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.rate_limited)}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.min_remaining)}</td>
              <td className="py-2 pr-4 text-gray-600 dark:text-gray-300">{time(row.last_seen_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function RepositoryTable({ rows }: { rows: GithubApiUsageRepositoryRow[] }) {
  return (
    <div className="mt-3 overflow-x-auto">
      <table className="min-w-full text-left text-sm">
        <thead className="text-xs uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="py-2 pr-4">Repository</th>
            <th className="py-2 pr-4">Credential</th>
            <th className="py-2 pr-4">Requests</th>
            <th className="py-2 pr-4">Limited</th>
            <th className="py-2 pr-4">Min remaining</th>
            <th className="py-2 pr-4">Last seen</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={`${row.auth_source}-${row.repo_slug}`}>
              <td className="py-2 pr-4 font-medium text-gray-900 dark:text-gray-100">{row.repo_slug}</td>
              <td className="py-2 pr-4 font-mono text-xs text-gray-600 dark:text-gray-300">{row.auth_source}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.requests)}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.rate_limited)}</td>
              <td className="py-2 pr-4 text-gray-900 dark:text-gray-100">{number(row.min_remaining)}</td>
              <td className="py-2 pr-4 text-gray-600 dark:text-gray-300">{time(row.last_seen_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
