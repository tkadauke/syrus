import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, StatePill } from "../toolCardUi"

// Core-owned tool card for ingest_pull_request (EPIC-293 / JOB-4225).
type JobSummary = { id: string; slug: string; state: string; kind: string | null }

type IngestResult = {
  prNumber: string
  alreadyIngested: boolean
  classification: string | null
  job: JobSummary | null
}

function parseJob(value: unknown): JobSummary | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  const state = displayValue(value.state)
  if (!id || !slug || !state) return null
  return { id, slug, state, kind: displayValue(value.kind) }
}

function parseResult(context: ToolCardContext): IngestResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const prNumber = displayValue(parsed.pr_number)
  if (!prNumber || typeof parsed.already_ingested !== "boolean") return null

  return {
    prNumber,
    alreadyIngested: parsed.already_ingested,
    classification: displayValue(parsed.classification),
    job: parseJob(parsed.job)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const jobLabel = result.job ? result.job.slug : `PR #${result.prNumber}`
  return result.alreadyIngested ? `PR #${result.prNumber} already ingested as ${jobLabel}` : `PR #${result.prNumber} ingested as ${jobLabel}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">PR #{result.prNumber}</span>
        <Badge>{result.alreadyIngested ? "already ingested" : "ingested"}</Badge>
        {result.classification ? <Badge>{result.classification}</Badge> : null}
      </div>
      {result.job ? (
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-mono">{result.job.slug}</span>
          <StatePill state={result.job.state} />
          {result.job.kind ? <Badge>{result.job.kind}</Badge> : null}
        </div>
      ) : null}
    </CardShell>
  )
}

const ingestPullRequestToolCard: ToolCardRenderer = {
  toolName: "ingest_pull_request",
  collapsedSummary,
  renderExpanded
}

export default ingestPullRequestToolCard
