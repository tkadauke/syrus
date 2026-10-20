import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { useT } from "../../../hooks/useT"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference } from "../toolCardUi"

// Core-owned tool card for classify_pull_request (the tool-card work).
type ClassifyResult = {
  repository: string
  prNumber: string
  classification: string
  headRef: string | null
  baseRef: string | null
  headRepository: string | null
  forkPr: boolean | null
  marker: Record<string, unknown> | null
  markerKind: string | null
  classificationEnabled: boolean | null
}

function parseResult(context: ToolCardContext): ClassifyResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const repository = displayValue(parsed.repository)
  const prNumber = displayValue(parsed.pr_number)
  const classification = displayValue(parsed.classification)
  if (!repository || !prNumber || !classification) return null

  const evidence = isPlainObject(parsed.evidence) ? parsed.evidence : {}
  const marker = isPlainObject(evidence.marker) ? evidence.marker : null

  return {
    repository,
    prNumber,
    classification,
    headRef: displayValue(evidence.head_ref),
    baseRef: displayValue(evidence.base_ref),
    headRepository: displayValue(evidence.head_repository),
    forkPr: typeof evidence.fork_pr === "boolean" ? evidence.fork_pr : null,
    marker,
    markerKind: marker ? displayValue(marker.kind) : null,
    classificationEnabled: typeof evidence.classification_enabled === "boolean" ? evidence.classification_enabled : null
  }
}

function githubUrl(repository: string, suffix = "") {
  return `https://github.com/${repository}${suffix}`
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) {
    const prNumber = displayValue(context.input?.pr_number)
    return prNumber ? `PR #${prNumber} classification failed` : "Pull request classification failed"
  }
  const result = parseResult(context)
  if (!result) return null
  return `PR #${result.prNumber}: ${result.classification}`
}

function ClassifyPullRequestCard({ context, result }: { context: ToolCardContext; result: ClassifyResult | null }) {
  const { t } = useT("chat")

  if (context.resultError) {
    return (
      <CardShell>
        <div className="rounded border border-danger-border bg-danger-surface px-2 py-1 text-danger-text">
          <div className="font-semibold">{t("tool_card_classify_pr_failed")}</div>
          <div className="mt-1 break-words">{displayValue(context.resultBody) ?? t("tool_card_classify_pr_failed_recovery")}</div>
        </div>
      </CardShell>
    )
  }

  if (!result) return <EmptyState>{t("tool_card_classify_pr_empty")}</EmptyState>

  const headRepository = result.headRepository ?? result.repository

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference id={result.prNumber} kind="pull_request" prUrl={githubUrl(result.repository, `/pull/${result.prNumber}`)} />
        <Badge>{result.classification}</Badge>
        {result.forkPr != null ? <Badge>{result.forkPr ? t("tool_card_classify_pr_fork") : t("tool_card_classify_pr_same_repo")}</Badge> : null}
        {result.markerKind ? <Badge>{t("tool_card_classify_pr_marker_badge", { kind: result.markerKind })}</Badge> : null}
      </div>

      {result.classificationEnabled === false ? (
        <div className="rounded border border-warning-border bg-warning-surface px-2 py-1 text-sm text-warning-text" role="alert">
          <span className="font-semibold">{t("tool_card_classify_pr_disabled")}</span> {t("tool_card_classify_pr_disabled_detail")}
        </div>
      ) : null}

      <dl className="grid gap-2 sm:grid-cols-2">
        <div className="min-w-0">
          <dt className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_classify_pr_repository")}</dt>
          <dd>
            <EntityReference href={githubUrl(result.repository)} kind="repository" repositorySlug={result.repository} />
          </dd>
        </div>
        {result.headRepository ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_classify_pr_head_repository")}</dt>
            <dd>
              <EntityReference href={githubUrl(result.headRepository)} kind="repository" repositorySlug={result.headRepository} />
            </dd>
          </div>
        ) : null}
        {result.headRef ? (
          <div className="min-w-0 break-all">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_classify_pr_head_ref")}</dt>
            <dd>
              <a className="font-mono text-xs text-brand hover:underline" href={githubUrl(headRepository, `/tree/${encodeURIComponent(result.headRef)}`)}>
                {result.headRef}
              </a>
            </dd>
          </div>
        ) : null}
        {result.baseRef ? (
          <div className="min-w-0 break-all">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_classify_pr_base_ref")}</dt>
            <dd>
              <a className="font-mono text-xs text-brand hover:underline" href={githubUrl(result.repository, `/tree/${encodeURIComponent(result.baseRef)}`)}>
                {result.baseRef}
              </a>
            </dd>
          </div>
        ) : null}
      </dl>

      {result.marker ? (
        <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
          <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">
            {t("tool_card_classify_pr_marker_details")}
          </summary>
          <div className="mt-2">
            <MarkdownPreview modalLabel={t("tool_card_classify_pr_marker_details")} text={`\`\`\`json\n${JSON.stringify(result.marker, null, 2)}\n\`\`\``} />
          </div>
        </details>
      ) : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  return <ClassifyPullRequestCard context={context} result={parseResult(context)} />
}

const classifyPullRequestToolCard: ToolCardRenderer = {
  toolName: "classify_pull_request",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "classified_job_export",
    label: "Classified pull request with provenance marker",
    input: { pr_number: 42 },
    parsedResult: {
      repository: "acme/widgets",
      pr_number: 42,
      classification: "syrus_job_export",
      evidence: {
        head_ref: "syrus/direct-42",
        base_ref: "main",
        head_repository: "acme/widgets-fork",
        fork_pr: true,
        marker: { kind: "syrus_job_export", job_id: 42, workflow_id: 314 },
        classification_enabled: true
      }
    }
  },
  {
    id: "classification_disabled",
    label: "Classification disabled",
    input: { pr_number: 43 },
    parsedResult: {
      repository: "acme/widgets",
      pr_number: 43,
      classification: "external_unknown",
      evidence: { classification_enabled: false }
    }
  },
  {
    id: "pull_request_not_found",
    label: "Pull request not found",
    input: { pr_number: 404 },
    resultBody: "pull request not found: #404",
    resultError: true
  }
]

export default classifyPullRequestToolCard
