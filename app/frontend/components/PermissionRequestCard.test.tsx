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
  it("lazily restores smart actions for a summary request", async () => {
    const summaryItem = { ...request.items[0] }
    delete summaryItem.smart_option
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ request }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <PermissionRequestCard request={{ ...request, items: [summaryItem] }} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Allow for this job" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/permission_requests/9", expect.anything())
  })

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

  it("keeps long statements inside a 402px card without raw structures or identifiers", () => {
    const long = {
      presentation: { statement: "x".repeat(500), agent: "Maya", scope: "y".repeat(300), consequences: ["send a message"] },
      items: [{ ...request.items[0], arguments: { description: "SECRET_ARGUMENT" }, resource_scope: { job_id: 777 } }]
    }
    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <PermissionRequestCard request={{ ...request, ...long }} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    const card = screen.getByTestId("permission-request-9")
    expect(card.className).toContain("min-w-0")
    expect(card.className).toContain("overflow-hidden")
    expect(card.className).not.toContain("overflow-x-auto")
    expect(screen.getByRole("heading").className).toContain("break-words")
    expect(screen.getByText(/y{50}/).className).toContain("[overflow-wrap:anywhere]")
    expect(card.textContent).not.toMatch(/SECRET_ARGUMENT|777|mail\.send|\{|—/)
  })

  it("omits optional context that is not available", () => {
    render(
      <QueryClientProvider client={new QueryClient()}>
        <MemoryRouter>
          <PermissionRequestCard request={{ ...request, presentation: { statement: "Draft an email" } }} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    expect(screen.getByText("Draft an email")).toBeInTheDocument()
    expect(screen.queryByText("Why is approval required?")).not.toBeInTheDocument()
    expect(screen.queryByText("Applies to")).not.toBeInTheDocument()
  })
})
