import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "../toolCardUi"

// Core-owned tool card for attach_repository (EPIC-293 / JOB-4225). Shows
// the resolved repository slug/default branch plus where the chat
// workspace cloned or fast-forwarded it to.
type AttachRepositoryResult = {
  slug: string
  defaultBranch: string | null
  workspacePath: string | null
  repositoryPath: string | null
}

function parseResult(context: ToolCardContext): AttachRepositoryResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.repository)) return null

  const slug = displayValue(parsed.repository.slug)
  if (!slug) return null

  return {
    slug,
    defaultBranch: displayValue(parsed.repository.default_branch),
    workspacePath: displayValue(parsed.workspace_path),
    repositoryPath: displayValue(parsed.repository_path)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return `Attached ${result.slug}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{result.slug}</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.defaultBranch ? <Row label="Default branch" value={result.defaultBranch} /> : null}
        {result.repositoryPath ? <Row label="Repository path" value={result.repositoryPath} /> : null}
      </dl>
    </CardShell>
  )
}

const attachRepositoryToolCard: ToolCardRenderer = {
  toolName: "attach_repository",
  collapsedSummary,
  renderExpanded
}

export default attachRepositoryToolCard
