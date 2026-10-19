import type { ToolCardContext } from "@app/pluginToolCards"
import { CardShell, EntityReference, Row, SectionLabel, StatePill, displayValue } from "./toolCardUi"
import { MarkdownPreview } from "./toolCardMarkdown"

const PINNED_PREVIEW_LINES = 8
const PINNED_PREVIEW_CHARS = 800

type PinnedContextResult = { kind: "updated"; message: string | null; content: string } | { kind: "removed"; message: string | null }

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function messageValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null
}

export function parsePinnedContextResult(context: ToolCardContext): PinnedContextResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !("pinned_context" in parsed)) return null

  const message = messageValue(parsed.message)
  if (parsed.pinned_context == null) return { kind: "removed", message }
  if (typeof parsed.pinned_context !== "string") return null

  return { kind: "updated", message, content: parsed.pinned_context }
}

export function pinnedContextSummary(context: ToolCardContext) {
  const result = parsePinnedContextResult(context)
  if (!result) return null
  if (context.resultError) return result.message || "Pinned context update failed"
  return result.message || (result.kind === "updated" ? "Pinned context updated" : "Pinned context removed")
}

export function PinnedContextCard({
  result,
  error = false,
  inputContent,
  chatId,
  pinnedContextId
}: {
  result: PinnedContextResult
  error?: boolean
  inputContent?: string | null
  chatId?: string | null
  pinnedContextId?: string | null
}) {
  if (result.kind === "removed") {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={error ? "failed" : "removed"} tone={error ? "failure" : "success"} />
          <span className="font-semibold text-gray-900 dark:text-gray-100">Pinned context</span>
        </div>
        {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
      </CardShell>
    )
  }

  const lineCount = result.content === "" ? 0 : result.content.split("\n").length

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={error ? "failed" : "updated"} tone={error ? "failure" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">Pinned context</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {chatId ? (
          <div className="min-w-0">
            <SectionLabel>Chat</SectionLabel>
            <EntityReference id={chatId} kind="chat" />
          </div>
        ) : null}
        {pinnedContextId ? <Row label="Pinned context" value={pinnedContextId} /> : null}
        <Row label="Lines" value={String(lineCount)} />
        <Row label="Characters" value={String(result.content.length)} />
      </dl>
      {result.message ? (
        <div>
          <SectionLabel>Outcome</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{result.message}</div>
        </div>
      ) : null}
      {inputContent != null && inputContent !== result.content ? (
        <div>
          <SectionLabel>Requested context</SectionLabel>
          <MarkdownPreview
            linkifyUrls
            maxChars={PINNED_PREVIEW_CHARS}
            maxLines={PINNED_PREVIEW_LINES}
            modalLabel="Requested pinned context"
            text={inputContent}
          />
        </div>
      ) : null}
      <div>
        <SectionLabel>Context preview</SectionLabel>
        <MarkdownPreview
          emptyLabel="Pinned context is empty."
          linkifyUrls
          maxChars={PINNED_PREVIEW_CHARS}
          maxLines={PINNED_PREVIEW_LINES}
          modalLabel="Pinned context"
          text={result.content}
        />
      </div>
    </CardShell>
  )
}

export function PendingPinnedContextCard({ content }: { content: string | null }) {
  const value = content ?? ""
  const lineCount = value === "" ? 0 : value.split("\n").length

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="pending" tone="info" />
        <span className="font-semibold text-gray-900 dark:text-gray-100">Pinned context</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Lines" value={String(lineCount)} />
        <Row label="Characters" value={String(value.length)} />
      </dl>
      <div>
        <SectionLabel>Requested context</SectionLabel>
        <MarkdownPreview
          emptyLabel="No pinned context was provided."
          linkifyUrls
          maxChars={PINNED_PREVIEW_CHARS}
          maxLines={PINNED_PREVIEW_LINES}
          modalLabel="Requested pinned context"
          text={value}
        />
      </div>
    </CardShell>
  )
}
export function pinnedContextIdentifiers(parsed: Record<string, unknown>) {
  return {
    chatId: displayValue(parsed.chat_id) || displayValue(parsed.chat_session_id),
    pinnedContextId: displayValue(parsed.pinned_context_id) || displayValue(parsed.id)
  }
}
