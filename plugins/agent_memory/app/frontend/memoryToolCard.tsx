import type { ReactNode } from "react"
import i18n from "i18next"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import type { MarkdownLinkHandler } from "@app/lib/Markdown"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, EntityReference, numberValue, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { DataTable } from "@app/components/ui"

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
  expiresAt: string | null
  lastVerifiedAt: string | null
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
    expiresAt: displayValue(value.expires_at),
    lastVerifiedAt: displayValue(value.last_verified_at),
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at),
    deletedAt: displayValue(value.deleted_at)
  }
}

export function scopeText(memory: MemoryPayload): string {
  if (memory.scope === "repository") return memory.scopeId ? t("tool_scope_repository_id", { id: memory.scopeId }) : t("tool_scope_repository")
  return memory.scope ?? "—"
}

export function MemoryRef({ id, label }: { id: string; label?: string }) {
  return <EntityReference href="/memories" id={id} kind="memory" label={label} slug={`MEMORY-${id}`} wrap="nowrap" />
}

export function ScopeRef({ memory }: { memory: MemoryPayload }) {
  if (memory.scope === "repository" && memory.scopeId) {
    return <EntityReference id={memory.scopeId} kind="repository" label={scopeText(memory)} repositoryId={memory.scopeId} wrap="break" />
  }
  return <span className="break-words font-mono text-xs text-text-primary">{scopeText(memory)}</span>
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
  return <StatePill state={t(memory.published ? "tool_status_published" : "tool_status_private")} tone={memory.published ? "success" : "neutral"} />
}

// The shared primitive keeps previews compact by both rendered lines and
// characters, then exposes the complete Markdown in its copyable modal.
const DETAIL_CONTENT_MAX_CHARS = 420
const LIST_CONTENT_MAX_CHARS = 180

export function ContentPreview({
  content,
  linkifySlugs = true,
  linkifyUrls = true,
  maxChars = DETAIL_CONTENT_MAX_CHARS,
  onLinkClick
}: {
  content: string
  linkifySlugs?: boolean
  linkifyUrls?: boolean
  maxChars?: number
  onLinkClick?: MarkdownLinkHandler
}) {
  return (
    <MarkdownPreview
      copyLabel={t("tool_copy_content")}
      emptyLabel={t("tool_empty_content")}
      linkifySlugs={linkifySlugs}
      linkifyUrls={linkifyUrls}
      maxChars={maxChars}
      maxLines={3}
      modalLabel={t("modal_content")}
      onLinkClick={onLinkClick}
      text={content}
    />
  )
}

export function MemoryDetailBody({ memory, shell = true }: { memory: MemoryPayload; shell?: boolean }) {
  const content = (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <KindBadge kind={memory.kind} />
        <PublishedPill memory={memory} />
        {memory.deletedAt ? <StatePill state={t("tool_status_deleted")} tone="failure" /> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <div className="min-w-0">
          <SectionLabel>{t("tool_memory_id")}</SectionLabel>
          <MemoryRef id={memory.id} />
        </div>
        <div className="min-w-0">
          <SectionLabel>{t("tool_scope")}</SectionLabel>
          <ScopeRef memory={memory} />
        </div>
        {memory.author ? <Row label={t("tool_author")} value={memory.author} /> : null}
        {memory.confidence != null ? <Row label={t("tool_confidence")} value={String(memory.confidence)} /> : null}
        {memory.expiresAt ? <Row label={t("tool_expires_at")} value={memory.expiresAt} /> : null}
        {memory.lastVerifiedAt ? <Row label={t("tool_last_verified_at")} value={memory.lastVerifiedAt} /> : null}
        {memory.createdAt ? <Row label={t("tool_created_at")} value={memory.createdAt} /> : null}
        {memory.updatedAt ? <Row label={t("tool_updated")} value={memory.updatedAt} /> : null}
      </dl>
      <div>
        <SectionLabel>{t("tool_content")}</SectionLabel>
        <ContentPreview content={memory.content} />
      </div>
    </>
  )
  return shell ? <CardShell>{content}</CardShell> : content
}

function MemoryListMetadata({ memory }: { memory: MemoryPayload }) {
  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
      {memory.author ? <Row label={t("tool_author")} value={memory.author} /> : null}
      {memory.confidence != null ? <Row label={t("tool_confidence")} value={String(memory.confidence)} /> : null}
      {memory.createdAt ? <Row label={t("tool_created_at")} value={memory.createdAt} /> : null}
      {memory.expiresAt ? <Row label={t("tool_expires_at")} value={memory.expiresAt} /> : null}
      {memory.lastVerifiedAt ? <Row label={t("tool_last_verified_at")} value={memory.lastVerifiedAt} /> : null}
      {memory.deletedAt ? <Row label={t("tool_status_deleted")} value={memory.deletedAt} /> : null}
    </dl>
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

export type MemoryToolError = { message: string; duplicateMemoryId: string | null }

export function parseMemoryToolError(context: ToolCardContext): MemoryToolError | null {
  const parsed = context.parsedResult
  let message: string | null = null

  if (typeof parsed === "string" && (context.resultError || /^Error:/i.test(parsed.trim()))) message = parsed
  if (isPlainObject(parsed) && Array.isArray(parsed.content)) {
    const envelopeText = parsed.content.flatMap((item) => (isPlainObject(item) && item.type === "text" && typeof item.text === "string" ? [item.text] : []))[0]
    if (envelopeText && (context.resultError || /^Error:/i.test(envelopeText.trim()))) message = envelopeText
  }
  if (!message && context.resultError) message = context.resultBody
  const cleaned = message?.trim().replace(/^Error:\s*/i, "") ?? ""
  if (!cleaned) return null

  return { message: cleaned, duplicateMemoryId: cleaned.match(/memory #(\d+)/i)?.[1] ?? null }
}

export function ErrorCard({ error, title = t("tool_error_title") }: { error: MemoryToolError; title?: string }) {
  const duplicate = error.duplicateMemoryId
  const parts = duplicate ? error.message.split(new RegExp(`(memory #${duplicate})`, "i")) : [error.message]

  return (
    <div className="mt-1 rounded-[var(--radius-panel)] border border-danger-border bg-danger-surface p-3 text-sm text-danger-text" role="alert">
      <div className="font-semibold">{title}</div>
      <div className="mt-1 break-words">
        {parts.map((part, index) =>
          part.toLowerCase() === `memory #${duplicate}` ? <MemoryRef id={duplicate!} key={`${part}-${index}`} label={part} /> : part
        )}
      </div>
    </div>
  )
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
    <div className="mt-1 min-w-0 rounded border border-border">
      <div className="divide-y divide-border sm:hidden">
        {rows.map((row) => (
          <article className="min-w-0 space-y-3 p-3" key={row.id}>
            <div className="flex min-w-0 flex-wrap items-center justify-between gap-2">
              <MemoryRef id={row.id} />
              <div className="flex flex-wrap items-center gap-2">
                <KindBadge kind={row.kind} />
                <PublishedPill memory={row} />
                {row.deletedAt ? <StatePill state={t("tool_status_deleted")} tone="failure" /> : null}
              </div>
            </div>
            <dl className="grid min-w-0 gap-2">
              <div className="min-w-0">
                <SectionLabel>{t("tool_scope")}</SectionLabel>
                <ScopeRef memory={row} />
              </div>
              <div className="min-w-0">
                <SectionLabel>{t("tool_updated")}</SectionLabel>
                <div className="break-words font-mono text-xs text-text-muted [overflow-wrap:anywhere]">{row.updatedAt ?? "—"}</div>
              </div>
            </dl>
            <div className="min-w-0">
              <SectionLabel>{t("tool_content")}</SectionLabel>
              <ContentPreview content={row.content} maxChars={LIST_CONTENT_MAX_CHARS} />
            </div>
            <MemoryListMetadata memory={row} />
          </article>
        ))}
      </div>
      <DataTable.Root className="table-fixed text-left text-xs" density="compact" wrapperClassName="hidden overflow-x-hidden rounded-none border-0 sm:block">
        <DataTable.Header className="bg-surface-raised text-2xs uppercase text-text-muted">
          <DataTable.Row>
            <DataTable.HeadCell className="w-[14%] px-2 py-2 font-semibold">{t("tool_memory_id")}</DataTable.HeadCell>
            <DataTable.HeadCell className="w-[13%] px-2 py-2 font-semibold">{t("tool_kind")}</DataTable.HeadCell>
            <DataTable.HeadCell className="w-[18%] px-2 py-2 font-semibold">{t("tool_scope")}</DataTable.HeadCell>
            <DataTable.HeadCell className="w-[13%] px-2 py-2 font-semibold">{t("tool_state")}</DataTable.HeadCell>
            <DataTable.HeadCell className="w-[27%] px-2 py-2 font-semibold">{t("tool_content")}</DataTable.HeadCell>
            <DataTable.HeadCell className="w-[15%] px-2 py-2 font-semibold">{t("tool_updated")}</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {rows.map((row) => (
            <DataTable.Row key={row.id}>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <MemoryRef id={row.id} />
              </DataTable.Cell>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <KindBadge kind={row.kind} />
              </DataTable.Cell>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <ScopeRef memory={row} />
              </DataTable.Cell>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <PublishedPill memory={row} />
                {row.deletedAt ? <StatePill state={t("tool_status_deleted")} tone="failure" /> : null}
              </DataTable.Cell>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <div className="min-w-0 text-text-secondary">
                  <ContentPreview content={row.content} maxChars={LIST_CONTENT_MAX_CHARS} />
                </div>
                <div className="mt-2 min-w-0">
                  <MemoryListMetadata memory={row} />
                </div>
              </DataTable.Cell>
              <DataTable.Cell className="min-w-0 px-2 py-2 align-top">
                <div className="min-w-0 break-words font-mono text-text-muted [overflow-wrap:anywhere]">{row.updatedAt ?? "—"}</div>
              </DataTable.Cell>
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </div>
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
  if (!event.actorKind) return <span className="text-text-subtle">—</span>
  const detail = event.actorUserId ? t("tool_actor_user", { id: event.actorUserId }) : event.actorRunId ? t("tool_actor_run", { id: event.actorRunId }) : null
  return (
    <span className="text-text-secondary">
      {event.actorKind}
      {detail ? ` (${detail})` : ""}
    </span>
  )
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
      {kindChanged ? <div className="text-text-muted">{t("tool_kind_change", { previous: event.previousKind ?? "—", next: event.newKind ?? "—" })}</div> : null}
      {confidenceChanged ? (
        <div className="text-text-muted">{t("tool_confidence_change", { previous: event.previousConfidence ?? "—", next: event.newConfidence ?? "—" })}</div>
      ) : null}
      {contentChanged ? (
        <Disclosure label={t("tool_content_change")}>
          {event.previousContent != null ? <div className="whitespace-pre-wrap break-words text-danger-text line-through">{event.previousContent}</div> : null}
          {event.newContent != null ? <div className="whitespace-pre-wrap break-words text-success-text">{event.newContent}</div> : null}
        </Disclosure>
      ) : null}
    </div>
  )
}
