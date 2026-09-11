import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for repo_info (the tool-card work). Shows the
// attached repository's default branch, trigger label, agent provider, and
// concise recent-commit/branch counts — full lists stay behind disclosures
// so the card doesn't dump every commit/branch by default.
type CommitRow = { sha: string; subject: string | null }
type BranchRow = { name: string; sha: string | null }

type RepoInfoResult = {
  slug: string
  defaultBranch: string | null
  triggerLabel: string | null
  agentProvider: string | null
  commits: CommitRow[]
  branches: BranchRow[]
}

const failureConfig: ToolFailureConfig = {
  title: "Repository info",
  attempted: (context) => {
    const slug = stringFromInput(context, ["slug", "repository", "repository_slug"])
    return slug ? `Read repository info for ${slug}` : "Read repository info"
  },
  retrySafety: "safe",
  recovery: "Retry after repository access or GitHub availability recovers."
}

function commitRows(value: unknown): CommitRow[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const sha = displayValue(item.sha)
    if (!sha) return []
    return [{ sha, subject: displayValue(item.subject) }]
  })
}

function branchRows(value: unknown): BranchRow[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const name = displayValue(item.name)
    if (!name) return []
    return [{ name, sha: displayValue(item.sha) }]
  })
}

function parseResult(context: ToolCardContext): RepoInfoResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.repository)) return null

  const repository = parsed.repository
  const slug = displayValue(repository.slug)
  if (!slug) return null

  return {
    slug,
    defaultBranch: displayValue(repository.default_branch),
    triggerLabel: displayValue(repository.trigger_label),
    agentProvider: displayValue(repository.agent_provider),
    commits: commitRows(repository.recent_commits),
    branches: branchRows(repository.branches)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  return result.defaultBranch ? `${result.slug} (default: ${result.defaultBranch})` : result.slug
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{result.slug}</span>
        {result.triggerLabel ? <Badge>label: {result.triggerLabel}</Badge> : null}
        {result.agentProvider ? <Badge>{result.agentProvider}</Badge> : null}
      </div>
      {result.defaultBranch ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Default branch" value={result.defaultBranch} />
        </dl>
      ) : null}
      {result.commits.length > 0 ? (
        <Disclosure label={`${result.commits.length} recent ${result.commits.length === 1 ? "commit" : "commits"}`}>
          <ul className="space-y-0.5 font-mono">
            {result.commits.map((commit) => (
              <li className="truncate" key={commit.sha} title={commit.subject ?? undefined}>
                {commit.sha.slice(0, 12)}{commit.subject ? ` ${commit.subject}` : ""}
              </li>
            ))}
          </ul>
        </Disclosure>
      ) : null}
      {result.branches.length > 0 ? (
        <Disclosure label={`${result.branches.length} ${result.branches.length === 1 ? "branch" : "branches"}`}>
          <ul className="space-y-0.5 font-mono">
            {result.branches.map((branch) => (
              <li className="truncate" key={branch.name}>
                {branch.name}{branch.sha ? ` @ ${branch.sha.slice(0, 12)}` : ""}
              </li>
            ))}
          </ul>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const repoInfoToolCard: ToolCardRenderer = {
  toolName: "repo_info",
  collapsedSummary,
  renderExpanded
}

export default repoInfoToolCard

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
