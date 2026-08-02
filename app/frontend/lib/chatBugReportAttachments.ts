import type { ChatMessageItem } from "../api/chats"
import type { BugReportOptionalAttachment } from "./bugReportOptionalAttachments"

export function visibleTranscriptMessages(messages: ChatMessageItem[]) {
  return messages.filter((m) => (m.role === "user" || m.role === "assistant") && m.text.trim().length > 0)
}

export function serializeTranscript(messages: ChatMessageItem[]): string {
  return visibleTranscriptMessages(messages)
    .map((m) => `[${m.role === "user" ? "User" : "Assistant"}]\n${m.text}`)
    .join("\n\n")
}

export function chatTranscriptBugReportAttachment(messages: ChatMessageItem[]): BugReportOptionalAttachment | null {
  const visibleMessages = visibleTranscriptMessages(messages)
  if (visibleMessages.length === 0) return null

  return {
    id: "chat-transcript",
    label: "Include chat transcript",
    preview: visibleMessages.map((m) => `[${m.role === "user" ? "User" : "Assistant"}] ${m.text}`).join("\n\n"),
    defaultChecked: false,
    buildFile: () => {
      const text = serializeTranscript(messages)
      if (text.trim().length === 0) return null
      return new File([text], "chat-transcript.txt", { type: "text/plain" })
    }
  }
}
