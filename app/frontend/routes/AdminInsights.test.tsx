import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach } from "vitest"
import { AdminInsightsRoute } from "./AdminInsights"

function makeSuggestion(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    title: "Cross-repo cache miss",
    category: "inefficiency",
    severity: "medium",
    confidence: 0.75,
    state: "pending",
    suggested_prompt: "Fix caching",
    memory_suggestion: null,
    has_memory_suggestion: false,
    evidence: [],
    job_slug: "JOB-200",
    job_path: "/jobs/200",
    accepted_at: null,
    dismissed_at: null,
    created_at: "2026-07-01T00:00:00Z",
    created_job: null,
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1", insights_path: "/repositories/1/insights" },
    user: { id: 1, display_name: "Alice" },
    ...overrides
  }
}

function makeMeta(overrides: Record<string, unknown> = {}) {
  return { total: 1, page: 1, per_page: 20, total_pages: 1, ...overrides }
}

function payload(suggestions: unknown[] = [makeSuggestion()], meta = makeMeta({ total: suggestions.length })) {
  return { suggestions, meta }
}

function renderRoute(suggestions?: unknown[], metaOverrides?: Record<string, unknown>) {
  const meta = makeMeta({ total: suggestions?.length ?? 1, ...metaOverrides })
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload(suggestions, meta)))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/admin/insights"]}>
        <Routes>
          <Route element={<AdminInsightsRoute />} path="/app-shell/admin/insights" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminInsightsRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  describe("pagination controls", () => {
    it("does not render pagination when total_pages is 1", async () => {
      renderRoute([makeSuggestion()])

      await screen.findByText("Cross-repo cache miss")

      expect(screen.queryByRole("button", { name: "Next" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
    })

    it("renders pagination controls when total_pages > 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, { total: 25, page: 1, per_page: 20, total_pages: 2 })

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.getByRole("button", { name: "Next" })).toBeInTheDocument()
    })

    it("Previous is disabled (not a button) on page 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, { total: 25, page: 1, per_page: 20, total_pages: 2 })

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
      expect(screen.getByText("Previous")).toBeInTheDocument()
    })

    it("clicking Next re-fetches with page=2", async () => {
      const page1Suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` })
      )
      const page2Suggestions = [makeSuggestion({ id: 21, title: "Admin Suggestion 21" })]

      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = String(input)
        if (url.includes("page=2")) {
          return Promise.resolve(jsonResponse(payload(page2Suggestions, makeMeta({ total: 21, page: 2, per_page: 20, total_pages: 2 }))))
        }
        return Promise.resolve(jsonResponse(payload(page1Suggestions, makeMeta({ total: 21, page: 1, per_page: 20, total_pages: 2 }))))
      })

      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/admin/insights"]}>
            <Routes>
              <Route element={<AdminInsightsRoute />} path="/app-shell/admin/insights" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("Showing 1–20 of 21")

      fireEvent.click(screen.getByRole("button", { name: "Next" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          expect.stringContaining("page=2"),
          expect.anything()
        )
      })
    })
  })
})
