import type { ChatMessageAttachmentInput } from "../../api/chats"
import type { Shape } from "../../components/ImageAnnotationModal"
import type { SlashCommand } from "../../lib/slashCommands"

// Compose-related types extracted from Chat.tsx so the composer (chat/Compose.tsx)
// and the route file can share them without a circular import. ChatSystemCommandHandlers
// is used on both sides (ChatColumn passes it down); the rest are composer-internal
// but live here to keep the compose type surface in one place.

export type WalkthroughDraft = {
  // Monotonic client-side identity: state updates from an upload are keyed to
  // the draft that started them, so a late resolution can't corrupt a draft
  // the user has since replaced.
  key: number
  file: File
  filename: string
  durationSeconds: number | null
  status: "ready" | "uploading" | "analyzing" | "failed"
  percent: number
  id?: number
  error?: string
}

export type PendingSlashCommandConfirmation = {
  commandName: SlashCommand["name"]
  text: string
}

export type ChatSystemCommandHandlers = {
  openBookmarks: () => void
  openAttachments: () => void
  openSettings: () => void
}

export type ChatSystemAction =
  | { kind: "rename"; title: string }
  | { kind: "clear" }
  | { kind: "new" }
  | { kind: "branch" }
  | { kind: "share" }
  | { kind: "attach"; slug: string }
  | { kind: "pin"; pinned: boolean }

export type ChatSystemCommandAction =
  | { kind: "bookmark"; label: string }
  | { kind: "discard"; path: string }
  | { kind: "job"; action: "cancel" | "retry"; jobId: string }
  | { kind: "clear-canvas" }

export type ChatComposeAttachment = ChatMessageAttachmentInput & {
  size: number
  shapes?: Shape[]
  originalDataUrl?: string
}
