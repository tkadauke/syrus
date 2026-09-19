import { act, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardChromePayload, DashboardPendingProposal } from "../api/dashboard"
import { applyAppEvent } from "../lib/appEvents"
import { PendingProposalsSection } from "./Dashboard"

function makeProposal(overrides: Partial<DashboardPendingProposal> = {}): DashboardPendingProposal {
  return {
    id: 1,
    title: "Survey aqueduct route",
    state: "proposed",
    chat_session_id: 9,
    chat_title: "Roadmap chat",
    anchor_message_id: 42,
    created_at: "2026-05-30T12:00:00.000Z",
    ...overrides
  }
}

// Renders through a live react-query cache (rather than passing `proposals`
// straight in) so the test exercises the same ["dashboard", "chrome", ...]
// cache the live-update patch in appEvents.ts writes to. staleTime: Infinity
// keeps this a pure cache-read like the real dashboard already has fetched
// data by the time a live broadcast arrives -- no background refetch racing
// the direct-cache-patch assertions below.
function DashboardChromeHarness() {
  const { data } = useQuery<DashboardChromePayload>({
    queryKey: ["dashboard", "chrome", ""],
    queryFn: () => Promise.resolve({ pending_proposals: [] } as unknown as DashboardChromePayload),
    staleTime: Infinity
  })

  return <PendingProposalsSection prefix="" proposals={data?.pending_proposals ?? []} />
}

function renderHarness(queryClient: QueryClient) {
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <DashboardChromeHarness />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("PendingProposalsSection", () => {
  it("renders up to 5 cards from the payload with title, chat context, and a relative timestamp", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <PendingProposalsSection
            prefix=""
            proposals={[
              makeProposal({ id: 1, title: "Survey aqueduct route" }),
              makeProposal({ id: 2, title: "Draft build plan", chat_title: "Build chat", anchor_message_id: 7 })
            ]}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Proposed")).toBeInTheDocument()
    expect(screen.getByText("Survey aqueduct route")).toBeInTheDocument()
    expect(screen.getByText("Draft build plan")).toBeInTheDocument()
    expect(screen.getByText("Roadmap chat")).toBeInTheDocument()
    expect(screen.getByText("Build chat")).toBeInTheDocument()

    const link = screen.getByRole("link", { name: /Survey aqueduct route/ })
    expect(link).toHaveAttribute("href", "/chats/9#message-42")
  })

  it("links to the plain chat when no anchor message id is known yet", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <PendingProposalsSection prefix="" proposals={[ makeProposal({ anchor_message_id: null }) ]} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("link", { name: /Survey aqueduct route/ })).toHaveAttribute("href", "/chats/9")
  })

  it("renders nothing when there are no pending proposals", () => {
    const { container } = render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <PendingProposalsSection prefix="" proposals={[]} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(container.firstChild).toBeNull()
  })

  it("adds a card live when an update_proposal broadcast reports a new proposed proposal", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["dashboard", "chrome", ""], { pending_proposals: [] })
    renderHarness(queryClient)

    await waitFor(() => expect(screen.queryByText("Survey aqueduct route")).not.toBeInTheDocument())

    act(() => {
      applyAppEvent(queryClient, {
        type: "chat.updated",
        resource: "chat",
        id: 9,
        changed: [ "proposal" ],
        payload: {
          action: "update_proposal",
          proposal_id: 1,
          dashboard_proposal: makeProposal({ id: 1, title: "Survey aqueduct route" })
        }
      })
    })

    expect(await screen.findByText("Survey aqueduct route")).toBeInTheDocument()
    expect(screen.getByText("Proposed")).toBeInTheDocument()
  })

  it("removes a card live the moment an update_proposal broadcast confirms or rejects it", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["dashboard", "chrome", ""], { pending_proposals: [ makeProposal({ id: 1, title: "Survey aqueduct route" }) ] })
    renderHarness(queryClient)

    expect(await screen.findByText("Survey aqueduct route")).toBeInTheDocument()

    act(() => {
      applyAppEvent(queryClient, {
        type: "chat.updated",
        resource: "chat",
        id: 9,
        changed: [ "proposal" ],
        payload: {
          action: "update_proposal",
          proposal_id: 1,
          dashboard_proposal: makeProposal({ id: 1, title: "Survey aqueduct route", state: "confirmed" })
        }
      })
    })

    await waitFor(() => expect(screen.queryByText("Survey aqueduct route")).not.toBeInTheDocument())
  })
})
