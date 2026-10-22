import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { Badge, CardShell, Disclosure, EmptyState, EntityReference, displayValue, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for repo_info (the tool-card work). Shows the
// attached repository's default branch, trigger label, agent provider, and
// concise recent-commit/branch counts — full lists stay behind disclosures
// so the card doesn't dump every commit/branch by default.
type CommitRow = { sha: string; subject: string | null }
type BranchRow = { name: string; sha: string | null }

type RepoInfoResult = {
  id: string | null
  slug: string
  url: string
  defaultBranch: string | null
  triggerLabel: string | null
  agentProvider: string | null
  commits: CommitRow[]
  branches: BranchRow[]
}

const failureConfig: ToolFailureConfig = {
  title: "Repository info",
  attempted: (context) => {
    const slug = repositorySlug(context) ?? stringFromInput(context, ["slug", "repository", "repository_slug"])
    return slug ? `Read repository info for ${slug}` : "Read repository info"
  },
  retrySafety: "safe",
  recovery: "Retry after repository access or GitHub availability recovers."
}

function repositorySlug(context: ToolCardContext): string | null {
  return stringFromNestedResult(context.parsedResult, ["slug", "repository_slug"])
}

function stringFromNestedResult(value: unknown, keys: string[]): string | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = stringFromNestedResult(item, keys)
      if (found) return found
    }
    return null
  }
  if (!isPlainObject(value)) return null

  for (const key of keys) {
    const found = displayValue(value[key])
    if (found) return found
  }
  for (const child of Object.values(value)) {
    const found = stringFromNestedResult(child, keys)
    if (found) return found
  }
  return null
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
    id: displayValue(repository.id),
    slug,
    url: displayValue(repository.url) ?? `https://github.com/${slug}`,
    defaultBranch: displayValue(repository.default_branch),
    triggerLabel: displayValue(repository.trigger_label),
    agentProvider: displayValue(repository.agent_provider),
    commits: commitRows(repository.recent_commits),
    branches: branchRows(repository.branches)
  }
}

function githubPath(result: RepoInfoResult, kind: "commit" | "tree", value: string) {
  const encoded = value.split("/").map(encodeURIComponent).join("/")
  return `${result.url}/${kind}/${encoded}`
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  return result.defaultBranch ? `${result.slug} (default: ${result.defaultBranch})` : result.slug
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference kind="repository" repositoryId={result.id} repositorySlug={result.slug} />
        {result.triggerLabel ? <Badge>label: {result.triggerLabel}</Badge> : null}
        {result.agentProvider ? <Badge>{result.agentProvider}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.id ? <Row label="Repository ID" value={result.id} /> : null}
        {result.defaultBranch ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase text-text-muted">Default branch</div>
            <EntityReference
              href={githubPath(result, "tree", result.defaultBranch)}
              id={result.defaultBranch}
              kind="artifact"
              label={result.defaultBranch}
              slug={result.defaultBranch}
            />
          </div>
        ) : null}
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">GitHub</div>
          <EntityReference href={result.url} id={result.url} kind="artifact" label={result.url} slug={result.url} />
        </div>
      </dl>
      {result.commits.length > 0 ? (
        <Disclosure label={`${result.commits.length} recent ${result.commits.length === 1 ? "commit" : "commits"}`}>
          <ul className="space-y-1">
            {result.commits.map((commit) => (
              <li className="flex min-w-0 flex-wrap items-baseline gap-x-2" key={commit.sha}>
                <EntityReference
                  href={githubPath(result, "commit", commit.sha)}
                  id={commit.sha}
                  kind="artifact"
                  label={commit.sha.slice(0, 12)}
                  slug={commit.sha}
                  wrap="nowrap"
                />
                {commit.subject ? <span className="min-w-0 break-words text-xs text-text-secondary">{commit.subject}</span> : null}
              </li>
            ))}
          </ul>
        </Disclosure>
      ) : (
        <EmptyState>No recent commits found.</EmptyState>
      )}
      {result.branches.length > 0 ? (
        <Disclosure label={`${result.branches.length} ${result.branches.length === 1 ? "branch" : "branches"}`}>
          <ul className="space-y-1">
            {result.branches.map((branch) => (
              <li className="flex min-w-0 flex-wrap items-center gap-x-2" key={branch.name}>
                <EntityReference href={githubPath(result, "tree", branch.name)} id={branch.name} kind="artifact" label={branch.name} slug={branch.name} />
                {branch.sha ? (
                  <EntityReference
                    href={githubPath(result, "commit", branch.sha)}
                    id={branch.sha}
                    kind="artifact"
                    label={branch.sha.slice(0, 12)}
                    slug={branch.sha}
                    wrap="nowrap"
                  />
                ) : null}
              </li>
            ))}
          </ul>
        </Disclosure>
      ) : (
        <EmptyState>No branches found.</EmptyState>
      )}
    </CardShell>
  )
}

const repoInfoToolCard: ToolCardRenderer = {
  toolName: "repo_info",
  collapsedSummary,
  renderExpanded
}

export default repoInfoToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repository_activity",
    label: "Repository activity",
    parsedResult: {
      repository: {
        id: 1,
        slug: "tkadauke/syrus",
        url: "https://github.com/tkadauke/syrus",
        default_branch: "main",
        trigger_label: "syrus",
        agent_provider: "codex",
        recent_commits: [{ sha: "abcdef1234567890", subject: "Keep long commit subjects readable on narrow screens" }],
        branches: [{ name: "main", sha: "abcdef1234567890" }]
      }
    }
  },
  {
    id: "empty_activity",
    label: "Repository with no activity",
    parsedResult: { repository: { id: 1, slug: "acme/empty", default_branch: "main", recent_commits: [], branches: [] } }
  },
  {
    id: "repository_error",
    label: "Repository error",
    resultError: true,
    parsedResult: { repository: { slug: "acme/private" }, error: "GitHub access is unavailable" }
  }
]
