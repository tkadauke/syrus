import type { ChatMessageItem } from "../api/chats"
import type { BugReportOptionalAttachment } from "./bugReportOptionalAttachments"
import type { TFunction } from "i18next"

export function visibleTranscriptMessages(messages: ChatMessageItem[]) {
  return messages.filter((m) => (m.role === "user" || m.role === "assistant") && m.text.trim().length > 0)
}

export function serializeTranscript(messages: ChatMessageItem[], t: TFunction): string {
  return visibleTranscriptMessages(messages)
    .map((m) => `[${t(m.role === "user" ? "transcript_role_user" : "transcript_role_assistant")}]\n${m.text}`)
    .join("\n\n")
}

export function chatTranscriptBugReportAttachment(messages: ChatMessageItem[], t: TFunction): BugReportOptionalAttachment | null {
  const visibleMessages = visibleTranscriptMessages(messages)
  if (visibleMessages.length === 0) return null

  return {
    id: "chat-transcript",
    label: t("include_chat_transcript"),
    preview: visibleMessages.map((m) => `[${t(m.role === "user" ? "transcript_role_user" : "transcript_role_assistant")}] ${m.text}`).join("\n\n"),
    defaultChecked: false,
    buildFile: () => {
      const text = serializeTranscript(messages, t)
      if (text.trim().length === 0) return null
      return new File([text], "chat-transcript.txt", { type: "text/plain" })
    }
  }
}
