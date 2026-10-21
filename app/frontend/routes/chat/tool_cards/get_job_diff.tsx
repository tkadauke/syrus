import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EntityReference, numberValue, Row, SectionLabel } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for get_job_diff (the Tier 1 tool-card work). Shows a
// file/diff summary plus paginated raw diff access for the Job's latest
// stored agent diff.
type DiffCard = {
  jobId: string
  runId: string | null
  diff: string | null
  message: string | null
  page: number | null
  perBytes: number | null
  totalPages: number | null
  totalBytes: number | null
  hasNextPage: boolean
  nextPage: number | null
  pageOutOfRange: boolean
}

const failureConfig: ToolFailureConfig = {
  title: "Job diff read",
  attempted: (context) => {
    const jobId = stringFromInput(context, ["job_id"])
    return jobId ? `Read diff for JOB-${jobId}` : "Read Job diff"
  },
  retrySafety: "safe",
  recovery: "Retry after the Job is available to this chat."
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
    perBytes: numberValue(parsed.per_bytes),
    totalPages: numberValue(parsed.total_pages),
    totalBytes: numberValue(parsed.total_bytes),
    hasNextPage: parsed.has_next_page === true,
    nextPage: numberValue(parsed.next_page),
    pageOutOfRange: parsed.page_out_of_range === true
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const card = parseDiffCard(context)
  if (!card) return null
  if (card.pageOutOfRange) return i18n.t("chat:tool_card_diff_page_out_of_range", { jobId: card.jobId, page: card.page ?? "?" })
  if (card.diff === null) return i18n.t("chat:tool_card_diff_missing", { jobId: card.jobId })
  return i18n.t("chat:tool_card_diff_summary", { jobId: card.jobId, page: card.page ?? 1, totalPages: card.totalPages ?? 1 })
}

function References({ card }: { card: DiffCard }) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <EntityReference id={card.jobId} kind="job" />
      {card.runId ? <EntityReference id={card.runId} jobId={card.jobId} kind="run" /> : null}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const card = parseDiffCard(context)
  if (!card) return null

  if (card.diff === null || card.pageOutOfRange) {
    return (
      <CardShell>
        <References card={card} />
        <MarkdownPreview
          emptyLabel={i18n.t("chat:tool_card_diff_missing_default")}
          maxLines={3}
          modalLabel={i18n.t("chat:tool_card_diff_message")}
          text={card.message}
          title={i18n.t("chat:tool_card_diff_message")}
        />
      </CardShell>
    )
  }

  const stats = diffStats(card.diff)

  return (
    <CardShell>
      <References card={card} />
      <DiffStatBadges stats={stats} />
      {(card.page ?? 1) > 1 || card.hasNextPage ? <div className="text-text-secondary text-xs">{i18n.t("chat:tool_card_diff_page_only_stats")}</div> : null}
      {card.page != null && card.totalPages != null ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row
            label={i18n.t("chat:tool_card_diff_page")}
            value={`${card.page} of ${card.totalPages}${card.hasNextPage ? ` (${i18n.t("chat:tool_card_diff_more_available")})` : ""}`}
            wrap
          />
          {card.perBytes != null ? <Row label={i18n.t("chat:tool_card_diff_bytes_per_page")} value={String(card.perBytes)} /> : null}
          {card.totalBytes != null ? <Row label="Total bytes" value={String(card.totalBytes)} /> : null}
          {card.nextPage != null ? <Row label={i18n.t("chat:tool_card_diff_next_page")} value={String(card.nextPage)} /> : null}
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

export const examples: ToolCardExample[] = [
  {
    id: "paginated_diff",
    label: "Paginated diff",
    input: { job_id: 4221, page: 1, per_bytes: 51200 },
    parsedResult: {
      job_id: 4221,
      run_id: 9,
      diff: "diff --git a/foo.rb b/foo.rb\n@@ -1 +1 @@\n-old\n+new",
      page: 1,
      per_bytes: 51200,
      total_bytes: 640020,
      total_pages: 13,
      has_next_page: true,
      next_page: 2,
      page_out_of_range: false,
      message: null
    }
  },
  {
    id: "missing_diff",
    label: "No stored diff",
    input: { job_id: 4221 },
    parsedResult: {
      job_id: 4221,
      run_id: null,
      diff: null,
      page: 1,
      per_bytes: 51200,
      total_bytes: 0,
      total_pages: 0,
      has_next_page: false,
      message: "No stored diff is available for this Job yet."
    }
  },
  {
    id: "page_out_of_range",
    label: "Page out of range",
    input: { job_id: 4221, page: 14 },
    parsedResult: {
      job_id: 4221,
      run_id: 9,
      diff: "",
      page: 14,
      per_bytes: 51200,
      total_bytes: 640020,
      total_pages: 13,
      has_next_page: false,
      page_out_of_range: true,
      message: "Page 14 is out of range for this 13-page diff."
    }
  }
]
