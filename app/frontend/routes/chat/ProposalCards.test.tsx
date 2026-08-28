import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PendingActionCard } from "./ProposalCards"
import type { ChatPendingAction } from "../../api/chats"
import type { ChatQueryKey } from "./constants"

function pendingAction(overrides: Partial<ChatPendingAction> = {}): ChatPendingAction {
  return {
    id: 501,
    label: "Rebase JOB-2325",
    detail: null,
    state: "failed",
    action: "rebase_job",
    action_type: null,
    execution_error: "GitHub API timed out.",
    app_confirm_path: "/api/v1/app/chats/122/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/122/pending_actions/501/reject",
    app_cancel_path: "/api/v1/app/chats/122/pending_actions/501",
    ...overrides
  }
}

function renderCard(action: ChatPendingAction, onNotice = vi.fn()) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(queryKey, { pending_actions: [action] })
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <PendingActionCard onNotice={onNotice} pendingAction={action} queryKey={queryKey} />
      </QueryClientProvider>
    </MemoryRouter>
  )
  return { onNotice }
}

describe("PendingActionCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows a dismiss button for a failed pending action and cancels it on click", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ pending_actions: [], message: "Pending action dismissed." }))
    const { onNotice } = renderCard(pendingAction())

    fireEvent.click(screen.getByRole("button", { name: "Dismiss failed action" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Pending action dismissed."))
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/chats/122/pending_actions/501")
    expect(init?.method).toBe("DELETE")
  })

  it("does not show a dismiss button for a pending (not yet failed) action", () => {
    renderCard(pendingAction({ state: "pending" }))

    expect(screen.queryByRole("button", { name: "Dismiss failed action" })).not.toBeInTheDocument()
  })
})
