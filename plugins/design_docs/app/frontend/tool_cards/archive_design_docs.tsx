import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, PendingActionResultCard, pendingActionCollapsedSummary } from "@app/routes/chat/pendingActionToolCard"
import { Badge, CardShell, displayValue, numberValue } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import { t } from "../designDocToolCard"

type Target = { docRef: string; title: string; reason: string | null }

function targets(value: unknown, skipped = false): Target[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    if (!isPlainObject(entry)) return []
    const docRef = displayValue(entry.doc_ref)
    const title = displayValue(entry.title)
    if (!docRef || !title) return []
    return [{ docRef, title, reason: skipped ? displayValue(entry.reason) : null }]
  })
}

function parsed(context: ToolCardContext) {
  if (!isPlainObject(context.parsedResult)) return null
  const value = context.parsedResult
  const requestedRefs = Array.isArray(value.requested_refs) ? value.requested_refs.flatMap((ref) => (displayValue(ref) ? [displayValue(ref)!] : [])) : []
  if (requestedRefs.length === 0) return null
  return {
    requestedRefs,
    eligibleCount: numberValue(value.eligible_count) ?? 0,
    skippedCount: numberValue(value.skipped_count) ?? 0,
    state: displayValue(value.state) || "unknown",
    reason: displayValue(value.reason) || "",
    targets: targets(value.targets),
    skipped: targets(value.skipped, true),
    pending: parsePendingActionResult(context)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsed(context)
  if (!result) return null
  if (result.pending) return t("tool_bulk_archive_summary", { count: result.eligibleCount, state: pendingActionCollapsedSummary(result.pending) })
  return t("tool_bulk_archive_skipped_summary", { count: result.skippedCount })
}

function TargetList({ items }: { items: Target[] }) {
  if (items.length === 0) return null
  return (
    <ul className="max-h-56 space-y-1 overflow-y-auto rounded border border-border bg-surface-subtle px-3 py-2 text-xs">
      {items.map((item) => (
        <li className="flex min-w-0 flex-wrap justify-between gap-2" key={item.docRef}>
          <span className="min-w-0 break-words text-text-primary [overflow-wrap:anywhere]">
            <a className="font-medium text-brand hover:underline" href={`/design_docs/${item.docRef.replace(/^DOC-/, "")}`}>
              {item.docRef}
            </a>{" "}
            — {item.title}
          </span>
          {item.reason ? <span className="text-warning-text">{item.reason}</span> : null}
        </li>
      ))}
    </ul>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parsed(context)
  if (!result) return null
  return (
    <div className="min-w-0 space-y-2">
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <Badge>{t("tool_bulk_archive")}</Badge>
          <Badge>{result.state}</Badge>
          <span className="text-xs text-text-subtle">{t("tool_bulk_archive_counts", { eligible: result.eligibleCount, skipped: result.skippedCount })}</span>
        </div>
        <div>
          <div className="mb-1 text-xs font-medium text-text-secondary">{t("tool_targets")}</div>
          <TargetList items={result.targets} />
        </div>
        {result.skipped.length > 0 ? (
          <div>
            <div className="mb-1 text-xs font-medium text-text-secondary">{t("tool_skipped_targets")}</div>
            <TargetList items={result.skipped} />
          </div>
        ) : null}
        <div className="break-words text-xs text-text-secondary [overflow-wrap:anywhere]">
          <span className="font-medium">{t("tool_reason")}:</span> {result.reason || t("tool_no_archive_reason")}
        </div>
      </CardShell>
      {result.pending ? <PendingActionResultCard result={result.pending} /> : null}
    </div>
  )
}

const archiveDesignDocsToolCard: ToolCardRenderer = {
  toolName: "archive_design_docs",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "grouped_preview",
    label: "Grouped archive preview",
    parsedResult: {
      pending_action_group_id: 8,
      pending_action_id: 81,
      state: "pending",
      requested_refs: ["DOC-42", "DOC-43", "DOC-44"],
      eligible_count: 2,
      skipped_count: 1,
      member_count: 2,
      reason: "The designs have shipped.",
      targets: [
        { doc_ref: "DOC-42", title: "Checkout flow" },
        { doc_ref: "DOC-43", title: "Review workflow" }
      ],
      skipped: [{ doc_ref: "DOC-44", title: "Earlier draft", reason: "already archived" }]
    }
  }
]

export default archiveDesignDocsToolCard
