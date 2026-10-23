import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, EntityReference } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for attach_repository (the tool-card work). Shows
// the resolved repository slug/default branch plus where the chat
// workspace cloned or fast-forwarded it to.
type AttachRepositoryResult = {
  id: string
  slug: string
  defaultBranch: string | null
  workspacePath: string | null
  repositoryPath: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "Repository attach",
  attempted: (context) => {
    const slug = stringFromInput(context, ["slug", "repository", "repository_slug"])
    return slug ? `Attach ${slug}` : "Attach repository"
  },
  retrySafety: "safe",
  recovery: "Retry after the repository or workspace issue is corrected."
}

function parseResult(context: ToolCardContext): AttachRepositoryResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.repository)) return null

  const slug = displayValue(parsed.repository.slug)
  if (!slug) return null

  return {
    id: displayValue(parsed.repository.id) ?? "",
    slug,
    defaultBranch: displayValue(parsed.repository.default_branch),
    workspacePath: displayValue(parsed.workspace_path),
    repositoryPath: displayValue(parsed.repository_path)
  }
}

function DetailRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-medium uppercase tracking-wide text-text-muted">{label}</dt>
      <dd className="min-w-0 break-all font-mono text-xs text-text-primary">{children}</dd>
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseResult(context)
  if (!result) return null
  return `Attached ${result.slug}`
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseResult(context)
  if (!result) {
    if (context.parsedResult != null || context.resultBody.trim()) return null
    const requestedSlug = stringFromInput(context, ["slug", "repository", "repository_slug"])
    return <EmptyState>{requestedSlug ? `Attaching ${requestedSlug}…` : "Waiting for repository attachment…"}</EmptyState>
  }

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference id={result.id} kind="repository" repositorySlug={result.slug} slug={result.slug} touchTarget />
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.id ? (
          <DetailRow label="Repository ID">
            <EntityReference id={result.id} kind="repository" label={result.id} repositorySlug={result.slug} touchTarget />
          </DetailRow>
        ) : null}
        {result.defaultBranch ? <DetailRow label="Default branch">{result.defaultBranch}</DetailRow> : null}
        {result.workspacePath ? <DetailRow label="Workspace path">{result.workspacePath}</DetailRow> : null}
        {result.repositoryPath ? <DetailRow label="Repository path">{result.repositoryPath}</DetailRow> : null}
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

export const examples: ToolCardExample[] = [
  {
    id: "attached_repository",
    label: "Attached repository",
    input: { slug: "tkadauke/syrus" },
    parsedResult: {
      repository: { id: 42, slug: "tkadauke/syrus", default_branch: "main" },
      workspace_path: "/data/chat_workspaces/123",
      repository_path: "/data/chat_workspaces/123/repositories/tkadauke/syrus"
    }
  },
  {
    id: "codex_result_body_envelope",
    label: "Codex result-body envelope",
    description: "A resultBody-only fixture exercising the provider envelope normalizer.",
    input: { slug: "tkadauke/syrus" },
    resultBody: JSON.stringify({
      content: [
        {
          type: "text",
          text: JSON.stringify({
            repository: { id: 42, slug: "tkadauke/syrus", default_branch: "main" },
            workspace_path: "/data/chat_workspaces/123",
            repository_path: "/data/chat_workspaces/123/repositories/tkadauke/syrus"
          })
        }
      ]
    }),
    sourceType: "codex"
  },
  {
    id: "pending",
    label: "Attachment pending",
    input: { slug: "tkadauke/syrus" },
    resultBody: ""
  }
]

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
