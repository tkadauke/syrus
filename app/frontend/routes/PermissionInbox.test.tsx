import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import * as api from "../api/permissionRequests"
import { PermissionInboxRoute } from "./PermissionInbox"

vi.mock("../api/permissionRequests", async () => {
  const actual = await vi.importActual<typeof import("../api/permissionRequests")>("../api/permissionRequests")
  return { ...actual, fetchPermissionRequests: vi.fn(), decidePermissionRequest: vi.fn(), batchDecidePermissionRequests: vi.fn() }
})

const request = {
  presentation: {
    statement: "Send a message to another chat",
    agent: "Release agent",
    origin: "Job: Ship 1.0",
    scope: "Chat Release room",
    consequences: ["send a message"],
    why_approval_required: "Your settings require your approval before an agent does this.",
    requested_durations: ["This one time"]
  },
  id: 12,
  state: "pending",
  actionable: true,
  purpose: "Publish the release note",
  requested_by: "agent",
  runtime_role: "implementer",
  created_at: "2026-11-02T00:00:00Z",
  checkpoint_state: "waiting",
  non_actionable_reason: null,
  origin: { type: "Job", id: 42, label: "JOB-42" },
  subject: { type: "User", id: 1, label: "Release agent" },
  repository: null,
  items: [
    {
      id: 3,
      kind: "operation",
      state: "pending",
      capability: "communication.chat@v1",
      operation: "send@v1",
      resource_type: "job",
      resource_scope: { job_id: 42 },
      arguments: { channel: "release" },
      effects: ["communication"],
      risk: "medium",
      purpose: "Announce completion",
      policy_chain: [],
      decisive_rule: { source: "role_default", policy: "ask" },
      requested_durations: ["invocation", "job"],
      selected_duration: null,
      decision_reason: null,
      decided_at: null
    }
  ]
}

describe("PermissionInboxRoute", () => {
  beforeEach(() => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [request],
      summary: { pending_count: 1, blocked_agent_count: 1 },
      pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
    })
    vi.mocked(api.decidePermissionRequest).mockResolvedValue({ request: { ...request, state: "confirmed" } })
  })

  it("shows plain-English context and approves the selected compatible duration", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/permissions/inbox"]}>
          <PermissionInboxRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Send a message to another chat")).toBeInTheDocument()
    expect(screen.getByText("Send a message to another chat")).toBeInTheDocument()
    expect(screen.getByText("Release agent · Job: Ship 1.0")).toBeInTheDocument()
    expect(screen.getByText("Chat Release room")).toBeInTheDocument()
    expect(screen.getByText("Why is approval required?")).toBeInTheDocument()
    const card = screen.getByTestId("permission-request-12")
    expect(card.textContent).not.toMatch(/communication\.chat|send@v1|job_id|\{|"|role_default/)
    fireEvent.change(screen.getByLabelText("Authority duration"), { target: { value: "job" } })
    fireEvent.click(screen.getByRole("button", { name: "Approve" }))
    await waitFor(() => expect(api.decidePermissionRequest).toHaveBeenCalledWith(12, "approved", "job"))
  })

  it("batches selected requests using only a shared duration", async () => {
    const second = { ...request, id: 13, purpose: "Second request", items: [{ ...request.items[0], id: 4, requested_durations: ["job"] }] }
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [request, second],
      summary: { pending_count: 2, blocked_agent_count: 2 },
      pagination: { page: 1, per_page: 50, total: 2, total_pages: 1 }
    })
    vi.mocked(api.batchDecidePermissionRequests).mockResolvedValue({ requests: [] })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/permissions/inbox"]}>
          <PermissionInboxRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByLabelText("Select request: Publish the release note"))
    fireEvent.click(screen.getByLabelText("Select request: Second request"))
    expect(screen.getAllByLabelText("Authority duration")[0]).toHaveValue("job")
    fireEvent.click(screen.getByRole("button", { name: "Approve selected" }))
    await waitFor(() => expect(api.batchDecidePermissionRequests).toHaveBeenCalledWith([12, 13], "approved", "job"))
  })

  it("keeps a pending request read-only when it is not actionable by the viewer", async () => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [{ ...request, actionable: false }],
      summary: { pending_count: 1, blocked_agent_count: 1 },
      pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/permissions/inbox"]}>
          <PermissionInboxRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Send a message to another chat")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Select request: Publish the release note")).not.toBeInTheDocument()
  })

  it("preserves the app-shell prefix in pagination links", async () => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [request],
      summary: { pending_count: 1, blocked_agent_count: 1 },
      pagination: { page: 1, per_page: 50, total: 51, total_pages: 2 }
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/permissions/inbox"]}>
          <PermissionInboxRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/permissions/inbox?page=2")
  })

  it("sends the encoded filter to the server and offers labeled choices from the response", async () => {
    const tree = { and: [{ field: "action", op: "is_one_of", value: ["communication.chat/send@v1"] }] }
    const q = btoa(JSON.stringify(tree)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [request],
      filter_options: {
        state: [{ value: "pending", label: "Pending" }],
        subject: [{ value: "User:1", label: "Release agent" }],
        action: [{ value: "communication.chat/send@v1", label: "Send a message to another chat" }],
        effect: [{ value: "communication", label: "send a message" }],
        origin_type: [{ value: "Job", label: "Job" }]
      },
      summary: { pending_count: 1, blocked_agent_count: 1 },
      pagination: { page: 2, per_page: 50, total: 120, total_pages: 3 }
    })
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={[`/permissions/inbox?page=2&q=${q}`]}>
          <PermissionInboxRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByText("Page 2 of 3")
    expect(api.fetchPermissionRequests).toHaveBeenCalledWith(2, q)
    expect(screen.getByRole("link", { name: "Next" }).getAttribute("href")).toContain(`q=${q}`)
    expect(screen.getByRole("link", { name: "Previous" }).getAttribute("href")).toContain(`q=${q}`)
  })
})
