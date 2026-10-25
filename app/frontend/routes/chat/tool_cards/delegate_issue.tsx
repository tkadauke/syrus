import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EntityReference, Row } from "../toolCardUi"
import i18n from "@app/i18n"

function repositorySlug(context: ToolCardContext, message: string | null) {
  const inputSlug = displayValue(context.input?.repository_slug)
  if (inputSlug) return inputSlug

  const match = message?.match(/\bin ([^\s/]+\/[^\s?]+?)(?:\s+to\s+Syrus)?\?*$/)
  return match?.[1] ?? null
}

function jobIdFromUrl(url: string | null) {
  if (!url) return null
  const match = url.match(/^\/jobs\/(\d+)(?:[/?#]|$)/)
  return match?.[1] ?? null
}

function DelegateIssueDetails({ context, result }: { context: ToolCardContext; result: ReturnType<typeof parsePendingActionResult> }) {
  const input = isPlainObject(context.input) ? context.input : {}
  const repositoryId = displayValue(input.repository_id)
  const issueNumber = displayValue(input.issue_number)
  const message = result && result.kind !== "dry_run_evidence" ? result.message : null
  const slug = repositorySlug(context, message)
  const issueUrl = slug && issueNumber ? `https://github.com/${slug}/issues/${encodeURIComponent(issueNumber)}` : null
  const resourceUrl = result && (result.kind === "standard" || result.kind === "bulk") ? result.resourceUrl : null
  const resourceTitle = result && (result.kind === "standard" || result.kind === "bulk") ? result.resourceTitle : null
  const jobId = jobIdFromUrl(resourceUrl)

  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
      <Row
        label={i18n.t("chat:shared.repository")}
        value={
          repositoryId ? (
            <EntityReference
              kind="repository"
              label={slug || i18n.t("chat:shared.repository_with_id", { id: repositoryId })}
              repositoryId={repositoryId}
              repositorySlug={slug}
            />
          ) : (
            <span className="text-text-muted">{i18n.t("chat:mutation_not_provided")}</span>
          )
        }
      />
      <Row
        label={i18n.t("chat:mutation_github_issue")}
        value={
          issueNumber ? (
            <EntityReference id={issueNumber} issueUrl={issueUrl} kind="issue" />
          ) : (
            <span className="text-text-muted">{i18n.t("chat:mutation_not_provided")}</span>
          )
        }
      />
      {resourceUrl ? (
        <Row
          label={i18n.t("chat:mutation_resulting_job")}
          value={
            jobId ? (
              <span className="flex min-w-0 flex-wrap items-center gap-1">
                <EntityReference href={resourceUrl} id={jobId} kind="job" />
                {resourceTitle ? <span className="break-words text-text-secondary">{resourceTitle}</span> : null}
              </span>
            ) : (
              <EntityReference
                href={resourceUrl}
                id={resourceTitle || i18n.t("chat:mutation_view_result")}
                kind="artifact"
                label={resourceTitle || i18n.t("chat:mutation_view_result")}
              />
            )
          }
        />
      ) : null}
    </dl>
  )
}

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context)
  return result ? <PendingActionResultCard details={<DelegateIssueDetails context={context} result={result} />} omitResource result={result} /> : null
}

const delegateIssueToolCard: ToolCardRenderer = {
  toolName: "delegate_issue",
  collapsedSummary,
  renderExpanded
}

export default delegateIssueToolCard
