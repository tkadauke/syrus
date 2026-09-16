import { useId, useState, type ReactNode } from "react"
import i18n from "i18next"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { CloseIcon } from "@app/components/CloseIcon"
import { Markdown } from "@app/lib/Markdown"
import { Modal } from "@app/components/Modal"

// Shared presentation helpers for the agent_memory plugin's chat tool cards
// (the tool-card work). list_memories, search_memories, read_memory,
// write_memory, publish_memory, and unpublish_memory all echo the same
// `memory_payload` shape (see
// plugins/agent_memory/app/services/agent_memory/tools/memory_tool_support.rb),
// so this module parses and renders that shape once.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason test_insights and
// design_docs keep their shared modules beside this one).
export type MemoryPayload = {
  id: string
  kind: string | null
  scope: string | null
  scopeId: string | null
  content: string
  published: boolean
  author: string | null
  confidence: number | null
  createdAt: string | null
  updatedAt: string | null
  deletedAt: string | null
}

export function parseMemory(value: unknown): MemoryPayload | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const content = typeof value.content === "string" ? value.content : null
  if (!id || content == null) return null

  return {
    id,
    kind: displayValue(value.kind),
    scope: displayValue(value.scope),
    scopeId: displayValue(value.scope_id),
    content,
    published: value.published === true,
    author: displayValue(value.author),
    confidence: numberValue(value.confidence),
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at),
    deletedAt: displayValue(value.deleted_at)
  }
}

export function scopeText(memory: MemoryPayload): string {
  if (memory.scope === "repository") return memory.scopeId ? t("tool_scope_repository_id", { id: memory.scopeId }) : t("tool_scope_repository")
  return memory.scope ?? "—"
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

export function KindBadge({ kind }: { kind: string | null }) {
  if (!kind) return null
  return <Badge>{kind.replace(/_/g, " ")}</Badge>
}

// Publishing only applies to repository-scoped memories (global memories
// can never be published — see AgentMemory::Entry#published_only_for_repository_scope),
// so the pill is omitted entirely for global memories rather than showing a
// misleading "Private".
export function PublishedPill({ memory }: { memory: MemoryPayload }) {
  if (memory.scope !== "repository") return null
  return <StatePill state={memory.published ? "published" : "private"} tone={memory.published ? "success" : "neutral"} />
}

// Wrapped prose (a memory written as a flowing paragraph, no literal "\n")
// can still run to a dozen visual lines even though it is a single line by
// truncateLines' newline-counting rules -- that's the "too much text on
// this card" bug. Approximate the wrapped line count instead of relying on
// literal newlines, so a long single-paragraph memory still collapses.
const CONTENT_PREVIEW_MAX_LINES = 3
const CONTENT_PREVIEW_CHARS_PER_LINE = 80

function estimateVisualLineCount(text: string, charsPerLine: number): number {
  return text.split("\n").reduce((total, line) => total + Math.max(1, Math.ceil(line.length / charsPerLine)), 0)
}

export function ContentPreview({ content }: { content: string }) {
  const [expanded, setExpanded] = useState(false)
  const estimatedLines = estimateVisualLineCount(content, CONTENT_PREVIEW_CHARS_PER_LINE)
  const isLong = estimatedLines > CONTENT_PREVIEW_MAX_LINES

  return (
    <div className="space-y-1">
      <div className={`whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300 ${isLong ? "line-clamp-3" : ""}`}>{content}</div>
      {isLong ? (
        <>
          <button
            className="text-2xs font-semibold uppercase text-brand hover:underline dark:text-brand-emphasis"
            onClick={() => setExpanded(true)}
            type="button"
          >
            {t("tool_show_more")}
          </button>
          {expanded ? <MemoryContentModal content={content} onClose={() => setExpanded(false)} /> : null}
        </>
      ) : null}
    </div>
  )
}

function MemoryContentModal({ content, onClose }: { content: string; onClose: () => void }) {
  const titleId = useId()

  return (
    <Modal
      className="flex max-h-[calc(100vh-2rem)] w-full max-w-2xl flex-col overflow-hidden rounded-lg bg-white shadow-xl dark:bg-gray-900"
      labelledBy={titleId}
      onClose={onClose}
      open
    >
      <div className="flex items-start justify-between gap-4 border-b border-gray-200 p-4 dark:border-gray-800">
        <SectionLabel>
          <span id={titleId}>{t("modal_content")}</span>
        </SectionLabel>
        <button
          aria-label={t("tool_close")}
          className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-white"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto p-4 sm:p-5">
        <Markdown className="chat-prose text-sm text-gray-800 dark:text-gray-100" text={content} />
      </div>
    </Modal>
  )
}

export function MemoryDetailBody({ memory }: { memory: MemoryPayload }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <KindBadge kind={memory.kind} />
        <PublishedPill memory={memory} />
        {memory.deletedAt ? <StatePill state="deleted" tone="failure" /> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("tool_memory_id")} value={memory.id} />
        <Row label={t("tool_scope")} value={scopeText(memory)} />
        {memory.author ? <Row label={t("tool_author")} value={memory.author} /> : null}
        {memory.confidence != null ? <Row label={t("tool_confidence")} value={String(memory.confidence)} /> : null}
        {memory.updatedAt ? <Row label={t("tool_updated")} value={memory.updatedAt} /> : null}
      </dl>
      <div>
        <SectionLabel>{t("tool_content")}</SectionLabel>
        <ContentPreview content={memory.content} />
      </div>
    </CardShell>
  )
}

// Result shape read_memory/write_memory/publish_memory/unpublish_memory all
// share: a single `{ memory: memory_payload }` (write_memory adds a
// top-level `id`, already redundant with memory.id).
export function parseMemoryDetail(context: ToolCardContext): MemoryPayload | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  return parseMemory(parsed.memory)
}

export function TableShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">{children}</div>
}

// list_memories/search_memories shared list rendering: both return
// `{ memories: [memory_payload, ...] }`.
export function memoryRows(context: ToolCardContext): MemoryPayload[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.memories)) return null

  return parsed.memories.flatMap((entry) => {
    const memory = parseMemory(entry)
    return memory ? [memory] : []
  })
}

export function memoryListSummary(context: ToolCardContext): string | null {
  const rows = memoryRows(context)
  if (!rows) return null

  return t("tool_memory_count", { count: rows.length })
}

export function MemoryListBody({ rows, emptyMessage }: { rows: MemoryPayload[]; emptyMessage: string }) {
  if (rows.length === 0) return <EmptyState>{emptyMessage}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_kind")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_scope")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_state")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_content")}</th>
            <th className="px-2 py-1 font-semibold" scope="col">{t("tool_updated")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="whitespace-nowrap px-2 py-1"><KindBadge kind={row.kind} /></td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{scopeText(row)}</td>
              <td className="whitespace-nowrap px-2 py-1"><PublishedPill memory={row} /></td>
              <td className="max-w-[24rem] px-2 py-1 text-gray-700 dark:text-gray-300"><ContentPreview content={row.content} /></td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-500 dark:text-gray-400">{row.updatedAt ?? "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </TableShell>
  )
}

// admin_read_memory_audit_history: `{ memory_id, deleted, audit_events: [...] }`.
export type AuditEvent = {
  key: string
  eventType: string | null
  actorKind: string | null
  actorUserId: string | null
  actorRunId: string | null
  previousContent: string | null
  newContent: string | null
  previousKind: string | null
  newKind: string | null
  previousConfidence: number | null
  newConfidence: number | null
  createdAt: string | null
}

export function parseAuditEvent(value: unknown, index: number): AuditEvent | null {
  if (!isPlainObject(value)) return null

  return {
    key: displayValue(value.id) ?? String(index),
    eventType: displayValue(value.event_type),
    actorKind: displayValue(value.actor_kind),
    actorUserId: displayValue(value.actor_user_id),
    actorRunId: displayValue(value.actor_run_id),
    previousContent: typeof value.previous_content === "string" ? value.previous_content : null,
    newContent: typeof value.new_content === "string" ? value.new_content : null,
    previousKind: displayValue(value.previous_kind),
    newKind: displayValue(value.new_kind),
    previousConfidence: numberValue(value.previous_confidence),
    newConfidence: numberValue(value.new_confidence),
    createdAt: displayValue(value.created_at)
  }
}

export function AuditEventActor({ event }: { event: AuditEvent }) {
  if (!event.actorKind) return <span className="text-gray-400 dark:text-gray-500">—</span>
  const detail = event.actorUserId ? t("tool_actor_user", { id: event.actorUserId }) : event.actorRunId ? t("tool_actor_run", { id: event.actorRunId }) : null
  return <span className="text-gray-600 dark:text-gray-300">{event.actorKind}{detail ? ` (${detail})` : ""}</span>
}

const EVENT_TONE: Record<string, "success" | "warning" | "failure" | "neutral"> = {
  created: "success",
  updated: "warning",
  deleted: "failure"
}

export function AuditEventTypePill({ eventType }: { eventType: string | null }) {
  if (!eventType) return null
  return <StatePill state={eventType} tone={EVENT_TONE[eventType] ?? "neutral"} />
}

export function AuditEventChange({ event }: { event: AuditEvent }) {
  const contentChanged = event.previousContent != null || event.newContent != null
  const kindChanged = event.previousKind !== event.newKind && (event.previousKind != null || event.newKind != null)
  const confidenceChanged = event.previousConfidence !== event.newConfidence && (event.previousConfidence != null || event.newConfidence != null)
  if (!contentChanged && !kindChanged && !confidenceChanged) return null

  return (
    <div className="mt-1 space-y-1">
      {kindChanged ? <div className="text-gray-500 dark:text-gray-400">{t("tool_kind_change", { previous: event.previousKind ?? "—", next: event.newKind ?? "—" })}</div> : null}
      {confidenceChanged ? <div className="text-gray-500 dark:text-gray-400">{t("tool_confidence_change", { previous: event.previousConfidence ?? "—", next: event.newConfidence ?? "—" })}</div> : null}
      {contentChanged ? (
        <Disclosure label={t("tool_content_change")}>
          {event.previousContent != null ? <div className="whitespace-pre-wrap break-words text-red-700 line-through dark:text-red-300">{event.previousContent}</div> : null}
          {event.newContent != null ? <div className="whitespace-pre-wrap break-words text-emerald-700 dark:text-emerald-300">{event.newContent}</div> : null}
        </Disclosure>
      ) : null}
    </div>
  )
}
