import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { MemoryRef, parseMemoryToolError } from "../memoryToolCard"

type DeleteMemoryResult = { id: string; deleted: boolean }

function parseResult(context: ToolCardContext): DeleteMemoryResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const id = displayValue(parsed.id)
  if (!id || typeof parsed.deleted !== "boolean") return null

  return { id, deleted: parsed.deleted }
}

function isPending(context: ToolCardContext) {
  return !context.resultError && context.parsedResult == null && !context.resultBody.trim()
}

function isEmpty(context: ToolCardContext) {
  return !context.resultError && isPlainObject(context.parsedResult) && !parseResult(context)
}

function errorMemoryId(message: string) {
  return message.match(/memory #(\d+)/i)?.[1] ?? message.match(/not accessible:\s*(\d+)/i)?.[1] ?? null
}

function RequestedMemory({ id }: { id: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{t("tool_input_memory_id")}</SectionLabel>
      <MemoryRef id={id} />
    </div>
  )
}

function ErrorCard({ inputId, message }: { inputId: string | null; message: string }) {
  const id = errorMemoryId(message)
  const parts = id ? message.split(new RegExp(`(memory #${id}|${id}(?=\\s*$))`, "i")) : [message]

  return (
    <CardShell>
      {inputId ? <RequestedMemory id={inputId} /> : null}
      <div className="rounded-[var(--radius-panel)] border border-danger-border bg-danger-surface p-3 text-sm text-danger-text" role="alert">
        <div className="font-semibold">{t("tool_delete_error_title")}</div>
        <div className="mt-1 break-words [overflow-wrap:anywhere]">
          {parts.map((part, index) =>
            id && (part.toLowerCase() === `memory #${id}` || part === id) ? <MemoryRef id={id} key={`${part}-${index}`} label={part} /> : part
          )}
        </div>
      </div>
    </CardShell>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const error = parseMemoryToolError(context)
  if (error) return t("tool_delete_failed", { message: error.message })

  const result = parseResult(context)
  if (result) return t(result.deleted ? "tool_delete_summary" : "tool_delete_not_deleted_summary", { id: result.id })
  if (isPending(context)) return t("tool_delete_pending")
  if (isEmpty(context)) return t("tool_delete_empty")
  return null
}

function renderExpanded(context: ToolCardContext) {
  const inputId = displayValue(context.input?.id)
  const error = parseMemoryToolError(context)
  if (error) return <ErrorCard inputId={inputId} message={error.message} />

  const result = parseResult(context)
  if (!result) {
    const message = isPending(context) ? t("tool_delete_pending") : isEmpty(context) ? t("tool_delete_empty") : null
    if (message) {
      return (
        <CardShell>
          {inputId ? <RequestedMemory id={inputId} /> : null}
          <EmptyState>{message}</EmptyState>
        </CardShell>
      )
    }
    return null
  }

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={t(result.deleted ? "tool_status_deleted" : "tool_status_not_deleted")} tone={result.deleted ? "failure" : "neutral"} />
      </div>
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {inputId ? <RequestedMemory id={inputId} /> : null}
        <div className="min-w-0">
          <SectionLabel>{t("tool_memory_id")}</SectionLabel>
          <MemoryRef id={result.id} />
        </div>
      </dl>
    </CardShell>
  )
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`agent_memory:${key}`, options)
}

const deleteMemoryToolCard: ToolCardRenderer = {
  toolName: "delete_memory",
  collapsedSummary,
  renderExpanded
}

export default deleteMemoryToolCard

export const examples: ToolCardExample[] = [
  { id: "deleted", label: "Memory deleted", input: { id: 55 }, parsedResult: { id: 55, deleted: true } },
  {
    id: "inaccessible",
    label: "Memory inaccessible",
    input: { id: 91 },
    resultBody: "Error: memory not found or not accessible: 91",
    resultError: true
  },
  { id: "pending", label: "Pending deletion", input: { id: 55 } },
  { id: "empty", label: "Empty result", input: { id: 55 }, parsedResult: {} }
]
