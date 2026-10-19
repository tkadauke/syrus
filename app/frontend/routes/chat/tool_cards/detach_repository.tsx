import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EmptyState, EntityReference, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for detach_repository, the symmetric counterpart to
// attach_repository. Shows which repository was removed and, when it was
// the chat's effective repository, the note the tool returns about what
// (if anything) is now effective for file browsing.
type DetachRepositoryResult = {
  id: string
  slug: string
  detached: boolean
  remainingRepositories: Array<{ id: string; slug: string }>
  note: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "Repository detach",
  attempted: (context) => {
    const slug = stringFromInput(context, ["slug", "repository", "repository_slug"])
    return slug ? `Detach ${slug}` : "Detach repository"
  },
  retrySafety: "safe",
  recovery: "Retry after confirming the repository is attached to this chat."
}

function parseResult(context: ToolCardContext): DetachRepositoryResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.repository)) return null

  const slug = displayValue(parsed.repository.slug)
  if (!slug) return null

  const remaining = Array.isArray(parsed.remaining_repositories) ? parsed.remaining_repositories : []
  const id = displayValue(parsed.repository.id)
  if (!id) return null

  const remainingRepositories = remaining.flatMap((entry) => {
    if (!isPlainObject(entry)) return []
    const remainingId = displayValue(entry.id)
    const remainingSlug = displayValue(entry.slug)
    return remainingId && remainingSlug ? [{ id: remainingId, slug: remainingSlug }] : []
  })

  return {
    id,
    slug,
    detached: parsed.detached === true,
    remainingRepositories,
    note: displayValue(parsed.note)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  return `Detached ${result.slug}`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <EntityReference kind="repository" repositoryId={result.id} repositorySlug={result.slug} />
        <StatePill state={result.detached ? "detached" : "pending"} tone={result.detached ? "success" : "warning"} />
      </div>
      <div>
        <div className="text-2xs font-semibold uppercase text-text-muted">Repository ID</div>
        <div className="break-all font-mono text-xs text-text-primary">{result.id}</div>
      </div>
      <div>
        <div className="text-2xs font-semibold uppercase text-text-muted">Remaining repositories</div>
        {result.remainingRepositories.length ? (
          <div className="mt-1 flex min-w-0 flex-wrap gap-x-3 gap-y-2">
            {result.remainingRepositories.map((repository) => (
              <EntityReference key={repository.id} kind="repository" repositoryId={repository.id} repositorySlug={repository.slug} />
            ))}
          </div>
        ) : (
          <EmptyState>No repositories remain attached.</EmptyState>
        )}
      </div>
      {result.note ? (
        noteIsProse(result.note) ? (
          <MarkdownPreview linkifyUrls maxChars={240} text={result.note} />
        ) : (
          <span className="break-words text-sm text-text-secondary [overflow-wrap:anywhere]">{result.note}</span>
        )
      ) : null}
    </CardShell>
  )
}

function noteIsProse(note: string) {
  return /[.!?](?:\s|$)/.test(note) || note.includes("\n") || /(?:^|\n)\s*(?:#|[-*>]|\d+[.)])\s/.test(note)
}

const detachRepositoryToolCard: ToolCardRenderer = {
  toolName: "detach_repository",
  collapsedSummary,
  renderExpanded
}

export default detachRepositoryToolCard

export const examples: ToolCardExample[] = [
  {
    id: "detached_with_remaining_repository",
    label: "Detached with another repository remaining",
    input: { slug: "tkadauke/syrus" },
    parsedResult: {
      repository: { id: 1, slug: "tkadauke/syrus" },
      detached: true,
      remaining_repositories: [{ id: 2, slug: "tkadauke/other" }],
      note: "This was the chat's effective repository. **tkadauke/other** is now effective for file browsing."
    }
  },
  {
    id: "no_repositories_remaining",
    label: "No repositories remaining",
    input: { slug: "tkadauke/syrus" },
    parsedResult: {
      repository: { id: 1, slug: "tkadauke/syrus" },
      detached: true,
      remaining_repositories: [],
      note: "This was the chat's only attached repository. Attach a repository before browsing source."
    }
  }
]

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
