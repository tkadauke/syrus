import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { pluginChatMessageComponentFor } from "@app/pluginChatMessageRenderers"
import type { PluginChatMessageProps } from "@app/pluginChatMessageRenderers"
import CoworkerMessage, { withoutMessagePrefix } from "./CoworkerMessage"

describe("Coworkers chat message contribution", () => {
  it("is discovered through the generic plugin renderer registry", () => {
    const component = pluginChatMessageComponentFor("coworkers/CoworkerMessage")

    expect(component).not.toBeNull()
    expect(component).not.toBe(CoworkerMessage)
  })

  it("removes only the matching transport prefix from historical messages", () => {
    expect(withoutMessagePrefix("Message from @maya\n\nHello", "from", "maya")).toBe("Hello")
    expect(withoutMessagePrefix("Message to @maya", "to", "maya")).toBe("")
    expect(withoutMessagePrefix("Unrelated", "from", "maya")).toBe("Unrelated")
  })

  it("renders two delivered replies with distinct author bubbles and working-session links", () => {
    const payload = { chat: { id: 10, conversation_kind: "direct" } }
    const item = (id: number, text: string) => ({ id, type: "message", role: "assistant", text, content: {}, attachments: [], created_at: "2026-11-17T00:00:00Z" })
    const props = (id: number, name: string, handle: string, accent: string, workingChatId: number) => ({
      item: item(id, `${name} answered`), payload,
      presentation: { component: "coworkers/CoworkerMessage", data: { appearance: { name, handle, accent_hex: accent, avatar_key: null, avatar_url: null }, direction: "incoming", handle, working_chat_id: workingChatId } },
      prefix: "", queryKey: ["chat", "10"], readOnly: true, entranceClass: "", onNotice: vi.fn()
    })
    const maya = props(1, "Maya", "maya", "#b6492e", 101) as unknown as PluginChatMessageProps
    const rin = props(2, "Rin", "rin", "#663399", 102) as unknown as PluginChatMessageProps

    render(
      <MemoryRouter>
        <CoworkerMessage {...maya} />
        <CoworkerMessage {...rin} />
      </MemoryRouter>
    )

    expect(screen.getByText("Maya")).toBeInTheDocument()
    expect(screen.getByText("Rin")).toBeInTheDocument()
    expect(screen.getAllByText("View working session").map((link) => link.getAttribute("href"))).toEqual([ "/chats/101", "/chats/102" ])
    expect(screen.getAllByTestId("coworker-incoming-message")).toHaveLength(2)
  })
})
