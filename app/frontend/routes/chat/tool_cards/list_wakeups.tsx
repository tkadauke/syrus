import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { intlLocale, formatRelativeDate } from "../../../lib/relativeTime"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, displayValue, EmptyState, EntityReference, numberValue, StatePill } from "../toolCardUi"

type WakeupRow = { id: string; fireAt: string; delayRemainingMinutes: number | null; prompt: string; state: string | null; chatId: string | null }

function parseWakeupRow(value: unknown): WakeupRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const fireAt = displayValue(value.fire_at)
  if (!id || !fireAt) return null
  return {
    id,
    fireAt,
    delayRemainingMinutes: numberValue(value.delay_remaining_minutes),
    prompt: displayValue(value.prompt) ?? displayValue(value.prompt_preview) ?? "",
    state: displayValue(value.state) ?? displayValue(value.status),
    chatId: displayValue(value.chat_id)
  }
}

function wakeupRows(context: ToolCardContext): WakeupRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.wakeups)) return null
  return parsed.wakeups.flatMap((item) => {
    const row = parseWakeupRow(item)
    return row ? [row] : []
  })
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) {
    return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message) ?? "Unable to load wakeups."
  }
  return displayValue(context.resultBody) ?? "Unable to load wakeups."
}

function collapsedSummary(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return error
  const rows = wakeupRows(context)
  if (!rows) return null
  return `${rows.length} wakeup${rows.length === 1 ? "" : "s"}`
}

function WakeupTime({ value }: { value: string }) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>{value}</>
  const local = new Intl.DateTimeFormat(intlLocale(), { dateStyle: "medium", timeStyle: "short" }).format(date)
  return (
    <time className="flex flex-col" dateTime={value} title={value}>
      <span>{local}</span>
      <span className="text-2xs text-text-subtle">{formatRelativeDate(date)}</span>
    </time>
  )
}

function renderExpanded(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return <EmptyState>{error}</EmptyState>
  const rows = wakeupRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>No pending wakeups in this chat.</EmptyState>

  return (
    <div className="mt-1 min-w-0 max-w-full overflow-hidden rounded border border-border">
      <table className="block w-full table-fixed text-left text-xs md:table">
        <thead className="hidden bg-surface-raised text-2xs uppercase text-text-muted md:table-header-group">
          <tr>
            <th className="w-28 px-2 py-1 font-semibold" scope="col">
              Wakeup
            </th>
            <th className="w-44 px-2 py-1 font-semibold" scope="col">
              Fires at
            </th>
            <th className="w-24 px-2 py-1 font-semibold" scope="col">
              Remaining
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Prompt
            </th>
          </tr>
        </thead>
        <tbody className="block divide-y divide-border bg-surface md:table-row-group">
          {rows.map((row) => (
            <tr className="grid min-w-0 grid-cols-1 gap-2 p-3 md:table-row md:p-0" key={row.id}>
              <td className="min-w-0 md:px-2 md:py-2">
                <div className="flex min-w-0 flex-wrap items-center gap-1">
                  <EntityReference chatId={row.chatId} id={row.id} kind="wakeup" />
                  {row.state ? <StatePill state={row.state} /> : null}
                  {row.chatId ? <EntityReference id={row.chatId} kind="chat" /> : null}
                </div>
              </td>
              <td className="min-w-0 break-words text-text-muted md:px-2 md:py-2">
                <WakeupTime value={row.fireAt} />
              </td>
              <td className="min-w-0 text-text-muted md:px-2 md:py-2">
                {row.delayRemainingMinutes != null ? <Badge>{row.delayRemainingMinutes} min</Badge> : "—"}
              </td>
              <td className="min-w-0 max-w-full text-text-muted md:px-2 md:py-2">
                <MarkdownPreview
                  emptyState={<span>—</span>}
                  linkifySlugs
                  linkifyUrls
                  maxChars={320}
                  maxLines={3}
                  modalLabel={`Wakeup ${row.id} prompt`}
                  text={row.prompt}
                />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const listWakeupsToolCard: ToolCardRenderer = { toolName: "list_wakeups", collapsedSummary, renderExpanded }
export default listWakeupsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "pending_wakeups",
    label: "Pending wakeups",
    description: "Full prompts, local and relative fire times, status, chat references, and wrapping rows.",
    sourceType: "claude",
    parsedResult: {
      wakeups: [
        {
          id: 7,
          chat_id: 42,
          fire_at: "2026-10-20T09:30:00Z",
          delay_remaining_minutes: 45,
          state: "pending",
          prompt: "Check **deployment status** for JOB-322 and review https://example.test/details."
        },
        {
          id: 8,
          chat_id: 42,
          fire_at: "2026-10-21T14:00:00Z",
          delay_remaining_minutes: 1755,
          state: "pending",
          prompt: "Summarize the overnight results and call out anything requiring operator attention. ".repeat(8)
        }
      ]
    }
  },
  { id: "empty", label: "No pending wakeups", sourceType: "codex", parsedResult: { wakeups: [] } },
  { id: "error", label: "Provider error", resultError: true, resultBody: JSON.stringify({ error: "Wakeups are temporarily unavailable." }) }
]
