import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { parsePendingActionResult, PendingActionResultCard, pendingActionCollapsedSummary } from "@app/routes/chat/pendingActionToolCard"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { Badge, CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { DesignDocHeader, t, type DesignDocSummary } from "../designDocToolCard"

type ArchivedResult = {
  kind: "archived"
  doc: DesignDocSummary
  previousState: string | null
  newState: string | null
  reason: string
}

type PendingResult = {
  kind: "pending"
  doc: DesignDocSummary
  pending: NonNullable<ReturnType<typeof parsePendingActionResult>>
  confirmationRequired: boolean
  confirmationReason: string
  designDocId: string | null
}

type ErrorResult = { kind: "error"; message: string }
type DeleteDesignDocResult = ArchivedResult | PendingResult | ErrorResult

function errorMessage(value: unknown): string | null {
  const direct = displayValue(value)
  if (direct) return direct
  if (!isPlainObject(value)) return null
  return displayValue(value.message) || displayValue(value.error_message) || errorMessage(value.error)
}

function docSummary(value: Record<string, unknown>): DesignDocSummary | null {
  const docRef = displayValue(value.doc_ref)
  if (!docRef) return null

  return {
    docRef,
    title: displayValue(value.title) || t("tool_untitled_design_doc"),
    visibility: null,
    state: displayValue(value.new_state) || displayValue(value.state),
    pendingSuggestionsCount: null,
    openThreadsCount: null
  }
}

function deleteDesignDoc(context: ToolCardContext): DeleteDesignDocResult | null {
  const value = context.parsedResult
  if (!isPlainObject(value)) {
    if (!context.resultError) return null
    return { kind: "error", message: displayValue(context.resultBody) || t("tool_archive_failed") }
  }

  const failure = errorMessage(value.error) || (context.resultError ? errorMessage(value) : null)
  if (failure) return { kind: "error", message: failure }

  const doc = docSummary(value)
  if (!doc) return null

  if (value.archived === true && value.immediate === true) {
    return {
      kind: "archived",
      doc,
      previousState: displayValue(value.previous_state),
      newState: displayValue(value.new_state),
      reason: displayValue(value.reason) || ""
    }
  }

  const pending = parsePendingActionResult(context)
  if (!pending || (pending.kind !== "standard" && pending.kind !== "bulk")) return null

  return {
    kind: "pending",
    doc,
    pending,
    confirmationRequired: value.confirmation_required === true,
    confirmationReason: displayValue(value.confirmation_reason) || "",
    designDocId: displayValue(value.design_doc_id)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = deleteDesignDoc(context)
  if (!result) return null
  if (result.kind === "error") return t("tool_archive_error_summary", { message: result.message })
  if (result.kind === "pending") return `${result.doc.docRef} · ${pendingActionCollapsedSummary(result.pending)}`
  return t("tool_archived_summary", { doc: result.doc.docRef, title: result.doc.title })
}

function renderExpanded(context: ToolCardContext) {
  const result = deleteDesignDoc(context)
  if (!result) return null

  if (result.kind === "error") {
    return (
      <CardShell>
        <div className="rounded border border-danger/30 bg-danger/10 px-3 py-2">
          <div className="text-xs font-semibold text-danger">{t("tool_archive_failed")}</div>
          <div className="mt-1 break-words text-xs text-text-primary [overflow-wrap:anywhere]">{result.message}</div>
        </div>
      </CardShell>
    )
  }

  return (
    <div className="min-w-0 space-y-2">
      <CardShell>
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <Badge>{result.kind === "archived" ? t("tool_archived") : t("tool_archive_requested")}</Badge>
          {result.kind === "archived" ? <Badge>{t("tool_immediate")}</Badge> : null}
          {result.kind === "pending" && result.confirmationRequired ? <Badge>{t("tool_confirmation_required")}</Badge> : null}
        </div>
        <DesignDocHeader doc={result.doc} />
        <div className="break-words text-sm font-medium text-text-primary [overflow-wrap:anywhere]">{result.doc.title}</div>
        {result.kind === "archived" ? (
          <>
            <div className="flex min-w-0 flex-wrap items-center gap-2" aria-label={t("tool_state_transition")}>
              {result.previousState ? <StatePill state={result.previousState} /> : <span className="text-xs text-text-subtle">—</span>}
              <span aria-hidden="true" className="text-text-subtle">
                →
              </span>
              {result.newState ? <StatePill state={result.newState} /> : <span className="text-xs text-text-subtle">—</span>}
            </div>
            <MarkdownPreview emptyLabel={t("tool_no_archive_reason")} linkifyUrls maxChars={720} text={result.reason} title={t("tool_reason")} />
          </>
        ) : (
          <>
            {result.designDocId ? <Row label={t("tool_design_doc_id")} value={result.designDocId} /> : null}
            <MarkdownPreview
              emptyLabel={t("tool_no_confirmation_reason")}
              linkifyUrls
              maxChars={720}
              text={result.confirmationReason}
              title={t("tool_confirmation_reason")}
            />
          </>
        )}
      </CardShell>
      {result.kind === "pending" ? <PendingActionResultCard result={result.pending} /> : null}
    </div>
  )
}

const deleteDesignDocToolCard: ToolCardRenderer = {
  toolName: "delete_design_doc",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "immediate_archive",
    label: "Immediate archive",
    parsedResult: {
      archived: true,
      immediate: true,
      doc_ref: "DOC-42",
      title: "Disposable draft",
      previous_state: "draft",
      new_state: "archived",
      reason: "Fresh empty draft."
    }
  },
  {
    id: "pending_confirmation",
    label: "Pending confirmation",
    parsedResult: {
      pending_confirmation_id: 91,
      pending_action_id: 91,
      state: "pending",
      message: "Archive DOC-42?",
      doc_ref: "DOC-42",
      title: "Established design",
      confirmation_required: true,
      confirmation_reason: "Doc has **2 comments**.",
      design_doc_id: 42
    }
  },
  {
    id: "archive_error",
    label: "Archive error",
    parsedResult: { error: "not allowed to archive DOC-42" },
    resultError: true
  }
]

export default deleteDesignDocToolCard
