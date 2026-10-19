import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { MarkdownPreview } from "./toolCardMarkdown"
import { CardShell, displayValue, EmptyState, EntityReference, Row, StatePill } from "./toolCardUi"

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

export type LocalModeJobOutcomeModel = {
  result: LocalModeJobOutcome | null
  requestedJobId: string | null
  error: string | null
}

export function parseLocalModeJobOutcome(value: unknown): LocalModeJobOutcome | null {
  if (!isPlainObject(value)) return null

  const releasedJob = isPlainObject(value.released_job) ? value.released_job : null
  const jobId = displayValue(value.job_id) || displayValue(releasedJob?.id)
  const jobState = displayValue(value.job_state) || displayValue(releasedJob?.state)
  if (!jobId || !jobState) return null

  return {
    jobId,
    jobState,
    message: displayValue(value.message),
    branchName: displayValue(value.branch_name) || displayValue(releasedJob?.branch_name),
    repositorySlug: displayValue(value.repository_slug)
  }
}

export function localModeJobOutcomeSummary(result: LocalModeJobOutcome): string {
  return result.message || `JOB-${result.jobId} (${result.jobState})`
}

export function localModeJobOutcomeModel(context: ToolCardContext): LocalModeJobOutcomeModel {
  const result = parseLocalModeJobOutcome(context.parsedResult)
  const requestedJobId = displayValue(context.input?.job_id)
  return {
    result,
    requestedJobId,
    error: context.resultError ? displayValue(context.resultBody) || "The job operation failed." : null
  }
}

export function LocalModeJobOutcomeEmptyCard({ jobId }: { jobId: string | null }) {
  return (
    <EmptyState>
      No job outcome returned
      {jobId ? (
        <>
          {" "}
          for <EntityReference id={jobId} kind="job" />
        </>
      ) : null}
      .
    </EmptyState>
  )
}

export function LocalModeJobOutcomeCard({ result }: { result: LocalModeJobOutcome }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.jobId} kind="job" />
        <StatePill state={result.jobState} />
        {result.repositorySlug ? <EntityReference kind="repository" repositorySlug={result.repositorySlug} slug={result.repositorySlug} /> : null}
      </div>
      {result.branchName ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row copyable label="Branch" value={result.branchName} wrap />
        </dl>
      ) : null}
      {result.message ? <MarkdownPreview text={result.message} title="Outcome" /> : null}
    </CardShell>
  )
}

export function LocalModeJobOutcomeToolCard({ context }: { context: ToolCardContext }) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return <EmptyState>{model.error}</EmptyState>
  if (!model.result) return <LocalModeJobOutcomeEmptyCard jobId={model.requestedJobId} />
  return <LocalModeJobOutcomeCard result={model.result} />
}
