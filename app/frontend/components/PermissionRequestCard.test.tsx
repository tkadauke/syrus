import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { PermissionRequest } from "../api/permissionRequests"
import { PermissionRequestCard } from "./PermissionRequestCard"

const request: PermissionRequest = {
  id: 9,
  state: "pending",
  actionable: true,
  purpose: "Send a draft",
  requested_by: "agent",
  runtime_role: "chat:coworker",
  created_at: "2026-11-03T00:00:00Z",
  checkpoint_state: null,
  non_actionable_reason: null,
  origin: null,
  subject: { type: "Coworkers::Coworker", id: 1, label: "Maya" },
  repository: null,
  items: [
    {
      id: 33,
      kind: "operation",
      state: "pending",
      capability: "mail.send",
      operation: "mail.send/draft",
      resource_type: "none",
      resource_scope: {},
      arguments: {},
      effects: [],
      risk: null,
      purpose: null,
      policy_chain: [],
      decisive_rule: {},
      requested_durations: ["invocation"],
      selected_duration: null,
      decision_reason: null,
      decided_at: null,
      smart_option: {
        kind: "allow_job",
        duration: "job",
        digest: "d1",
        summary: { allows: ["Maya may draft in this job."], excludes: ["Other operations"] },
        draft: {},
        ceiling: {},
        context: { coworker: "Maya", operation: "mail.send/draft", repository: null, resource_scope_label: null, duration: "job" }
      }
    }
  ]
}

afterEach(() => vi.restoreAllMocks())

describe("PermissionRequestCard smart actions", () => {
  it("applies the adaptive rule through the item smart decision endpoint", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ request: { ...request, state: "confirmed", actionable: false } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )
    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <PermissionRequestCard request={request} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "Allow for this job" }))
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/permission_requests/9/items/33/smart_decision")
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({ duration: "job", digest: "d1" })
  })

  it("wraps long unbroken argument text instead of overflowing horizontally", () => {
    const long = { items: [{ ...request.items[0], arguments: { description: "x".repeat(500) } }] }
    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <PermissionRequestCard request={{ ...request, ...long }} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    const value = screen.getByText(/xxxxxxxx/)
    expect(value.className).toContain("[overflow-wrap:anywhere]")
    expect(screen.getByTestId("permission-request-9").className).toContain("min-w-0")
  })
})
