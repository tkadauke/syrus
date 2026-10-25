import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Notice } from "../../../components/ui"
import i18n from "../../../i18n"
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
  if (context.resultError) return context.resultBody.trim() || i18n.t("chat:tool_card_git_diff_error_detail")
  const text = typeof context.parsedResult === "string" ? context.parsedResult : context.resultBody
  return /local daemon|failed|error/i.test(text) ? text.trim() : null
}

function collapsedSummary(context: ToolCardContext) {
  if (errorText(context)) return i18n.t("chat:tool_card_git_diff_error")
  const diff = parseDiff(context)
  if (diff == null) return null
  if (!diff.trim()) return i18n.t("chat:tool_card_git_diff_empty_summary")

  const stats = diffStats(diff)
  return i18n.t("chat:tool_card_git_diff_summary", { additions: stats.additions, deletions: stats.deletions, count: stats.fileCount })
}

function renderExpanded(context: ToolCardContext) {
  const error = errorText(context)
  if (error)
    return (
      <Notice tone="danger" title={i18n.t("chat:tool_card_git_diff_error")}>
        {error} {i18n.t("chat:tool_card_git_diff_recovery")}
      </Notice>
    )
  const diff = parseDiff(context)
  if (diff == null) return null
  if (!diff.trim()) return <EmptyState>{i18n.t("chat:tool_card_git_diff_empty")}</EmptyState>

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
  {
    id: "changes",
    label: i18n.t("chat:tool_card_git_diff_example_changes"),
    parsedResult: { diff: "diff --git a/app.rb b/app.rb\n--- a/app.rb\n+++ b/app.rb\n@@ -1 +1 @@\n-old\n+new" }
  },
  { id: "empty", label: i18n.t("chat:tool_card_git_diff_example_empty"), parsedResult: { diff: "" } },
  {
    id: "daemon_error",
    label: i18n.t("chat:tool_card_git_diff_example_error"),
    resultBody: "Local daemon not connected. Start it and try again.",
    resultError: true
  }
]

export default gitDiffToolCard
