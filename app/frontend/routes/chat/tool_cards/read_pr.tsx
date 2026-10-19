import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, EntityReference, InternalLink, displayValue, numberValue, SectionLabel, StatePill } from "../toolCardUi"
import { changedFilePaths, DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"
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
  repository: string | null
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
  const parsed = parsedObject(context.parsedResult)
  if (!isPlainObject(parsed) || !isPlainObject(parsed.pr)) return null

  const pr = parsed.pr
  const number = displayValue(pr.number)
  const state = displayValue(pr.state)
  if (!number || !state) return null

  const htmlUrl = displayValue(pr.html_url)
  return {
    number,
    title: displayValue(pr.title) || `PR #${number}`,
    state,
    htmlUrl,
    body: displayValue(pr.body),
    diff: parseDiff(pr.diff),
    repository: repositoryFromPrUrl(htmlUrl)
  }
}

function parsedObject(value: unknown): unknown {
  if (typeof value !== "string") return value
  try {
    return JSON.parse(value)
  } catch {
    return value
  }
}

function repositoryFromPrUrl(url: string | null): string | null {
  if (!url) return null
  try {
    const match = new URL(url).pathname.match(/^\/([^/]+\/[^/]+)\/pull\/\d+/)
    return match?.[1] ?? null
  } catch {
    return null
  }
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
  const paths = pr.diff ? changedFilePaths(pr.diff.text) : []

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={pr.number} kind="pull_request" prUrl={pr.htmlUrl} />
        <StatePill state={pr.state} />
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{pr.title}</div>
      <div>
        <SectionLabel>Repository</SectionLabel>
        <div className="mt-1">
          {pr.repository ? (
            <EntityReference href={`https://github.com/${pr.repository}`} kind="repository" repositorySlug={pr.repository} />
          ) : (
            <span className="text-xs text-text-muted">Unknown repository</span>
          )}
        </div>
      </div>
      {pr.body ? <MarkdownPreview maxLines={6} modalLabel="PR body" text={pr.body} title="PR body" /> : <EmptyState>No PR description.</EmptyState>}
      {pr.diff ? (
        <div>
          <SectionLabel>Diff</SectionLabel>
          <div className="mt-1 space-y-1">
            <DiffStatBadges stats={diffStats(pr.diff.text)} />
            {pr.diff.truncated ? (
              <div className="text-2xs text-gray-500 dark:text-gray-400">
                Truncated{pr.diff.omittedBytes != null ? ` — ${pr.diff.omittedBytes} bytes omitted` : ""}
              </div>
            ) : null}
            {pr.diff.bytes != null ? <div className="text-2xs text-text-muted">{pr.diff.bytes} bytes returned</div> : null}
            {pr.diff.text ? (
              <>
                {paths.length > 0 ? (
                  <div className="min-w-0">
                    <SectionLabel>Changed files</SectionLabel>
                    <ul className="mt-1 space-y-1">
                      {paths.map((path) => (
                        <li className="min-w-0 break-all text-xs" key={path}>
                          {pr.htmlUrl ? (
                            <InternalLink href={`${pr.htmlUrl}/files`}>{path}</InternalLink>
                          ) : (
                            <span className="font-mono text-text-primary">{path}</span>
                          )}
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : null}
                <RawDiffPreview diff={pr.diff.text} />
              </>
            ) : (
              <EmptyState>No changes in diff.</EmptyState>
            )}
          </div>
        </div>
      ) : (
        <EmptyState>No diff returned.</EmptyState>
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
  }
]

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
