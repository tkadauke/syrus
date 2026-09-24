import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for detach_repository, the symmetric counterpart to
// attach_repository. Shows which repository was removed and, when it was
// the chat's effective repository, the note the tool returns about what
// (if anything) is now effective for file browsing.
type DetachRepositoryResult = {
  slug: string
  remainingSlugs: string[]
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
  const remainingSlugs = remaining
    .map((entry) => (isPlainObject(entry) ? displayValue(entry.slug) : null))
    .filter((value): value is string => Boolean(value))

  return {
    slug,
    remainingSlugs,
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
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-text-primary">{result.slug}</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Remaining repositories" value={result.remainingSlugs.length ? result.remainingSlugs.join(", ") : "none"} />
      </dl>
      {result.note ? <p className="text-sm text-text-secondary">{result.note}</p> : null}
    </CardShell>
  )
}

const detachRepositoryToolCard: ToolCardRenderer = {
  toolName: "detach_repository",
  collapsedSummary,
  renderExpanded
}

export default detachRepositoryToolCard

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
