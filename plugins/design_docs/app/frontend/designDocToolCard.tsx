import { isPlainObject } from "@app/pluginToolCards"
import i18n from "i18next"
import { Badge, displayValue, InternalLink, numberValue, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation for the design_docs plugin's chat tool cards (the pending-action tool-card work
// / read_design_doc, propose_design_doc, suggest_design_doc_change,
// and comment_on_design_doc all echo a design_doc summary (list_payload or
// detail_payload -- see plugins/design_docs/app/services/design_docs/tool_support.rb),
// so this module parses that common subset once.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason core keeps
// toolCardUi.tsx one directory up, and scheduled_tasks keeps its own shared
// module beside this one).
export type DesignDocSummary = {
  docRef: string
  title: string
  visibility: string | null
  state: string | null
  pendingSuggestionsCount: number | null
  openThreadsCount: number | null
}

export function parseDesignDocSummary(value: unknown): DesignDocSummary | null {
  if (!isPlainObject(value)) return null

  const docRef = displayValue(value.doc_ref)
  const title = displayValue(value.title)
  if (!docRef || !title) return null

  return {
    docRef,
    title,
    visibility: displayValue(value.visibility),
    state: displayValue(value.state),
    pendingSuggestionsCount: numberValue(value.pending_suggestions_count),
    openThreadsCount: numberValue(value.open_threads_count)
  }
}

function docHref(docRef: string): string | null {
  const match = docRef.match(/(\d+)\s*$/)
  return match ? `/design_docs/${match[1]}` : null
}

export function DesignDocHeader({ doc }: { doc: DesignDocSummary }) {
  const href = docHref(doc.docRef)

  return (
    <div className="flex flex-wrap items-center gap-2">
      {href ? (
        <InternalLink href={href}>{doc.docRef}</InternalLink>
      ) : (
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{doc.docRef}</span>
      )}
      {doc.state ? <StatePill state={doc.state} /> : null}
      {doc.visibility ? <Badge>{doc.visibility}</Badge> : null}
    </div>
  )
}

// Concise content metadata for a markdown blob without rendering the whole
// document inline -- the raw JSON "Raw details" disclosure covers that.
export function contentMetadata(markdown: unknown): string | null {
  const text = typeof markdown === "string" ? markdown.trim() : ""
  if (!text) return null

  const words = text.split(/\s+/).filter(Boolean).length
  return t("tool_word_count", { count: words })
}

export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`design_docs:${key}`, options)
}
