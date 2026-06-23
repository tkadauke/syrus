import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { StartEpicButton } from "./StartEpicButton"
import type { ChatProposal } from "../api/chats"

function proposal(overrides: Partial<ChatProposal> = {}): ChatProposal {
  return {
    id: 1, kind: "epic", kind_label: "Epic", state: "confirmed", state_label: "Confirmed",
    title: "Onboarding", slug: "onboarding", body: "", proposed: false, resolved: true,
    epic_bundle: true, scoped_repository_slug: "acme/widgets", dependency_slugs: [], dependencies: [], has_dependencies: false, target_epic_label: null,
    app_confirm_path: "", app_reject_path: "", materialized_label: "EPIC-1", materialized_path: "/epics/3",
    materialized_epic_state: "backlog", materialized_epic_state_path: "/api/v1/app/epics/3/state",
    ...overrides
  }
}

function renderButton(p: ChatProposal, onNotice = vi.fn()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <StartEpicButton proposal={p} onNotice={onNotice} />
    </QueryClientProvider>
  )
  return { onNotice }
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

describe("StartEpicButton", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing for a non-Epic proposal (no state path)", () => {
    const { container } = render(
      <QueryClientProvider client={new QueryClient()}>
        <StartEpicButton proposal={proposal({ materialized_epic_state_path: null })} onNotice={vi.fn()} />
      </QueryClientProvider>
    )
    expect(container).toBeEmptyDOMElement()
  })

  it("shows 'In progress' (no button) when the Epic already started", () => {
    renderButton(proposal({ materialized_epic_state: "in_progress" }))
    expect(screen.getByText("In progress")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Start" })).not.toBeInTheDocument()
  })

  it("starts the Epic and reports it via onNotice", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ epic: { state: "in_progress" } }))
    const { onNotice } = renderButton(proposal())

    fireEvent.click(screen.getByRole("button", { name: "Start" }))

    await waitFor(() => expect(screen.getByText("In progress")).toBeInTheDocument())
    expect(onNotice).toHaveBeenCalledWith("Epic moved to In Progress — its Jobs will start.")
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/epics/3/state")
    expect(init?.method).toBe("PATCH")
    expect(JSON.parse(init?.body as string)).toEqual({ target_state: "in_progress", override: true })
  })
})
