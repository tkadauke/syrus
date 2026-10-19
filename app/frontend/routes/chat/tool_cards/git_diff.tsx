import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Notice } from "../../../components/ui"
import { EmptyState } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Local Mode tool card for git_diff (the tool-card work). Reuses the
// shared diff preview from toolCardDiff.tsx (get_job_diff/read_pr), which
// already caps very large diffs to a bounded preview.
function parseDiff(context: ToolCardContext): string | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.diff !== "string") return null
  return parsed.diff
}

function errorText(context: ToolCardContext) {
  if (context.resultError) return context.resultBody.trim() || "Unable to read the local diff."
  const text = typeof context.parsedResult === "string" ? context.parsedResult : context.resultBody
  return /local daemon|failed|error/i.test(text) ? text.trim() : null
}

function collapsedSummary(context: ToolCardContext) {
  if (errorText(context)) return "Unable to read local diff"
  const diff = parseDiff(context)
  if (diff == null) return null
  if (!diff.trim()) return "No uncommitted changes"

  const stats = diffStats(diff)
  return `+${stats.additions} -${stats.deletions} across ${stats.fileCount} file${stats.fileCount === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const error = errorText(context)
  if (error) return <Notice tone="danger" title="Unable to read local diff">{error} Connect or restart the local daemon, then try again.</Notice>
  const diff = parseDiff(context)
  if (diff == null) return null
  if (!diff.trim()) return <EmptyState>No uncommitted changes.</EmptyState>

  const stats = diffStats(diff)
  return (
    <div className="mt-1 space-y-1">
      <DiffStatBadges stats={stats} />
      <RawDiffPreview diff={diff} />
    </div>
  )
}

const gitDiffToolCard: ToolCardRenderer = {
  toolName: "git_diff",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  { id: "changes", label: "Local changes", parsedResult: { diff: "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-old\n+new" } },
  { id: "empty", label: "No local changes", parsedResult: { diff: "" } },
  { id: "daemon_error", label: "Daemon unavailable", resultBody: "Local daemon not connected. Start it and try again.", resultError: true }
]

export default gitDiffToolCard
