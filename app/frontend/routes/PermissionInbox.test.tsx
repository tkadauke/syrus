import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import * as api from "../api/permissionRequests"
import { PermissionInboxRoute } from "./PermissionInbox"

vi.mock("../api/permissionRequests", async () => {
  const actual = await vi.importActual<typeof import("../api/permissionRequests")>("../api/permissionRequests")
  return { ...actual, fetchPermissionRequests: vi.fn(), decidePermissionRequest: vi.fn() }
})

const request = {
  id: 12, state: "pending", actionable: true, purpose: "Publish the release note", requested_by: "agent",
  runtime_role: "implementer", created_at: "2026-11-02T00:00:00Z", checkpoint_state: "waiting", non_actionable_reason: null,
  origin: { type: "Job", id: 42, label: "JOB-42" }, subject: { type: "User", id: 1, label: "Release agent" }, repository: null,
  items: [{ id: 3, kind: "operation", state: "pending", capability: "communication.chat@v1", operation: "send@v1",
    resource_type: "job", resource_scope: { job_id: 42 }, arguments: { channel: "release" }, effects: ["communication"],
    risk: "medium", purpose: "Announce completion", policy_chain: [], decisive_rule: { source: "role_default", policy: "ask" },
    requested_durations: ["invocation", "job"], selected_duration: null, decision_reason: null, decided_at: null }]
}

describe("PermissionInboxRoute", () => {
  beforeEach(() => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({ requests: [request] })
    vi.mocked(api.decidePermissionRequest).mockResolvedValue({ request: { ...request, state: "confirmed" } })
  })

  it("shows normalized request evidence and approves the selected compatible duration", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(<QueryClientProvider client={client}><MemoryRouter initialEntries={["/permissions/inbox"]}><PermissionInboxRoute /></MemoryRouter></QueryClientProvider>)

    expect(await screen.findByText("Publish the release note")).toBeInTheDocument()
    expect(screen.getByText(/communication.chat@v1/)).toBeInTheDocument()
    expect(screen.getByText("communication")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Authority duration"), { target: { value: "job" } })
    fireEvent.click(screen.getByRole("button", { name: "Approve" }))
    await waitFor(() => expect(api.decidePermissionRequest).toHaveBeenCalledWith(12, "approved", "job"))
  })
})
