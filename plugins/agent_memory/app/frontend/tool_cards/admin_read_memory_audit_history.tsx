import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { AuditEventActor, AuditEventChange, AuditEventTypePill, parseAuditEvent, type AuditEvent } from "../memoryToolCard"

// Plugin-owned tool card for admin_read_memory_audit_history (the tool-card work).
type AuditHistoryCard = {
  memoryId: string
  deleted: boolean
  events: AuditEvent[]
}

function parseCard(context: ToolCardContext): AuditHistoryCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const memoryId = displayValue(parsed.memory_id)
  if (!memoryId) return null

  const events = Array.isArray(parsed.audit_events)
    ? parsed.audit_events.flatMap((entry, index) => {
        const event = parseAuditEvent(entry, index)
        return event ? [event] : []
      })
    : []

  return { memoryId, deleted: parsed.deleted === true, events }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return `${card.events.length} audit event${card.events.length === 1 ? "" : "s"} for memory #${card.memoryId}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Row label="Memory ID" value={card.memoryId} />
        {card.deleted ? <StatePill state="deleted" tone="failure" /> : null}
      </div>
      {card.events.length === 0 ? (
        <EmptyState>No audit events recorded.</EmptyState>
      ) : (
        <div>
          <SectionLabel>Audit trail (oldest first)</SectionLabel>
          <ul className="mt-1 space-y-2 rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
            {card.events.map((event) => (
              <li className="border-b border-gray-100 pb-2 last:border-0 last:pb-0 dark:border-gray-800" key={event.key}>
                <div className="flex flex-wrap items-center gap-2">
                  <AuditEventTypePill eventType={event.eventType} />
                  <AuditEventActor event={event} />
                  {event.createdAt ? <span className="text-gray-400 dark:text-gray-500">{event.createdAt}</span> : null}
                </div>
                <AuditEventChange event={event} />
              </li>
            ))}
          </ul>
        </div>
      )}
    </CardShell>
  )
}

const adminReadMemoryAuditHistoryToolCard: ToolCardRenderer = {
  toolName: "admin_read_memory_audit_history",
  collapsedSummary,
  renderExpanded
}

export default adminReadMemoryAuditHistoryToolCard
