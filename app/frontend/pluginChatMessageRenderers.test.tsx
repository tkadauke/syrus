import { act, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ChatPayload, ChatRenderItem } from "./api/chats"
import { preloadPluginContributions, registerPluginContribution, registerPluginContributionPreloader } from "./pluginContributionRegistry"
import { ChatMessage } from "./routes/chat/MessageCards"

function renderPluginMessage() {
  const item = {
    type: "message",
    id: 91,
    role: "assistant",
    text: "Existing fallback",
    attachments: [],
    plugin_message: { component: "late_renderer_test/Message" }
  } as Extract<ChatRenderItem, { type: "message" }>
  const payload = { chat: { id: 122 } } as ChatPayload
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ChatMessage item={item} payload={payload} prefix="" queryKey={["chats", "122", ""] as const} onNotice={() => {}} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("plugin chat message renderers", () => {
  it("shows the existing fallback before preload finishes and updates after registration", async () => {
    let release!: () => void
    const loading = new Promise<void>((resolve) => {
      release = resolve
    })
    registerPluginContributionPreloader("late_renderer_test", async () => {
      await loading
      registerPluginContribution("chat_message_renderer", "late_renderer_test", "Message", {
        default: () => <span>Late plugin message</span>
      })
    })

    const preload = preloadPluginContributions(["late_renderer_test"])
    const { container } = renderPluginMessage()
    expect(container).toBeEmptyDOMElement()

    await act(async () => {
      release()
      await preload
    })

    expect(screen.getByText("Late plugin message")).toBeInTheDocument()
  })
})
