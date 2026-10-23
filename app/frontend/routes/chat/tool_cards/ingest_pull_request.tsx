import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for ingest_pull_request (the tool-card work).
type JobSummary = { id: string | null; slug: string | null; state: string | null; kind: string | null; epicId: string | null }

type IngestResult = {
  prNumber: string
  prUrl: string | null
  alreadyIngested: boolean
  classification: string | null
  job: JobSummary | "incomplete" | null
}

function parseJob(value: unknown): JobSummary | "incomplete" | null {
  if (value == null) return null
  if (!isPlainObject(value)) return "incomplete"
  const job = {
    id: displayValue(value.id),
    slug: displayValue(value.slug),
    state: displayValue(value.state),
    kind: displayValue(value.kind),
    epicId: displayValue(value.epic_id)
  }
  return job.id || job.slug ? job : "incomplete"
}

function failureConfig(): ToolFailureConfig {
  return {
    title: i18n.t("chat:ingest_pull_request.failure_title"),
    attempted: (context) => {
      const prNumber = stringFromInput(context, ["pr_number"])
      return prNumber ? i18n.t("chat:ingest_pull_request.attempted_with_number", { prNumber }) : i18n.t("chat:ingest_pull_request.attempted")
    },
    retrySafety: "caution",
    recovery: i18n.t("chat:ingest_pull_request.recovery")
  }
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
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig())
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  const job = result.job === "incomplete" ? null : result.job
  const jobLabel = job?.slug || (job?.id ? `JOB-${job.id}` : `PR #${result.prNumber}`)
  return i18n.t(result.alreadyIngested ? "chat:ingest_pull_request.summary_already_ingested" : "chat:ingest_pull_request.summary_ingested", {
    prNumber: result.prNumber,
    jobLabel
  })
}

function Classification({ context, result }: { context: ToolCardContext; result: IngestResult }) {
  const requested = stringFromInput(context, ["classification"])
  if (!requested && !result.classification) return null

  const label = requested
    ? i18n.t(result.alreadyIngested ? "chat:ingest_pull_request.classification_override_not_applied" : "chat:ingest_pull_request.classification_override")
    : i18n.t("chat:ingest_pull_request.classification_auto_detected")
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
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig()} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference kind="pull_request" id={result.prNumber} prUrl={result.prUrl} />
        <Badge>{i18n.t(result.alreadyIngested ? "chat:ingest_pull_request.status_already_ingested" : "chat:ingest_pull_request.status_ingested")}</Badge>
      </div>
      <Classification context={context} result={result} />
      {result.job === "incomplete" ? (
        <EmptyState>{i18n.t("chat:ingest_pull_request.incomplete_job")}</EmptyState>
      ) : result.job ? (
        <div className="flex flex-wrap items-center gap-2">
          {result.job.id ? <EntityReference kind="job" id={result.job.id} /> : null}
          {result.job.slug ? <span className="break-all font-mono font-medium">{result.job.slug}</span> : null}
          {result.job.state ? <StatePill state={result.job.state} /> : null}
          {result.job.kind ? <Badge>{result.job.kind}</Badge> : null}
          {result.job.epicId ? <EntityReference kind="epic" id={result.job.epicId} /> : null}
        </div>
      ) : (
        <EmptyState>{i18n.t("chat:ingest_pull_request.no_job")}</EmptyState>
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
    label: i18n.t("chat:ingest_pull_request.example_auto_detected"),
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
    label: i18n.t("chat:ingest_pull_request.example_override_without_job"),
    input: { pr_number: 43, classification: "manual_hotfix" },
    parsedResult: { pr_number: 43, pr_url: "https://github.com/acme/widgets/pull/43", already_ingested: false, classification: "manual_hotfix", job: null }
  },
  {
    id: "not_found",
    label: i18n.t("chat:ingest_pull_request.example_not_found"),
    input: { pr_number: 404 },
    resultBody: "Error: pull request not found: #404",
    resultError: true
  }
]
