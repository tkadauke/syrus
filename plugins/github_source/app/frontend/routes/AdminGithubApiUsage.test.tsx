import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import AdminGithubApiUsage from "./AdminGithubApiUsage"
import type { GithubApiUsagePayload } from "../api/githubApiUsage"

function payload(overrides: Partial<GithubApiUsagePayload> = {}): GithubApiUsagePayload {
  return {
    hours: 24,
    filter: { and: [{ field: "hours", op: "is", value: "24" }] },
    filter_schema: [
      {
        field: "hours",
        label: "Window",
        bucket: "enum",
        operators: ["is"],
        values: [
          { label: "1 hour", value: "1" },
          { label: "24 hours", value: "24" },
          { label: "7 days", value: "168" }
        ]
      }
    ],
    generated_at: "2026-09-25T12:00:00Z",
    totals: { requests: 12, rate_limited: 1 },
    by_operation: [
      { auth_source: "app", operation: "issues.list", resource: "core", requests: 10, rate_limited: 1, min_remaining: 42, last_seen_at: "2026-09-25T11:00:00Z" },
      { auth_source: "pat", operation: "pulls.get", resource: "core", requests: 2, rate_limited: 0, min_remaining: 99, last_seen_at: "2026-09-25T10:00:00Z" }
    ],
    by_repository: [
      { auth_source: "app", repo_slug: "acme/widgets", requests: 8, rate_limited: 1, min_remaining: 42, last_seen_at: "2026-09-25T11:00:00Z" }
    ],
    recent_rate_limits: [],
    ...overrides
  }
}

function renderRoute(initialEntry = "/admin/github_api_usage") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<AdminGithubApiUsage />} path="/admin/github_api_usage" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminGithubApiUsage", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the shared FilterBar and configurable sortable data tables", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()

    expect(await screen.findByRole("heading", { name: "GitHub API Usage" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Window is 24 hours" })).toBeInTheDocument()
    await screen.findByText("By Operation")
    expect(screen.getAllByRole("button", { name: "Columns" }).length).toBeGreaterThanOrEqual(2)

    const operationPanel = screen.getByText("By Operation").closest("section") as HTMLElement
    fireEvent.click(within(operationPanel).getByRole("button", { name: "Requests" }))

    await waitFor(() => {
      const rows = within(operationPanel).getAllByRole("row")
      expect(rows[1]).toHaveTextContent("pulls.get")
      expect(rows[2]).toHaveTextContent("issues.list")
    })
  })

  it("updates the legacy hours query param through the shared FilterBar chip editor", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute()
    await screen.findByRole("heading", { name: "GitHub API Usage" })

    fireEvent.click(screen.getByRole("button", { name: "Window is 24 hours" }))
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "168" } })

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => String(call[0]).includes("hours=168"))).toBe(true)
    })
  })
})
