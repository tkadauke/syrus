import { describe, expect, it } from "vitest"
import { mergeMessageTail } from "./messageStreamItems"
import type { ChatMessageItem } from "../../api/chats"

function message(id: number): ChatMessageItem {
  return {
    type: "message",
    id,
    role: "user",
    tool_name: null,
    content: { text: `message ${id}` },
    text: `message ${id}`,
    bookmarkable: true
  } as unknown as ChatMessageItem
}

describe("mergeMessageTail", () => {
  it("preserves earlier messages that fall before the new tail's oldest id", () => {
    const current = [message(1), message(2), message(9)]
    const next = [message(9), message(10)]

    expect(mergeMessageTail(current, next).map((item) => item.id)).toEqual([1, 2, 9, 10])
  })

  it("returns the new tail unchanged when it is empty", () => {
    const current = [message(1), message(2)]

    expect(mergeMessageTail(current, [])).toEqual([])
  })

  it("drops stale current entries that the new tail supersedes", () => {
    const current = [message(1), message(5)]
    const next = [message(5), message(6)]

    expect(mergeMessageTail(current, next).map((item) => item.id)).toEqual([1, 5, 6])
  })
})
