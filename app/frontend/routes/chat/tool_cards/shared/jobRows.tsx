import { linkifySlugs } from "../../../../lib/linkifySlugs"
import { StatusPill } from "../../../../components/StatusPill"
import { stringValue } from "../../utils"
import { isPlainObject } from "../../../../pluginToolCards"
import { PriorityPill } from "./badges"

// Shared dense-list row for the list_jobs and search_jobs tool cards
// (EPIC-291 / JOB-4220) — both tools return an array of Job summary
// payloads with a slightly different, overlapping field set
// (`job_list_payload` vs `job_search_payload` in
// app/services/mcp_tool_payloads/job_payload.rb), so every field here is
// optional and simply omitted from the row when the payload doesn't carry it.
export type JobRowData = {
  id: number
  title: string
  state: string
  repositorySlug: string
  prNumber: number | null
  priority: string
  branch: string
}

export function parseJobRow(value: unknown): JobRowData | null {
  if (!isPlainObject(value) || typeof value.id !== "number") return null

  return {
    id: value.id,
    title: stringValue(value.issue_title).trim(),
    state: stringValue(value.state).trim(),
    repositorySlug: stringValue(value.repository_slug).trim(),
    prNumber: typeof value.pr_number === "number" ? value.pr_number : null,
    priority: stringValue(value.priority).trim(),
    branch: stringValue(value.branch_name).trim()
  }
}

function JobRow({ job }: { job: JobRowData }) {
  return (
    <li className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-gray-200 py-1.5 last:border-b-0 dark:border-gray-800">
      <span className="shrink-0 font-mono font-medium text-gray-700 dark:text-gray-300">{linkifySlugs(`JOB-${job.id}`)}</span>
      {job.state ? <StatusPill state={job.state} /> : null}
      <span className="min-w-0 flex-1 truncate text-gray-800 dark:text-gray-100" title={job.title || undefined}>{job.title || `JOB-${job.id}`}</span>
      {job.repositorySlug ? <span className="shrink-0 font-mono text-2xs text-gray-500 dark:text-gray-400">{job.repositorySlug}</span> : null}
      {job.prNumber != null ? <span className="shrink-0 font-mono text-gray-500 dark:text-gray-400">#{job.prNumber}</span> : null}
      {job.branch ? <span className="hidden shrink-0 truncate font-mono text-2xs text-gray-500 dark:text-gray-400 sm:inline" title={job.branch}>{job.branch}</span> : null}
      {job.priority ? <PriorityPill priority={job.priority} /> : null}
    </li>
  )
}

export function JobRowList({ jobs }: { jobs: JobRowData[] }) {
  return (
    <ul className="mt-1 divide-y divide-gray-200 rounded border border-gray-200 bg-gray-50 px-2 text-xs dark:divide-gray-800 dark:border-gray-700 dark:bg-gray-900">
      {jobs.map((job) => <JobRow job={job} key={job.id} />)}
    </ul>
  )
}
