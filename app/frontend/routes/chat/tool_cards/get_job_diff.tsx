import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { CardShell, displayValue, numberValue, Row, SectionLabel } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Core-owned tool card for get_job_diff (the Tier 1 tool-card work). Shows a
// file/diff summary plus paginated raw diff access for the Job's latest
// stored agent diff.
type DiffCard = {
  jobId: string
  runId: string | null
  diff: string | null
  message: string | null
  page: number | null
  totalPages: number | null
  totalBytes: number | null
  hasNextPage: boolean
  pageOutOfRange: boolean
}

function parseDiffCard(context: ToolCardContext): DiffCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const jobId = displayValue(parsed.job_id)
  if (!jobId) return null

  return {
    jobId,
    runId: displayValue(parsed.run_id),
    diff: typeof parsed.diff === "string" ? parsed.diff : null,
    message: displayValue(parsed.message),
    page: numberValue(parsed.page),
    totalPages: numberValue(parsed.total_pages),
    totalBytes: numberValue(parsed.total_bytes),
    hasNextPage: parsed.has_next_page === true,
    pageOutOfRange: parsed.page_out_of_range === true
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseDiffCard(context)
  if (!card) return null
  if (card.pageOutOfRange) return i18n.t("chat:tool_card_diff_page_out_of_range", { jobId: card.jobId, page: card.page ?? "?" })
  if (card.diff === null) return `JOB-${card.jobId}: no stored diff`
  return `JOB-${card.jobId} diff (page ${card.page ?? 1} of ${card.totalPages ?? 1})`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseDiffCard(context)
  if (!card) return null

  if (card.diff === null || card.pageOutOfRange) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">JOB-{card.jobId}</span>
        </div>
        <div className="text-gray-500 dark:text-gray-400">{card.message || "No stored diff is available for this Job yet."}</div>
      </CardShell>
    )
  }

  const stats = diffStats(card.diff)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">JOB-{card.jobId}</span>
        {card.runId ? <span className="font-mono text-gray-500 dark:text-gray-400">RUN-{card.runId}</span> : null}
      </div>
      <DiffStatBadges stats={stats} />
      {(card.page ?? 1) > 1 || card.hasNextPage ? <div className="text-text-secondary text-xs">{i18n.t("chat:tool_card_diff_page_only_stats")}</div> : null}
      {card.page != null && card.totalPages != null ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Page" value={`${card.page} of ${card.totalPages}${card.hasNextPage ? " (more available)" : ""}`} />
          {card.totalBytes != null ? <Row label="Total bytes" value={String(card.totalBytes)} /> : null}
        </dl>
      ) : null}
      <div>
        <SectionLabel>Diff</SectionLabel>
        <div className="mt-1">
          <RawDiffPreview diff={card.diff} />
        </div>
      </div>
    </CardShell>
  )
}

const getJobDiffToolCard: ToolCardRenderer = {
  toolName: "get_job_diff",
  collapsedSummary,
  renderExpanded
}

export default getJobDiffToolCard
