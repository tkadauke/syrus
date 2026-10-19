import { isPlainObject } from "@app/pluginToolCards"
import type { ToolCardContext } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference, StatePill, WrappingRow } from "./toolCardUi"
import { MarkdownPreview } from "./toolCardMarkdown"

// Shared presentation for the Local Mode job-lifecycle tool family
// (open_in_local_mode, cancel_local_mode, create_coding_job — the tool-card work /
// All three return a `job_id`/`job_state`/`message` outcome,
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

export function localModeJobIdFromInput(context: ToolCardContext): string | null {
  return displayValue(context.input?.job_id)
}

export function LocalModeJobOutcomeCard({
  result,
  requestedJobId,
  stateTransition = false
}: {
  result: LocalModeJobOutcome
  requestedJobId?: string | null
  stateTransition?: boolean
}) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.jobId} kind="job" />
        <StatePill state={result.jobState} />
        {result.repositorySlug ? <EntityReference kind="repository" repositorySlug={result.repositorySlug} /> : null}
      </div>
      <div className="text-xs text-text-secondary">
        {stateTransition ? "Job returned to " : "Job state: "}
        <strong>{result.jobState.replace(/_/g, " ")}</strong>.
      </div>
      {result.branchName || requestedJobId ? (
        <dl className="grid gap-2 sm:grid-cols-2">
          {requestedJobId ? (
            <div className="min-w-0">
              <dt className="text-2xs font-semibold uppercase text-text-muted">Requested Job</dt>
              <dd>
                <EntityReference id={requestedJobId} kind="job" />
              </dd>
            </div>
          ) : null}
          {result.branchName ? <WrappingRow copyable label="Branch" value={result.branchName} /> : null}
        </dl>
      ) : null}
      {result.message ? <MarkdownPreview text={result.message} title="Message" /> : null}
    </CardShell>
  )
}

export function LocalModeJobOutcomeEmptyCard({ requestedJobId }: { requestedJobId?: string | null }) {
  return (
    <EmptyState>
      No job outcome was returned
      {requestedJobId ? (
        <>
          {" "}
          for <EntityReference id={requestedJobId} kind="job" />
        </>
      ) : null}
      . Use Raw details to inspect the response.
    </EmptyState>
  )
}
