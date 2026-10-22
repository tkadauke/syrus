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

export type CreateCodingJobRequest = {
  title: string | null
  body: string | null
  repositoryId: string | null
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

export function createCodingJobRequest(context: ToolCardContext): CreateCodingJobRequest {
  return {
    title: displayValue(context.input?.title),
    body: displayValue(context.input?.body),
    repositoryId: displayValue(context.input?.repository_id)
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

function LocalModeJobOutcomeDetails({ result, showRepository = true }: { result: LocalModeJobOutcome; showRepository?: boolean }) {
  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.jobId} kind="job" />
        <StatePill state={result.jobState} />
        {showRepository && result.repositorySlug ? (
          <EntityReference
            href={`https://github.com/${result.repositorySlug}`}
            kind="repository"
            repositorySlug={result.repositorySlug}
            slug={result.repositorySlug}
          />
        ) : null}
      </div>
      {result.branchName ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row copyable label="Branch" value={result.branchName} wrap />
        </dl>
      ) : null}
      {result.message ? <MarkdownPreview text={result.message} title="Outcome" /> : null}
    </>
  )
}

export function LocalModeJobOutcomeCard({ result }: { result: LocalModeJobOutcome }) {
  return (
    <CardShell>
      <LocalModeJobOutcomeDetails result={result} />
    </CardShell>
  )
}

export function CreateCodingJobOutcomeCard({ context }: { context: ToolCardContext }) {
  const model = localModeJobOutcomeModel(context)
  const request = createCodingJobRequest(context)
  const repositorySlug = model.result?.repositorySlug

  return (
    <CardShell>
      {request.title ? <h3 className="break-words text-sm font-semibold text-text-primary">{request.title}</h3> : null}
      {request.repositoryId || repositorySlug ? (
        <div className="grid min-w-0 gap-1 sm:grid-cols-2">
          <div className="min-w-0">
            <div className="text-xs font-medium text-text-muted">Repository</div>
            <EntityReference
              href={!request.repositoryId && repositorySlug ? `https://github.com/${repositorySlug}` : null}
              kind="repository"
              label={repositorySlug || (request.repositoryId ? `Repository ${request.repositoryId}` : null)}
              repositoryId={request.repositoryId}
              repositorySlug={repositorySlug}
            />
          </div>
          {request.repositoryId ? <Row label="Repository ID" value={request.repositoryId} /> : null}
        </div>
      ) : null}
      {request.body ? <MarkdownPreview text={request.body} title="Description" /> : null}
      {model.error ? <EmptyState>{model.error}</EmptyState> : null}
      {model.result ? <LocalModeJobOutcomeDetails result={model.result} showRepository={false} /> : null}
      {!model.error && !model.result ? <LocalModeJobOutcomeEmptyCard jobId={null} /> : null}
    </CardShell>
  )
}

export function LocalModeJobOutcomeToolCard({ context }: { context: ToolCardContext }) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return <EmptyState>{model.error}</EmptyState>
  if (!model.result) return <LocalModeJobOutcomeEmptyCard jobId={model.requestedJobId} />
  return <LocalModeJobOutcomeCard result={model.result} />
}
