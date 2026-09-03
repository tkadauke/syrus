import { getJson } from "@app/api/client"

export type JobTestCase = {
  id: number
  name: string
  suite_name: string
  file_path: string | null
  status: "passed" | "failed" | "skipped" | "error"
  duration_ms: number | null
  failure_message: string | null
  failure_backtrace: string | null
  output: string | null
  flakiness_score: number | null
  flakiness_failed_count: number | null
  flakiness_total_count: number | null
  flakiness_run_statuses: Array<"passed" | "failed" | "skipped" | "error"> | null
}

export type JobTestSuite = {
  suite_name: string
  total_count: number
  passed_count: number
  failed_count: number
  skipped_count: number
  error_count: number
  test_cases: JobTestCase[]
}

export type JobTestRun = {
  id: number
  grader_name: string
  run_id: number
  total_count: number
  passed_count: number
  failed_count: number
  skipped_count: number
  error_count: number
  duration_ms: number | null
  suites: JobTestSuite[]
}

export type JobTestResultsPayload = {
  job_id: number
  workflow_id: number | null
  test_runs: JobTestRun[]
}

export function fetchJobTestResults(path: string) {
  return getJson<JobTestResultsPayload>(path)
}
