import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import * as api from "../api/permissionRequests"
import type { PermissionRequestsPayload } from "../api/permissionRequests"
import { PermissionInboxDrawer } from "./PermissionInboxDrawer"

vi.mock("../api/permissionRequests", async () => {
  const actual = await vi.importActual<typeof import("../api/permissionRequests")>("../api/permissionRequests")
  return { ...actual, fetchPermissionRequests: vi.fn(), decidePermissionRequest: vi.fn() }
})

describe("PermissionInboxDrawer", () => {
  afterEach(() => vi.useRealTimers())

  it("shows normalized arguments on compact request cards", async () => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [
        {
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
              arguments: { channel: "release", message: "Drawer must show this argument" },
              effects: ["communication"],
              risk: "medium",
              purpose: "Announce completion",
              policy_chain: [],
              decisive_rule: { source: "role_default", policy: "ask" },
              requested_durations: ["invocation"],
              selected_duration: null,
              decision_reason: null,
              decided_at: null
            }
          ]
        }
      ],
      summary: { pending_count: 1, blocked_agent_count: 1 },
      pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
    })
    vi.mocked(api.decidePermissionRequest).mockResolvedValue({
      request: {
        ...(await api.fetchPermissionRequests()).requests[0],
        state: "rejected",
        actionable: false,
        checkpoint_state: "denied"
      }
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <PermissionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const control = await screen.findByRole("button", { name: "Approvals, 1 pending; 1 blocked agent waiting for your decision" })
    expect(control).toHaveAttribute("data-blocked", "true")
    expect(screen.getByTestId("approval-waiting-halo")).toHaveClass(
      "motion-safe:animate-approval-waiting-halo",
      "motion-reduce:ring-2",
      "motion-reduce:ring-warning-border"
    )
    fireEvent.click(control)

    expect(screen.getByText("Arguments")).toBeInTheDocument()
    expect(screen.getByText(JSON.stringify({ channel: "release", message: "Drawer must show this argument" }))).toBeInTheDocument()
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [],
      summary: { pending_count: 0, blocked_agent_count: 0 },
      pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
    })
    fireEvent.click(screen.getByRole("button", { name: "Deny" }))
    await waitFor(() => expect(screen.queryByTestId("approval-waiting-halo")).not.toBeInTheDocument())
  })

  it("has no waiting halo when no agent is blocked", async () => {
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue({
      requests: [],
      summary: { pending_count: 0, blocked_agent_count: 0 },
      pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 }
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <PermissionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Open approval inbox" })).toHaveAttribute("data-blocked", "false")
    expect(screen.queryByTestId("approval-waiting-halo")).not.toBeInTheDocument()
  })

  it("stops the newly-blocked ping after one pulse and immediately on resolution", async () => {
    const empty: PermissionRequestsPayload = {
      requests: [],
      summary: { pending_count: 0, blocked_agent_count: 0 },
      pagination: { page: 1, per_page: 50, total: 0, total_pages: 0 }
    }
    vi.mocked(api.fetchPermissionRequests).mockResolvedValue(empty)
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <PermissionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )
    await screen.findByRole("button", { name: "Open approval inbox" })
    vi.useFakeTimers()

    act(() => {
      client.setQueryData<PermissionRequestsPayload>(["permission_requests", 1], {
        ...empty,
        summary: { pending_count: 1, blocked_agent_count: 1 }
      })
      vi.advanceTimersByTime(0)
    })
    expect(screen.getByTestId("approval-newly-blocked-ping")).toBeInTheDocument()

    act(() => vi.advanceTimersByTime(1_000))
    expect(screen.queryByTestId("approval-newly-blocked-ping")).not.toBeInTheDocument()

    act(() => {
      client.setQueryData<PermissionRequestsPayload>(["permission_requests", 1], empty)
      vi.advanceTimersByTime(0)
    })
    act(() => {
      client.setQueryData<PermissionRequestsPayload>(["permission_requests", 1], {
        ...empty,
        summary: { pending_count: 1, blocked_agent_count: 1 }
      })
      vi.advanceTimersByTime(0)
    })
    expect(screen.getByTestId("approval-newly-blocked-ping")).toBeInTheDocument()

    act(() => {
      client.setQueryData<PermissionRequestsPayload>(["permission_requests", 1], empty)
      vi.advanceTimersByTime(0)
    })
    expect(screen.queryByTestId("approval-newly-blocked-ping")).not.toBeInTheDocument()
  })
})
