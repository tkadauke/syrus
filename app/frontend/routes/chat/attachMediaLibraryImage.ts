import { getDraftAttachments, readAttachmentFile, setDraftAttachments } from "./attachmentDraftStore"
import { type AttachMediaToComposerDetail, CHAT_ATTACHMENT_MAX_BYTES, CHAT_ATTACHMENT_TOTAL_MAX_BYTES, CHAT_DRAFT_ATTACHMENTS_CHANGED_EVENT } from "./constants"

export type AttachMediaLibraryImageResult = { ok: true } | { ok: false; reason: "fetch_failed" | "too_large" }

// Fetches an already-hosted media-library image (from the gallery or its
// lightbox, see WorkspacePanels.tsx) and merges it into the target chat's
// attachment draft directly through attachmentDraftStore.ts, independent of
// whether that chat's Compose is currently mounted -- see
// CHAT_DRAFT_ATTACHMENTS_CHANGED_EVENT in constants.ts for why that
// independence matters. Callers await the result to report success/failure
// (e.g. via onNotice) instead of assuming the fetch already succeeded.
export async function attachMediaLibraryImage(detail: AttachMediaToComposerDetail): Promise<AttachMediaLibraryImageResult> {
  let file: File
  try {
    const response = await fetch(detail.url)
    if (!response.ok) throw new Error(`Request failed with status ${response.status}`)
    const blob = await response.blob()
    file = new File([blob], detail.name, { type: blob.type || detail.mimeType })
  } catch (_error) {
    return { ok: false, reason: "fetch_failed" }
  }

  const current = getDraftAttachments(detail.chatId)
  const totalBytes = current.reduce((sum, attachment) => sum + attachment.size, 0) + file.size
  if (file.size > CHAT_ATTACHMENT_MAX_BYTES || totalBytes > CHAT_ATTACHMENT_TOTAL_MAX_BYTES) {
    return { ok: false, reason: "too_large" }
  }

  const attachment = await readAttachmentFile(file)
  setDraftAttachments(detail.chatId, [...current, attachment])
  window.dispatchEvent(new CustomEvent(CHAT_DRAFT_ATTACHMENTS_CHANGED_EVENT, { detail: { chatId: detail.chatId } }))
  return { ok: true }
}
