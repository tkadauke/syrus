import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { changedFilePathsFromUnifiedDiff } from "../../../components/diff/diffRendering"
import { CardShell, EmptyState, EntityReference, InternalLink, displayValue, numberValue, SectionLabel, StatePill } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"
import { MarkdownPreview } from "../toolCardMarkdown"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for read_pr (the Tier 1 tool-card work). Shows PR title,
// number (linked to GitHub when a URL is available), state, body preview,
// and the capped diff.
type PrDiff = { text: string; truncated: boolean; bytes: number | null; omittedBytes: number | null }

type PrCard = {
  number: string
  title: string
  state: string
  htmlUrl: string | null
  body: string | null
  diff: PrDiff | null
  repositorySlug: string | null
  repositoryUrl: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "PR read",
  attempted: (context) => {
    const prNumber = stringFromInput(context, ["pr_number", "pull_request_number", "number"])
    return prNumber ? `Read PR #${prNumber}` : "Read PR"
  },
  retrySafety: "safe",
  recovery: "Retry after GitHub or repository access recovers."
}

function parseDiff(value: unknown): PrDiff | null {
  if (!isPlainObject(value) || typeof value.text !== "string") return null
  return {
    text: value.text,
    truncated: value.truncated === true,
    bytes: numberValue(value.bytes),
    omittedBytes: numberValue(value.omitted_bytes)
  }
}

function parsePr(context: ToolCardContext): PrCard | null {
  const parsed = normalizedToolCardParsedResult(context.parsedResult)
  if (!isPlainObject(parsed) || !isPlainObject(parsed.pr)) return null

  const pr = parsed.pr
  const number = displayValue(pr.number)
  const state = displayValue(pr.state)
  if (!number || !state) return null

  const htmlUrl = displayValue(pr.html_url)
  const repository = repositoryFromPrUrl(htmlUrl)
  return {
    number,
    title: displayValue(pr.title) || `PR #${number}`,
    state,
    htmlUrl,
    body: typeof pr.body === "string" ? pr.body : null,
    diff: parseDiff(pr.diff),
    repositorySlug: repository?.slug ?? null,
    repositoryUrl: repository?.url ?? null
  }
}

function repositoryFromPrUrl(prUrl: string | null) {
  if (!prUrl) return null
  const match = prUrl.match(/^(https?:\/\/github\.com\/([^/]+\/[^/]+))\/pull\/\d+(?:\/|$)/)
  return match ? { url: match[1], slug: match[2] } : null
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const pr = parsePr(context)
  if (!pr) return null
  return `PR #${pr.number} (${pr.state})`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const pr = parsePr(context)
  if (!pr) return null
  const changedFiles = pr.diff ? changedFilePathsFromUnifiedDiff(pr.diff.text) : []

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={pr.number} kind="pull_request" prUrl={pr.htmlUrl} />
        <StatePill state={pr.state} />
        {pr.repositorySlug ? <EntityReference href={pr.repositoryUrl} kind="repository" repositorySlug={pr.repositorySlug} /> : null}
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{pr.title}</div>
      {pr.body?.trim() ? (
        <MarkdownPreview maxLines={6} modalLabel="Full PR body" text={pr.body} title="PR body" />
      ) : (
        <EmptyState>No PR description provided.</EmptyState>
      )}
      {pr.diff ? (
        <div>
          <SectionLabel>Diff</SectionLabel>
          <div className="mt-1 space-y-1">
            <DiffStatBadges stats={diffStats(pr.diff.text)} />
            <div className="flex flex-wrap gap-x-3 gap-y-1 text-2xs text-text-muted">
              {pr.diff.bytes != null ? <span>{pr.diff.bytes.toLocaleString()} bytes total</span> : null}
              {pr.diff.truncated ? (
                <span>Diff truncated{pr.diff.omittedBytes != null ? ` — ${pr.diff.omittedBytes.toLocaleString()} bytes omitted` : ""}</span>
              ) : null}
            </div>
            {changedFiles.length > 0 ? (
              <div className="min-w-0">
                <SectionLabel>Changed files</SectionLabel>
                <ul className="mt-1 space-y-1">
                  {changedFiles.map((path) => (
                    <li className="min-w-0 break-all text-xs" key={path}>
                      {pr.htmlUrl ? <InternalLink href={`${pr.htmlUrl}/files`}>{path}</InternalLink> : path}
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
            {pr.diff.text.trim() ? <RawDiffPreview diff={pr.diff.text} /> : <EmptyState>No diff content returned.</EmptyState>}
          </div>
        </div>
      ) : (
        <EmptyState>No diff is available for this PR.</EmptyState>
      )}
    </CardShell>
  )
}

const readPrToolCard: ToolCardRenderer = {
  toolName: "read_pr",
  collapsedSummary,
  renderExpanded
}

export default readPrToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "open_pr_with_diff",
    label: "Open PR with diff",
    input: { pr_number: 407 },
    parsedResult: {
      pr: {
        number: 407,
        title: "Add linked entity refs to tool cards",
        body: "Updates representative cards and examples so entity references are linked and copyable.",
        state: "open",
        html_url: "https://github.com/tkadauke/syrus/pull/407",
        diff: {
          text: "diff --git a/app/frontend/routes/chat/toolCardUi.tsx b/app/frontend/routes/chat/toolCardUi.tsx\n+copyable PR refs",
          truncated: false,
          bytes: 112
        }
      }
    }
  },
  {
    id: "pr_without_html_url",
    label: "PR without GitHub URL",
    description: "The PR number remains copyable when no external URL is available.",
    input: { pr_number: 408 },
    parsedResult: { pr: { number: 408, title: "Local PR metadata", state: "open" } }
  },
  {
    id: "empty_body_and_diff",
    label: "Empty body and diff",
    input: { pr_number: 409 },
    parsedResult: {
      pr: {
        number: 409,
        title: "Metadata only",
        body: "",
        state: "closed",
        html_url: "https://github.com/tkadauke/syrus/pull/409",
        diff: { text: "", truncated: false, bytes: 0 }
      }
    }
  },
  {
    id: "truncated_diff",
    label: "Truncated diff",
    input: { pr_number: 410 },
    parsedResult: {
      pr: {
        number: 410,
        title: "Large change",
        body: "See **details**.",
        state: "open",
        html_url: "https://github.com/tkadauke/syrus/pull/410",
        diff: { text: "diff --git a/old.rb b/new.rb\n+changed", truncated: true, bytes: 640020, omitted_bytes: 588820 }
      }
    }
  },
  {
    id: "failure",
    label: "Read failure",
    input: { pr_number: 404 },
    resultBody: "Error: pull request not found: 404",
    resultError: true
  }
]

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
