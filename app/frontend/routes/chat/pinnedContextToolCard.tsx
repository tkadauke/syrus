import type { ToolCardContext } from "@app/pluginToolCards"
import { CardShell, EntityReference, Row, SectionLabel, StatePill, displayValue } from "./toolCardUi"
import { MarkdownPreview } from "./toolCardMarkdown"
import i18n from "../../i18n"

const PINNED_PREVIEW_LINES = 8
const PINNED_PREVIEW_CHARS = 800

type PinnedContextResult = { kind: "updated"; message: string | null; content: string } | { kind: "removed"; message: string | null; content: string | null }

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
  if (parsed.pinned_context == null) {
    const removedContent = parsed.removed_pinned_context
    if (removedContent != null && typeof removedContent !== "string") return null
    return { kind: "removed", message, content: removedContent ?? null }
  }
  if (typeof parsed.pinned_context !== "string") return null

  return { kind: "updated", message, content: parsed.pinned_context }
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
          <span className="font-semibold text-gray-900 dark:text-gray-100">{i18n.t("chat:pinned_context")}</span>
        </div>
        {chatId ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:tool_card_chat")}</SectionLabel>
            <EntityReference id={chatId} kind="chat" />
          </div>
        ) : null}
        {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
        {result.content != null ? (
          <div>
            <SectionLabel>{i18n.t("chat:removed_context")}</SectionLabel>
            <MarkdownPreview
              emptyLabel={i18n.t("chat:removed_pinned_context_empty")}
              linkifyUrls
              maxChars={PINNED_PREVIEW_CHARS}
              maxLines={PINNED_PREVIEW_LINES}
              modalLabel={i18n.t("chat:removed_pinned_context")}
              text={result.content}
            />
          </div>
        ) : null}
      </CardShell>
    )
  }

  const lineCount = result.content === "" ? 0 : result.content.split("\n").length

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={error ? "failed" : "updated"} tone={error ? "failure" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{i18n.t("chat:pinned_context")}</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {chatId ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:tool_card_chat")}</SectionLabel>
            <EntityReference id={chatId} kind="chat" />
          </div>
        ) : null}
        {pinnedContextId ? <Row label={i18n.t("chat:pinned_context")} value={pinnedContextId} /> : null}
        <Row label={i18n.t("chat:lines")} value={String(lineCount)} />
        <Row label={i18n.t("chat:characters")} value={String(result.content.length)} />
      </dl>
      {result.message ? (
        <div>
          <SectionLabel>{i18n.t("chat:outcome")}</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{result.message}</div>
        </div>
      ) : null}
      {inputContent != null && inputContent !== result.content ? (
        <div>
          <SectionLabel>{i18n.t("chat:requested_context")}</SectionLabel>
          <MarkdownPreview
            linkifyUrls
            maxChars={PINNED_PREVIEW_CHARS}
            maxLines={PINNED_PREVIEW_LINES}
            modalLabel={i18n.t("chat:requested_pinned_context")}
            text={inputContent}
          />
        </div>
      ) : null}
      <div>
        <SectionLabel>{i18n.t("chat:context_preview")}</SectionLabel>
        <MarkdownPreview
          emptyLabel={i18n.t("chat:pinned_context_empty")}
          linkifyUrls
          maxChars={PINNED_PREVIEW_CHARS}
          maxLines={PINNED_PREVIEW_LINES}
          modalLabel={i18n.t("chat:pinned_context")}
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
        <span className="font-semibold text-gray-900 dark:text-gray-100">{i18n.t("chat:pinned_context")}</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={i18n.t("chat:lines")} value={String(lineCount)} />
        <Row label={i18n.t("chat:characters")} value={String(value.length)} />
      </dl>
      <div>
        <SectionLabel>{i18n.t("chat:requested_context")}</SectionLabel>
        <MarkdownPreview
          emptyLabel={i18n.t("chat:no_pinned_context")}
          linkifyUrls
          maxChars={PINNED_PREVIEW_CHARS}
          maxLines={PINNED_PREVIEW_LINES}
          modalLabel={i18n.t("chat:requested_pinned_context")}
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
