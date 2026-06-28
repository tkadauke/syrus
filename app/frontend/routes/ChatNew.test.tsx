import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { createChat } from "../api/chats"
import { ChatForm } from "./ChatNew"

vi.mock("../api/chats", () => ({
  createChat: vi.fn(),
  fetchNewChat: vi.fn()
}))

describe("ChatForm draft persistence", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("restores the new chat draft from localStorage", () => {
    window.localStorage.setItem("syrus.chat.draft.new", "hello")

    renderChatForm()

    expect(screen.getByLabelText("First message")).toHaveValue("hello")
  })

  it("writes text changes to localStorage", () => {
    renderChatForm()

    fireEvent.change(screen.getByLabelText("First message"), { target: { value: "Draft a rollout plan" } })

    expect(window.localStorage.getItem("syrus.chat.draft.new")).toBe("Draft a rollout plan")
  })

  it("clears the draft after creating the chat", async () => {
    vi.mocked(createChat).mockResolvedValue({
      message: "Created",
      redirect_to: "/chats/12",
      chat: {
        id: 12,
        title: "Release planning",
        title_pending: false,
        chat_path: "/chats/12",
        repository: null,
        pinned_context: null,
        stop_requested_at: null,
        cumulative_input_tokens: 0,
        cumulative_output_tokens: 0,
        cumulative_cost_usd: 0
      }
    })
    window.localStorage.setItem("syrus.chat.draft.new", "hello")
    renderChatForm()

    fireEvent.submit(screen.getByRole("button", { name: "Create chat" }).closest("form")!)

    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.draft.new")).toBeNull()
    })
    expect(createChat).toHaveBeenCalledWith({ repositoryId: "", text: "hello" })
  })
})

function renderChatForm() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        <ChatForm
          payload={{
            repositories: [{ id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }],
            repositories_path: "/repositories"
          }}
          prefix=""
        />
      </MemoryRouter>
    </QueryClientProvider>
  )
}
