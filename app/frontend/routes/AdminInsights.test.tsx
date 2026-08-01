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
    proposal_type: "create_job",
    suggested_prompt: "Fix caching",
    memory_suggestion: null,
    has_memory_suggestion: false,
    target_memory_id: null,
    stale_memory_text: null,
    stale_memory_evidence: null,
    target_insight_id: null,
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
  return {
    total: 1,
    page: 1,
    per_page: 20,
    total_pages: 1,
    state: "pending",
    counts: { pending: 1, accepted: 0, dismissed: 0, all: 1 },
    ...overrides
  }
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

    it("clicking a state tab re-fetches page 1 with that state", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload([makeSuggestion()])))

      renderRoute()

      const dismissedTab = await screen.findByRole("button", { name: /Dismissed/ })
      fireEvent.click(dismissedTab)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          expect.stringContaining("state=dismissed"),
          expect.anything()
        )
      })
    })
  })

  describe("remove-memory proposals", () => {
    it("renders stale memory details and accepts removal", async () => {
      const removeMemory = makeSuggestion({
        proposal_type: "remove_memory",
        suggested_prompt: null,
        target_memory_id: 88,
        stale_memory_text: "This workaround is obsolete.",
        stale_memory_evidence: "The code path was removed."
      })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.includes("/insight_suggestions/1") && init?.method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Memory removed and suggestion accepted.", suggestion: makeSuggestion({ ...removeMemory, state: "accepted" }), memory_id: 88 }))
        }
        return Promise.resolve(jsonResponse(payload([removeMemory])))
      })

      renderRoute([removeMemory])

      fireEvent.click(await screen.findByRole("button", { name: "Cross-repo cache miss" }))
      expect(await screen.findByText("Remove memory #88")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Remove memory" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1",
          expect.objectContaining({ method: "PATCH" })
        )
      })
    })
  })
})
