import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for ingest_pull_request (the tool-card work).
type JobSummary = { id: string | null; slug: string | null; state: string | null; kind: string | null; epicId: string | null }

type IngestResult = {
  prNumber: string
  prUrl: string | null
  alreadyIngested: boolean
  classification: string | null
  job: JobSummary | null
}

function parseJob(value: unknown): JobSummary | null {
  if (!isPlainObject(value)) return null
  return {
    id: displayValue(value.id),
    slug: displayValue(value.slug),
    state: displayValue(value.state),
    kind: displayValue(value.kind),
    epicId: displayValue(value.epic_id)
  }
}

const failureConfig: ToolFailureConfig = {
  title: "Pull request ingestion",
  attempted: (context) => {
    const prNumber = stringFromInput(context, ["pr_number"])
    return prNumber ? `Ingest PR #${prNumber}` : "Ingest pull request"
  },
  retrySafety: "caution",
  recovery: "Check the repository attachment, pull request number, classification, and validation message before retrying."
}

function parseResult(context: ToolCardContext): IngestResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const prNumber = displayValue(parsed.pr_number)
  if (!prNumber || typeof parsed.already_ingested !== "boolean") return null

  return {
    prNumber,
    prUrl: displayValue(parsed.pr_url),
    alreadyIngested: parsed.already_ingested,
    classification: displayValue(parsed.classification),
    job: parseJob(parsed.job)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  const jobLabel = result.job?.slug || (result.job?.id ? `JOB-${result.job.id}` : `PR #${result.prNumber}`)
  return result.alreadyIngested ? `PR #${result.prNumber} already ingested as ${jobLabel}` : `PR #${result.prNumber} ingested as ${jobLabel}`
}

function Classification({ context, result }: { context: ToolCardContext; result: IngestResult }) {
  const requested = stringFromInput(context, ["classification"])
  if (!requested && !result.classification) return null

  const label = requested ? (result.alreadyIngested ? "Classification override (not applied)" : "Classification override") : "Auto-detected classification"
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-1">
        <Badge>{result.classification || requested}</Badge>
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference kind="pull_request" id={result.prNumber} prUrl={result.prUrl} />
        <Badge>{result.alreadyIngested ? "already ingested" : "ingested"}</Badge>
      </div>
      <Classification context={context} result={result} />
      {result.job ? (
        <div className="flex flex-wrap items-center gap-2">
          {result.job.id ? <EntityReference kind="job" id={result.job.id} /> : null}
          {result.job.slug ? <span className="break-all font-mono font-medium">{result.job.slug}</span> : null}
          {result.job.state ? <StatePill state={result.job.state} /> : null}
          {result.job.kind ? <Badge>{result.job.kind}</Badge> : null}
          {result.job.epicId ? <EntityReference kind="epic" id={result.job.epicId} /> : null}
        </div>
      ) : (
        <EmptyState>No Job was created for this classification.</EmptyState>
      )}
    </CardShell>
  )
}

const ingestPullRequestToolCard: ToolCardRenderer = {
  toolName: "ingest_pull_request",
  collapsedSummary,
  renderExpanded
}

export default ingestPullRequestToolCard

export const examples: ToolCardExample[] = [
  {
    id: "auto_detected",
    label: "Auto-detected ingestion",
    input: { pr_number: 42 },
    parsedResult: {
      pr_number: 42,
      pr_url: "https://github.com/acme/widgets/pull/42",
      already_ingested: false,
      classification: "external_unknown",
      job: { id: 900, slug: "review-widget", state: "queued", kind: "external_pr", epic_id: 12 }
    }
  },
  {
    id: "classification_override",
    label: "Classification override without a Job",
    input: { pr_number: 43, classification: "manual_hotfix" },
    parsedResult: { pr_number: 43, pr_url: "https://github.com/acme/widgets/pull/43", already_ingested: false, classification: "manual_hotfix", job: null }
  },
  {
    id: "not_found",
    label: "Pull request not found",
    input: { pr_number: 404 },
    resultBody: "Error: pull request not found: #404",
    resultError: true
  }
]
