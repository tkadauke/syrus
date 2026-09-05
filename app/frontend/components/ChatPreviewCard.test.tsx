import { jsonResponse } from "../testSupport"
import { render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ChatPreviewCard, ChatPreviewSkeleton } from "./ChatPreviewCard"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function chatPreviewPayload(overrides: Record<string, unknown> = {}) {
  return {
    id: 5,
    chat_slug: "CHAT-5",
    title: "Launch planning",
    title_pending: false,
    participants: [
      { id: 1, name: "Ada Lovelace", avatar_url: null, role: "owner" }
    ],
    pending_proposal_count: 0,
    pending_actions_count: 0,
    ...overrides
  }
}

function renderCard(id: number, compact = false) {
  render(
    <QueryClientProvider client={client()}>
      <MemoryRouter>
        <ChatPreviewCard compact={compact} id={id} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ChatPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows skeleton while data is loading", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard(5)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })

  it("renders the chat slug and title after load", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload()))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Launch planning")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy CHAT-5 to clipboard" })).toBeInTheDocument()
  })

  it("shows a generating-title placeholder while title_pending is true", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload({ title: null, title_pending: true })))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Generating title…")).toBeInTheDocument())
  })

  it("renders the title as a link to the chat", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload()))
    renderCard(5)
    await waitFor(() => expect(screen.getByRole("link", { name: "Launch planning" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "Launch planning" })).toHaveAttribute("href", "/chats/5")
  })

  it("renders a See more link pointing to the chat", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload()))
    renderCard(5)
    await waitFor(() => expect(screen.getByRole("link", { name: "See more" })).toBeInTheDocument())
    expect(screen.getByRole("link", { name: "See more" })).toHaveAttribute("href", "/chats/5")
  })

  it("does not render a participant row for a 1:1 chat", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload()))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Launch planning")).toBeInTheDocument())
    expect(screen.queryByText("Ada Lovelace")).not.toBeInTheDocument()
  })

  it("renders a participant avatar row when there is more than one participant", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload({
      participants: [
        { id: 1, name: "Ada Lovelace", avatar_url: null, role: "owner" },
        { id: 2, name: "Alan Turing", avatar_url: null, role: "member" }
      ]
    })))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Launch planning")).toBeInTheDocument())
    expect(screen.getByText("AL")).toBeInTheDocument()
    expect(screen.getByText("AT")).toBeInTheDocument()
  })

  it("shows a pending-work indicator when proposals or pending actions exist", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload({ pending_proposal_count: 2, pending_actions_count: 1 })))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("3 pending")).toBeInTheDocument())
  })

  it("omits the pending-work indicator when nothing is pending", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload()))
    renderCard(5)
    await waitFor(() => expect(screen.getByText("Launch planning")).toBeInTheDocument())
    expect(screen.queryByText(/pending/)).not.toBeInTheDocument()
  })

  it("compact: applies line-clamp-1 to title and hides the participant row and see-more link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(chatPreviewPayload({
      participants: [
        { id: 1, name: "Ada Lovelace", avatar_url: null, role: "owner" },
        { id: 2, name: "Alan Turing", avatar_url: null, role: "member" }
      ]
    })))
    renderCard(5, true)
    await waitFor(() => expect(screen.getByText("Launch planning")).toBeInTheDocument())
    const titleLink = screen.getByRole("link", { name: "Launch planning" })
    expect(titleLink.className).toContain("line-clamp-1")
    expect(screen.queryByText("AL")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "See more" })).not.toBeInTheDocument()
  })
})

describe("ChatPreviewSkeleton", () => {
  it("renders a pulsing placeholder", () => {
    render(<ChatPreviewSkeleton />)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })
})
