import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import * as api from "../api/permissionRequests"
import { PermissionInboxDrawer } from "./PermissionInboxDrawer"

vi.mock("../api/permissionRequests", async () => {
  const actual = await vi.importActual<typeof import("../api/permissionRequests")>("../api/permissionRequests")
  return { ...actual, fetchPermissionRequests: vi.fn() }
})

describe("PermissionInboxDrawer", () => {
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
      pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <PermissionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Open approval inbox" }))

    expect(screen.getByText("Arguments")).toBeInTheDocument()
    expect(screen.getByText(JSON.stringify({ channel: "release", message: "Drawer must show this argument" }))).toBeInTheDocument()
  })
})
