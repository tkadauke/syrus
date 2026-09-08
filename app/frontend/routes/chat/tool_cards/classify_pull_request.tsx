import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row } from "../toolCardUi"

// Core-owned tool card for classify_pull_request (EPIC-293 / JOB-4225).
type ClassifyResult = {
  prNumber: string
  classification: string
  headRef: string | null
  baseRef: string | null
  headRepository: string | null
  forkPr: boolean | null
  markerKind: string | null
}

function parseResult(context: ToolCardContext): ClassifyResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const prNumber = displayValue(parsed.pr_number)
  const classification = displayValue(parsed.classification)
  if (!prNumber || !classification) return null

  const evidence = isPlainObject(parsed.evidence) ? parsed.evidence : {}
  const marker = isPlainObject(evidence.marker) ? evidence.marker : null

  return {
    prNumber,
    classification,
    headRef: displayValue(evidence.head_ref),
    baseRef: displayValue(evidence.base_ref),
    headRepository: displayValue(evidence.head_repository),
    forkPr: typeof evidence.fork_pr === "boolean" ? evidence.fork_pr : null,
    markerKind: marker ? displayValue(marker.kind) : null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return `PR #${result.prNumber}: ${result.classification}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">PR #{result.prNumber}</span>
        <Badge>{result.classification}</Badge>
        {result.forkPr != null ? <Badge>{result.forkPr ? "fork" : "same-repo"}</Badge> : null}
        {result.markerKind ? <Badge>marker: {result.markerKind}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.headRef ? <Row label="Head ref" value={result.headRef} /> : null}
        {result.baseRef ? <Row label="Base ref" value={result.baseRef} /> : null}
        {result.headRepository ? <Row label="Head repository" value={result.headRepository} /> : null}
      </dl>
    </CardShell>
  )
}

const classifyPullRequestToolCard: ToolCardRenderer = {
  toolName: "classify_pull_request",
  collapsedSummary,
  renderExpanded
}

export default classifyPullRequestToolCard
