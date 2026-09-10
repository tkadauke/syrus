import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
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

function collapsedSummary(context: ToolCardContext) {
  const diff = parseDiff(context)
  if (diff == null) return null
  if (!diff.trim()) return "No uncommitted changes"

  const stats = diffStats(diff)
  return `+${stats.additions} -${stats.deletions} across ${stats.fileCount} file${stats.fileCount === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
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

export default gitDiffToolCard
