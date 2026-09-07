import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, SectionLabel, StatePill, truncateLines } from "@app/routes/chat/toolCardUi"

// Shared presentation helpers for the agent_memory plugin's chat tool cards
// (EPIC-293 / JOB-4226). list_memories, search_memories, read_memory,
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
  if (memory.scope === "repository") return `repository${memory.scopeId ? ` #${memory.scopeId}` : ""}`
  return memory.scope ?? "—"
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

export function ContentPreview({ content, maxLines = 4 }: { content: string; maxLines?: number }) {
  const { preview, truncated, totalLines } = truncateLines(content, maxLines)
  return (
    <div className="space-y-1">
      <div className="whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{preview}</div>
      {truncated ? (
        <Disclosure label={`Show full content (${totalLines} lines)`}>
          <div className="whitespace-pre-wrap break-words">{content}</div>
        </Disclosure>
      ) : null}
    </div>
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
        <Row label="Memory ID" value={memory.id} />
        <Row label="Scope" value={scopeText(memory)} />
        {memory.author ? <Row label="Author" value={memory.author} /> : null}
        {memory.confidence != null ? <Row label="Confidence" value={String(memory.confidence)} /> : null}
        {memory.updatedAt ? <Row label="Updated" value={memory.updatedAt} /> : null}
      </dl>
      <div>
        <SectionLabel>Content</SectionLabel>
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

  return `${rows.length} memor${rows.length === 1 ? "y" : "ies"}`
}

export function MemoryListBody({ rows, emptyMessage }: { rows: MemoryPayload[]; emptyMessage: string }) {
  if (rows.length === 0) return <EmptyState>{emptyMessage}</EmptyState>

  return (
    <TableShell>
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Kind</th>
            <th className="px-2 py-1 font-semibold" scope="col">Scope</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Content</th>
            <th className="px-2 py-1 font-semibold" scope="col">Updated</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="whitespace-nowrap px-2 py-1"><KindBadge kind={row.kind} /></td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{scopeText(row)}</td>
              <td className="whitespace-nowrap px-2 py-1"><PublishedPill memory={row} /></td>
              <td className="max-w-[24rem] px-2 py-1 text-gray-700 dark:text-gray-300"><ContentPreview content={row.content} maxLines={2} /></td>
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
  const detail = event.actorUserId ? `user #${event.actorUserId}` : event.actorRunId ? `run #${event.actorRunId}` : null
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
      {kindChanged ? <div className="text-gray-500 dark:text-gray-400">kind: {event.previousKind ?? "—"} → {event.newKind ?? "—"}</div> : null}
      {confidenceChanged ? <div className="text-gray-500 dark:text-gray-400">confidence: {event.previousConfidence ?? "—"} → {event.newConfidence ?? "—"}</div> : null}
      {contentChanged ? (
        <Disclosure label="Content change">
          {event.previousContent != null ? <div className="whitespace-pre-wrap break-words text-red-700 line-through dark:text-red-300">{event.previousContent}</div> : null}
          {event.newContent != null ? <div className="whitespace-pre-wrap break-words text-emerald-700 dark:text-emerald-300">{event.newContent}</div> : null}
        </Disclosure>
      ) : null}
    </div>
  )
}
