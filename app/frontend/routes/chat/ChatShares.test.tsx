import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import * as chatsApi from "../../api/chats"
import { ChatShares } from "./ChatShares"

function renderShares() {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ChatShares chatId={42} />
    </QueryClientProvider>
  )
}

describe("ChatShares", () => {
  it("shows current shares, scoped candidates, and repository warnings", async () => {
    vi.spyOn(chatsApi, "fetchChatShares").mockResolvedValue({
      shares: [{ id: 5, user_id: 2, name: "Already Shared", handle: "shared", avatar_url: null, repository_access: true }],
      candidates: [{ user_id: 3, name: "No Repo", handle: "outside", avatar_url: null, repository_access: false }]
    })

    renderShares()
    fireEvent.click(screen.getByRole("button", { name: "Share" }))

    expect(await screen.findByText(/Already Shared/)).toBeInTheDocument()
    expect(screen.getByText(/No Repo/)).toBeInTheDocument()
    expect(screen.getByText("This person cannot access the attached repository.")).toBeInTheDocument()
  })

  it("looks up an exact handle and creates the share", async () => {
    const fetch = vi.spyOn(chatsApi, "fetchChatShares").mockResolvedValue({ shares: [], candidates: [] })
    const create = vi.spyOn(chatsApi, "createChatShare").mockResolvedValue({ shares: [] })
    renderShares()
    fireEvent.click(screen.getByRole("button", { name: "Share" }))
    fireEvent.change(await screen.findByPlaceholderText("Search people or type an exact @handle"), { target: { value: "@outside" } })

    await waitFor(() => expect(fetch).toHaveBeenCalledWith(42, "@outside"))
    fetch.mockResolvedValue({ shares: [], candidates: [{ user_id: 3, name: "Outside", handle: "outside", avatar_url: null, repository_access: true }] })
    fireEvent.change(screen.getByPlaceholderText("Search people or type an exact @handle"), { target: { value: "@outside " } })
    await screen.findByText(/Outside/)
    fireEvent.click(screen.getAllByRole("button", { name: /^Share$/ }).at(-1)!)
    await waitFor(() => expect(create).toHaveBeenCalled())
  })
})
