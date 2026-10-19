import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, EmptyState, SectionLabel } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Local Mode tool card for git_diff (the tool-card work). Reuses the
// shared diff preview from toolCardDiff.tsx (get_job_diff/read_pr), which
// already caps very large diffs to a bounded preview.
function parseDiff(context: ToolCardContext): string | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.diff !== "string") return null
  return parsed.diff
}

function plainTextResult(context: ToolCardContext): string | null {
  let text: string | null = null
  if (typeof context.parsedResult === "string" && context.parsedResult.trim()) text = context.parsedResult.trim()
  if (isPlainObject(context.parsedResult) && Array.isArray(context.parsedResult.content)) {
    const first = context.parsedResult.content[0]
    if (isPlainObject(first) && typeof first.text === "string" && first.text.trim()) text = first.text.trim()
  }
  if (text == null && context.parsedResult == null && context.resultBody.trim()) text = context.resultBody.trim()
  if (!text) return null
  return context.resultError || /(?:local daemon|fail(?:ed|ure)?|error|unable|could not)/i.test(text) ? text : null
}

function filePaths(diff: string): string[] {
  return Array.from(diff.matchAll(/^diff --git a\/(.+?) b\/(.+)$/gm), (match) => match[2])
}

function collapsedSummary(context: ToolCardContext) {
  const diff = parseDiff(context)
  if (diff == null) return plainTextResult(context) ? i18n.t("chat:tool_card_git_diff_failed") : null
  if (!diff.trim()) return "No uncommitted changes"

  const stats = diffStats(diff)
  return `+${stats.additions} -${stats.deletions} across ${stats.fileCount} file${stats.fileCount === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const diff = parseDiff(context)
  if (diff == null) {
    const error = plainTextResult(context)
    if (!error) return null
    return (
      <CardShell>
        <div className="text-sm font-semibold text-danger-text">{i18n.t("chat:tool_card_git_diff_failed")}</div>
        <MarkdownPreview text={error} title={i18n.t("chat:tool_card_git_diff_guidance")} />
      </CardShell>
    )
  }
  if (!diff.trim()) return <EmptyState>No uncommitted changes.</EmptyState>

  const stats = diffStats(diff)
  const paths = filePaths(diff)
  return (
    <CardShell>
      <DiffStatBadges stats={stats} />
      {paths.length > 0 ? (
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:tool_card_git_diff_files")}</SectionLabel>
          <div className="mt-1 flex min-w-0 flex-wrap gap-1">
            {paths.map((path) => (
              <code className="max-w-full break-all rounded bg-surface-inset px-1.5 py-0.5 text-xs text-text-primary" key={path}>
                {path}
              </code>
            ))}
          </div>
        </div>
      ) : null}
      <RawDiffPreview diff={diff} />
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "working_tree_diff",
    label: "Working tree diff",
    parsedResult: { diff: "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-old\n+new" }
  },
  { id: "empty_diff", label: "No changes", parsedResult: { diff: "" } },
  {
    id: "daemon_disconnected",
    label: "Daemon disconnected",
    resultBody: "Local daemon not connected. Run `syrus local` in your repo to continue.",
    resultError: true
  }
]

const gitDiffToolCard: ToolCardRenderer = {
  toolName: "git_diff",
  collapsedSummary,
  renderExpanded
}

export default gitDiffToolCard
