import { isPlainObject } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, StatePill } from "./toolCardUi"

// Shared presentation for the Local Mode job-lifecycle tool family
// (open_in_local_mode, cancel_local_mode, create_coding_job — EPIC-293 /
// JOB-4225). All three return a `job_id`/`job_state`/`message` outcome,
// with `branch_name`/`repository_slug` present only where the underlying
// tool actually resolves them; `tool_cards/<name>.tsx` files are thin
// re-exports. Lives outside `tool_cards/` for the same reason as
// toolCardUi.tsx / pendingActionToolCard.tsx.
export type LocalModeJobOutcome = {
  jobId: string
  jobState: string
  message: string | null
  branchName: string | null
  repositorySlug: string | null
}

export function parseLocalModeJobOutcome(value: unknown): LocalModeJobOutcome | null {
  if (!isPlainObject(value)) return null

  const jobId = displayValue(value.job_id)
  const jobState = displayValue(value.job_state)
  if (!jobId || !jobState) return null

  return {
    jobId,
    jobState,
    message: displayValue(value.message),
    branchName: displayValue(value.branch_name),
    repositorySlug: displayValue(value.repository_slug)
  }
}

export function localModeJobOutcomeSummary(result: LocalModeJobOutcome): string {
  return result.message || `JOB-${result.jobId} (${result.jobState})`
}

export function LocalModeJobOutcomeCard({ result }: { result: LocalModeJobOutcome }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">JOB-{result.jobId}</span>
        <StatePill state={result.jobState} />
        {result.repositorySlug ? <Badge>{result.repositorySlug}</Badge> : null}
      </div>
      {result.branchName ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Branch" value={result.branchName} />
        </dl>
      ) : null}
      {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
    </CardShell>
  )
}
