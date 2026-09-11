import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { AdminAttentionItems } from "./AdminAttentionItems"

function item(overrides: Record<string, unknown> = {}) {
  return {
    id: 12,
    problem_code: "grader_failure",
    problem_label: "Grader failure",
    signature: "grader_failure:abcd1234",
    title: "rspec failed on JOB-42",
    summary: "Required grader rspec failed on the landing candidate.",
    queue: "operator",
    urgency: "urgent",
    state: "open",
    resolution: null,
    reason: null,
    evidence: { grader_name: "rspec", exit_status: "1" },
    adjudication: { verdict: "inconclusive", reason: "no opinion" },
    actions: [{ action_key: "retry_job", label: "Retry from the failed step", detail: "job_id: 42", payload: { job_id: 42 } }],
    repository: { id: 2, slug: "tkadauke/syrus", path: "/repositories/2" },
    job: { id: 42, slug: "JOB-42", title: "Fix flaky spec", state: "landing", path: "/jobs/42" },
    workflow: { id: 900, trigger_kind: "auto_merge", state: "failed", slug: "WF-900", path: "/jobs/42?tab=workflows#workflow-900" },
    step: { id: 5, kind: "graders", state: "failed" },
    decided_by: null,
    decided_at: null,
    expires_at: null,
    created_at: "2026-09-07T10:00:00Z",
    ...overrides
  }
}

function payload(overrides: Record<string, unknown> = {}) {
  return {
    items: [item()],
    pagination: {
      page: 1,
      per_page: 50,
      total: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    filter_schema: [{ field: "state", label: "State", bucket: "enum", operators: ["is"], values: [{ value: "open", label: "open" }] }],
    filter: { and: [] },
    ...overrides
  }
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/attention_items"]}>
        <AdminAttentionItems />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminAttentionItems", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the queue, expands an item's evidence/adjudication/actions, and runs an action", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/attention_items" && (!init || init.method === undefined)) {
        return Promise.resolve(jsonResponse(payload()))
      }
      if (url === "/api/v1/app/admin/attention_items/12/act" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(item({ state: "open" })))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute()

    expect(await screen.findByRole("heading", { name: "Attention Items" })).toBeInTheDocument()
    expect(await screen.findByText("rspec failed on JOB-42")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")

    fireEvent.click(screen.getByText("rspec failed on JOB-42"))

    expect(await screen.findByText("Retry from the failed step")).toBeInTheDocument()
    expect(screen.getByText("job_id: 42")).toBeInTheDocument()
    expect(screen.getByText(/no opinion/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Run" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/attention_items/12/act", expect.objectContaining({ method: "POST" }))
    })
    const actCall = fetchSpy.mock.calls.find(([input, init]) => String(input) === "/api/v1/app/admin/attention_items/12/act" && init?.method === "POST")
    expect(JSON.parse(String(actCall?.[1]?.body))).toEqual({ action_key: "retry_job", reason: undefined })
  })

  it("records a decision via the decide form", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/attention_items/12/decide" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(item({ state: "decided", resolution: "dismissed" })))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute()

    fireEvent.click(await screen.findByText("rspec failed on JOB-42"))
    fireEvent.change(await screen.findByLabelText("Resolution"), { target: { value: "dismissed" } })
    fireEvent.click(screen.getByRole("button", { name: "Decide" }))

    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith("/api/v1/app/admin/attention_items/12/decide", expect.objectContaining({ method: "POST" }))
    })
  })
})
