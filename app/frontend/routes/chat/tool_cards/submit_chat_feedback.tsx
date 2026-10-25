import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard, type PendingActionInputField } from "../pendingActionToolCard"
import { Badge, displayValue, SectionLabel } from "../toolCardUi"
import i18n from "@app/i18n"
import { safeMediaUrl } from "./list_chat_media"

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
      <SectionLabel>{i18n.t("chat:tool_card_media")}</SectionLabel>
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
    const src = safeMediaUrl(image?.image_url || image?.file_path || derivedSrc || "")
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
  if (!result) return null
  if ((result.kind === "standard" || result.kind === "bulk") && !result.message) {
    const queued = result.state === "queued" || queuedResult(context)
    return i18n.t(
      queued
        ? result.jobId
          ? "chat:mutation_chat_feedback_queued_job"
          : "chat:mutation_chat_feedback_queued"
        : result.jobId
          ? "chat:mutation_chat_feedback_pending_job"
          : "chat:mutation_chat_feedback_pending",
      { job: result.jobId ? `JOB-${result.jobId}` : "" }
    )
  }
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
            <div className="break-words text-text-muted">{i18n.t("chat:mutation_feedback_queued_explanation")}</div>
          ) : unresolvedResult && ["pending", "confirming"].includes(unresolvedResult.state) ? (
            <div className="break-words text-text-muted">{i18n.t("chat:mutation_feedback_confirmation_explanation")}</div>
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

const thumbnail =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 320 180'%3E%3Crect width='320' height='180' fill='%23f1f5f9'/%3E%3Crect x='32' y='28' width='256' height='30' rx='6' fill='%23b6492e'/%3E%3Crect x='32' y='76' width='180' height='12' rx='6' fill='%2394a3b8'/%3E%3Crect x='32' y='100' width='220' height='12' rx='6' fill='%23cbd5e1'/%3E%3C/svg%3E"

export const examples: ToolCardExample[] = [
  {
    id: "pending_with_feedback_and_media",
    label: "Pending feedback with media",
    description: "Long Markdown feedback and message, linked references, image thumbnail, snapshot preview, and unresolved-media fallback.",
    input: {
      job_id: 4048,
      feedback:
        "Please tighten the **mobile header** and keep the primary action visible.\n\n- Preserve keyboard focus\n- Check the narrow layout\n\n" +
        "The attached image and whiteboard snapshot show the intended hierarchy. ".repeat(10),
      media: ["chat_image:7", "snapshot:42", "artifact:unresolved-reference"]
    },
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      message:
        "Submit this **review feedback** after checking the linked Job and attachments. " +
        "Confirming creates a dedicated follow-up workflow for the requested revision. ".repeat(10)
    },
    presentation: {
      chatId: 12,
      chatMedia: {
        snapshots: [{ id: 42, name: "Header hierarchy", snapshot_kind: "manual", element_count: 6, created_at: "2026-10-20T12:00:00Z" }],
        chat_images: [{ id: 7, title: "Mobile header", filename: "mobile-header.svg", content_type: "image/svg+xml", image_url: thumbnail }],
        typed_artifacts: [],
        whiteboard_has_unsaved_content: false
      }
    },
    sourceType: "generic"
  },
  {
    id: "queued_feedback",
    label: "Queued feedback",
    description: "Feedback waiting for the current Job work to become actionable.",
    input: { job_id: 4048, feedback: "Recheck the **responsive spacing** before the next implementation pass." },
    parsedResult: {
      pending_action_id: 502,
      state: "queued",
      status: "queued",
      message: "Feedback is queued until the Job finishes its current run."
    },
    presentation: { chatId: 12 },
    sourceType: "codex"
  },
  {
    id: "feedback_error",
    label: "Feedback error",
    description: "Failure state retaining the requested Job, Markdown feedback, and unresolved media reference.",
    input: { job_id: 9999, feedback: "Apply the **header revision** shown in the attachment.", media: ["snapshot:404"] },
    resultBody: "Error: Job not found",
    resultError: true,
    sourceType: "claude"
  }
]

export default submitChatFeedbackToolCard
