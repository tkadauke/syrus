import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { createChat, fetchNewChat } from "../api/chats"
import { ChatNewRoute } from "./ChatNew"

vi.mock("../components/ImageAnnotationModal", () => ({
  ImageAnnotationModal: ({ name, onDone, onClose }: { name: string; onDone: (dataUrl: string) => void; onClose: () => void }) => (
    <div aria-label={`Annotating ${name}`} role="dialog">
      <button onClick={() => onDone("data:image/png;base64,annotated")} type="button">Done</button>
      <button onClick={onClose} type="button">Cancel</button>
    </div>
  )
}))

vi.mock("../api/chats", () => ({
  createChat: vi.fn(),
  fetchNewChat: vi.fn()
}))

describe("ChatNewRoute", () => {
  beforeEach(() => {
    vi.mocked(createChat).mockReset()
    vi.mocked(fetchNewChat).mockReset()
    vi.mocked(fetchNewChat).mockResolvedValue({
      repositories: [{ id: 42, slug: "acme/widgets" }],
      default_repository_id: 42,
      repositories_path: "/repositories"
    })
  })

  it("renders a compose form without creating a blank chat", async () => {
    renderNewChatRoute()

    expect(await screen.findByRole("form", { name: "Start a new chat" })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Repository" })).toHaveValue("42")
    expect(screen.getByRole("textbox", { name: "First message" })).toBeInTheDocument()
    expect(createChat).not.toHaveBeenCalled()
  })

  it("shows drag-over state and adds dropped attachments", async () => {
    renderNewChatRoute()

    const form = await screen.findByRole("form", { name: "Start a new chat" })
    const file = new File(["pixels"], "screen.png", { type: "image/png" })

    fireEvent.dragEnter(form, { dataTransfer: { files: [file] } })
    expect(form).toHaveClass("ring-2", "ring-blue-400")

    fireEvent.drop(form, { dataTransfer: { files: [file] } })

    expect(await screen.findByRole("button", { name: "Annotate screen.png" })).toBeInTheDocument()
    expect(form).not.toHaveClass("ring-2")
  })

  it("validates per-file attachment size", async () => {
    renderNewChatRoute()

    const input = await screen.findByLabelText("Chat attachments")
    const file = new File(["x"], "large.png", { type: "image/png" })
    Object.defineProperty(file, "size", { value: 5 * 1024 * 1024 + 1 })

    fireEvent.change(input, { target: { files: [file] } })

    expect(await screen.findByText("Each attachment must be 5 MB or smaller.")).toBeInTheDocument()
  })

  it("adds pasted image attachments", async () => {
    renderNewChatRoute()

    const form = await screen.findByRole("form", { name: "Start a new chat" })
    const file = new File(["pasted"], "clipboard.png", { type: "image/png" })

    fireEvent.paste(form, {
      clipboardData: {
        items: [
          {
            kind: "file",
            type: "image/png",
            getAsFile: () => file
          }
        ]
      }
    })

    expect(await screen.findByRole("button", { name: "Annotate clipboard.png" })).toBeInTheDocument()
  })

  it("sends annotated attachments with the first message", async () => {
    vi.mocked(createChat).mockResolvedValue({
      message: "Message sent.",
      redirect_to: "/chats/18",
      chat: chatRecord({ id: 18 })
    })
    renderNewChatRoute()

    fireEvent.change(await screen.findByLabelText("Chat attachments"), { target: { files: [new File(["pixels"], "screen.png", { type: "image/png" })] } })
    fireEvent.click(await screen.findByRole("button", { name: "Annotate screen.png" }))
    fireEvent.click(screen.getByRole("button", { name: "Done" }))
    fireEvent.change(screen.getByRole("textbox", { name: "First message" }), { target: { value: "Inspect this screenshot" } })
    fireEvent.submit(screen.getByRole("form", { name: "Start a new chat" }))

    await waitFor(() => {
      expect(createChat).toHaveBeenCalledWith({
        repositoryId: "42",
        text: "Inspect this screenshot",
        attachments: [
          {
            name: "screen.png",
            mimeType: "image/png",
            dataUrl: "data:image/png;base64,annotated",
            size: 6
          }
        ]
      })
    })
    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/18")
    })
  })
})

function renderNewChatRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/new"]}>
        <Routes>
          <Route element={<ChatNewRoute />} path="/app-shell/chats/new" />
          <Route element={<LocationProbe />} path="*" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}</div>
}

function chatRecord({ id }: { id: number }) {
  return {
    id,
    title: null,
    title_pending: true,
    pinned: false,
    pinned_context: null,
    chat_path: `/chats/${id}`,
    repository: null,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    pending_proposal_count: 0
  }
}
