import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"
import { Badge, displayValue, SectionLabel } from "../toolCardUi"

const inputFields: PendingActionInputField[] = [{ key: "feedback", label: "Feedback", format: "markdown" }]

function mediaRefs(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const reference = displayValue(item)
    return reference ? [reference] : []
  })
}

function pendingActionHref(context: ToolCardContext, pendingActionId: string) {
  const chatId = context.presentation?.chatId ?? context.chatSessionId
  return chatId ? `/chats/${encodeURIComponent(String(chatId))}#pending-action-${encodeURIComponent(pendingActionId)}` : null
}

function queuedResult(context: ToolCardContext) {
  const parsed = normalizedToolCardParsedResult(context.parsedResult)
  return isPlainObject(parsed) && displayValue(parsed.status) === "queued"
}

function FeedbackMedia({ context, references }: { context: ToolCardContext; references: string[] }) {
  if (references.length === 0) return null

  return (
    <div className="min-w-0">
      <SectionLabel>Media</SectionLabel>
      <div className="mt-1 grid min-w-0 grid-cols-1 gap-2 min-[360px]:grid-cols-2 sm:grid-cols-3">
        {references.map((reference) => (
          <FeedbackMediaItem context={context} key={reference} reference={reference} />
        ))}
      </div>
    </div>
  )
}

function FeedbackMediaItem({ context, reference }: { context: ToolCardContext; reference: string }) {
  const [kind, rawId] = reference.split(":", 2)
  const id = Number(rawId)
  if (!Number.isFinite(id)) return <Badge wrap>{reference}</Badge>

  if (kind === "chat_image") {
    const image = context.presentation?.chatMedia?.chat_images.find((candidate) => candidate.id === id)
    const derivedSrc =
      context.presentation?.chatId != null
        ? `/api/v1/app/chats/${encodeURIComponent(String(context.presentation.chatId))}/media/chat_images/${encodeURIComponent(String(id))}/file`
        : null
    const src = image?.image_url || image?.file_path || derivedSrc
    if (!src) return <Badge wrap>{reference}</Badge>
    const title = image?.title || image?.filename || reference
    return (
      <MediaPreviewShell
        item={{
          title,
          subtitle: image?.content_type || "Chat image",
          src,
          alt: title,
          badge: "image",
          fallbackLabel: "Image preview unavailable",
          actions: [
            { label: "Open image", href: src },
            { label: "Download", href: src, download: true },
            { label: "Copy ID", copyValue: reference }
          ],
          meta: [
            { label: "ID", value: reference, copyValue: reference },
            { label: "Content type", value: image?.content_type }
          ]
        }}
        modalLabel={title}
        thumbnailClassName="min-h-11 w-full"
      />
    )
  }

  if (kind === "snapshot") {
    const snapshot = context.presentation?.chatMedia?.snapshots.find((candidate) => candidate.id === id)
    if (!snapshot) return <Badge wrap>{reference}</Badge>
    const title = snapshot.name || reference
    return (
      <MediaPreviewShell
        item={{
          title,
          subtitle: `${snapshot.element_count} whiteboard element${snapshot.element_count === 1 ? "" : "s"}`,
          badge: "snapshot",
          fallbackLabel: "Whiteboard snapshot",
          actions: [{ label: "Copy ID", copyValue: reference }],
          meta: [
            { label: "ID", value: reference, copyValue: reference },
            { label: "Created", value: snapshot.created_at }
          ]
        }}
        modalLabel={title}
        thumbnailClassName="min-h-11 w-full"
      />
    )
  }

  return <Badge wrap>{reference}</Badge>
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  if (!result) return null

  const input = isPlainObject(context.input) ? context.input : {}
  const media = mediaRefs(input.media)
  const unresolvedResult = result.kind === "standard" || result.kind === "bulk" ? result : null
  const queued = Boolean(unresolvedResult && (unresolvedResult.state === "queued" || queuedResult(context)))
  const linkedResult =
    result.kind === "standard" || result.kind === "bulk"
      ? { ...result, resourceUrl: result.resourceUrl || pendingActionHref(context, result.pendingActionId) }
      : result

  return (
    <PendingActionResultCard
      details={
        <>
          {queued ? (
            <div className="break-words text-text-muted">Queued until the Job becomes actionable; a chat_feedback workflow starts once it is confirmed.</div>
          ) : unresolvedResult && ["pending", "confirming"].includes(unresolvedResult.state) ? (
            <div className="break-words text-text-muted">Confirming this will start a new chat_feedback workflow.</div>
          ) : null}
          <FeedbackMedia context={context} references={media} />
        </>
      }
      input={input}
      inputFields={inputFields}
      result={linkedResult}
    />
  )
}

const submitChatFeedbackToolCard: ToolCardRenderer = {
  toolName: "submit_chat_feedback",
  collapsedSummary,
  renderExpanded
}

export default submitChatFeedbackToolCard
