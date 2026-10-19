import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { Notice } from "../../../components/ui"
import { isPlainObject } from "../../../toolCardParsing"
import { Badge, CardShell, Disclosure, displayValue, EntityReference, SectionLabel } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type ClassifyResult = {
  repository: string
  prNumber: string
  classification: string
  headRef: string | null
  baseRef: string | null
  headRepository: string | null
  forkPr: boolean | null
  marker: Record<string, unknown> | null
  classificationEnabled: boolean | null
}

const failureConfig: ToolFailureConfig = {
  title: "PR classification",
  attempted: (context) => {
    const prNumber = stringFromInput(context, ["pr_number", "pull_request_number", "number"])
    return prNumber ? `Classify PR #${prNumber}` : "Classify pull request"
  },
  retrySafety: "caution",
  recovery: "Check that a repository is attached and that the pull request exists, then retry."
}

function parseResult(context: ToolCardContext): ClassifyResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const repository = displayValue(parsed.repository)
  const prNumber = displayValue(parsed.pr_number)
  const classification = displayValue(parsed.classification)
  if (!repository || !prNumber || !classification) return null

  const evidence = isPlainObject(parsed.evidence) ? parsed.evidence : {}
  return {
    repository,
    prNumber,
    classification,
    headRef: displayValue(evidence.head_ref),
    baseRef: displayValue(evidence.base_ref),
    headRepository: displayValue(evidence.head_repository),
    forkPr: typeof evidence.fork_pr === "boolean" ? evidence.fork_pr : null,
    marker: isPlainObject(evidence.marker) ? evidence.marker : null,
    classificationEnabled: typeof evidence.classification_enabled === "boolean" ? evidence.classification_enabled : null
  }
}

function githubUrl(repository: string, suffix = "") {
  return `https://github.com/${repository}${suffix}`
}

function branchUrl(repository: string, branch: string) {
  return githubUrl(repository, `/tree/${encodeURIComponent(branch)}`)
}

function LinkedDetail({ href, label, value }: { href: string; label: string; value: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <a
        className="break-all font-mono text-xs font-medium text-brand hover:underline dark:text-brand-emphasis"
        href={href}
        rel="noreferrer"
        target="_blank"
        title={value}
      >
        {value}
      </a>
    </div>
  )
}

function RepositoryDetail({ label, repository }: { label: string; repository: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <EntityReference href={githubUrl(repository)} kind="repository" repositorySlug={repository} />
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  const result = parseResult(context)
  return result ? `PR #${result.prNumber}: ${result.classification}` : null
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseResult(context)
  if (!result) return null
  const headRepository = result.headRepository || result.repository

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={result.prNumber} kind="pull_request" prUrl={githubUrl(result.repository, `/pull/${result.prNumber}`)} />
        <Badge>{result.classification}</Badge>
        {result.forkPr != null ? <Badge>{result.forkPr ? "fork" : "same-repo"}</Badge> : null}
      </div>
      {result.classificationEnabled === false ? (
        <Notice title="Classification disabled" tone="warning">
          Repository classification is disabled, so this result may not be used to route the pull request.
        </Notice>
      ) : null}
      <dl className="grid gap-2 sm:grid-cols-2">
        <RepositoryDetail label="Repository" repository={result.repository} />
        {result.headRepository ? <RepositoryDetail label="Head repository" repository={result.headRepository} /> : null}
        {result.headRef ? <LinkedDetail href={branchUrl(headRepository, result.headRef)} label="Head ref" value={result.headRef} /> : null}
        {result.baseRef ? <LinkedDetail href={branchUrl(result.repository, result.baseRef)} label="Base ref" value={result.baseRef} /> : null}
      </dl>
      {result.marker ? (
        <Disclosure label="Provenance marker">
          <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-all font-mono text-xs">{JSON.stringify(result.marker, null, 2)}</pre>
        </Disclosure>
      ) : (
        <div>
          <SectionLabel>Provenance marker</SectionLabel>
          <div className="text-xs text-text-muted">No marker found.</div>
        </div>
      )}
    </CardShell>
  )
}

const classifyPullRequestToolCard: ToolCardRenderer = { toolName: "classify_pull_request", collapsedSummary, renderExpanded }
export default classifyPullRequestToolCard

export const examples: ToolCardExample[] = [
  {
    id: "classified_job_export",
    label: "Classified job export",
    input: { pr_number: 42 },
    parsedResult: {
      repository: "tkadauke/syrus",
      pr_number: 42,
      classification: "syrus_job_export",
      evidence: {
        head_ref: "syrus/direct-325",
        base_ref: "main",
        head_repository: "tkadauke/syrus",
        fork_pr: false,
        marker: { kind: "syrus_job_export", job_id: "4225", workflow_id: "9876", note: "Created from the completed implementation workflow." },
        classification_enabled: true
      }
    }
  },
  {
    id: "classification_disabled",
    label: "Classification disabled",
    input: { pr_number: 84 },
    parsedResult: {
      repository: "acme/widgets",
      pr_number: 84,
      classification: "external_unknown",
      evidence: {
        head_ref: "feature/long-lived-branch",
        base_ref: "main",
        head_repository: "contributor/widgets",
        fork_pr: true,
        marker: null,
        classification_enabled: false
      }
    }
  },
  { id: "pull_request_not_found", label: "Pull request not found", input: { pr_number: 999 }, resultBody: "pull request not found: #999", resultError: true }
]
