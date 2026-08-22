import { describe, expect, it } from "vitest"
import type { ChatMessageItem } from "../../api/chats"
import { retryTextByMessageId } from "./messageDisplay"

function message(overrides: Partial<ChatMessageItem> & { id: number; role: ChatMessageItem["role"] }): ChatMessageItem {
  return {
    type: "message",
    text: "",
    bookmarkable: false,
    ...overrides
  }
}

describe("retryTextByMessageId", () => {
  it("maps an error system message to the text of the preceding user message", () => {
    const messages = [
      message({ id: 1, role: "user", text: "does syrus update itself?" }),
      message({ id: 2, role: "system", text: "Claude authentication failed." })
    ]

    expect(retryTextByMessageId(messages)).toEqual(new Map([ [ 2, "does syrus update itself?" ] ]))
  })

  it("maps every system message following a user message to that same user text", () => {
    const messages = [
      message({ id: 1, role: "user", text: "hello" }),
      message({ id: 2, role: "system", text: "Claude authentication failed." }),
      message({ id: 3, role: "system", text: "Agent run failed" })
    ]

    expect(retryTextByMessageId(messages)).toEqual(new Map([
      [ 2, "hello" ],
      [ 3, "hello" ]
    ]))
  })

  it("re-anchors to the newer user message once one is sent", () => {
    const messages = [
      message({ id: 1, role: "user", text: "first" }),
      message({ id: 2, role: "system", text: "boom" }),
      message({ id: 3, role: "user", text: "second" }),
      message({ id: 4, role: "system", text: "boom again" })
    ]

    const map = retryTextByMessageId(messages)
    expect(map.get(2)).toBe("first")
    expect(map.get(4)).toBe("second")
  })

  it("does not map a system message that precedes any user message", () => {
    const messages = [
      message({ id: 1, role: "system", text: "MCP connected" }),
      message({ id: 2, role: "user", text: "hi" })
    ]

    expect(retryTextByMessageId(messages).has(1)).toBe(false)
  })

  it("ignores assistant and tool messages", () => {
    const messages = [
      message({ id: 1, role: "user", text: "hi" }),
      message({ id: 2, role: "assistant", text: "hello there" }),
      message({ id: 3, role: "tool_use", text: "" }),
      message({ id: 4, role: "system", text: "boom" })
    ]

    expect(retryTextByMessageId(messages).get(4)).toBe("hi")
  })

  it("returns an empty map for no messages", () => {
    expect(retryTextByMessageId([]).size).toBe(0)
  })
})
