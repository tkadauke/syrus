import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryInsightsRoute } from "./RepositoryInsights"
import * as useConfirmModule from "../hooks/useConfirm"

function makeSuggestion(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    title: "Frequent prepare failures",
    category: "repeated_failure",
    severity: "high",
    confidence: 0.85,
    state: "pending",
    proposal_type: "create_job",
    suggested_prompt: "Fix the prepare step",
    memory_suggestion: "Always check bundle install logs",
    has_memory_suggestion: true,
    target_memory_id: null,
    stale_memory_text: null,
    stale_memory_evidence: null,
    target_insight_id: null,
    evidence: [],
    job_slug: "JOB-100",
    job_path: "/jobs/100",
    accepted_at: null,
    dismissed_at: null,
    created_at: "2026-07-01T00:00:00Z",
    created_job: null,
    ...overrides
  }
}

function makeMeta(overrides: Record<string, unknown> = {}) {
  return { total: 1, page: 1, per_page: 20, total_pages: 1, ...overrides }
}

function payload(suggestions: unknown[] = [makeSuggestion()], meta = makeMeta({ total: suggestions.length })) {
  return {
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1", insights_path: "/repositories/1/insights" },
    tabs: [],
    suggestions,
    meta
  }
}

function renderRoute(suggestions?: unknown[], meta?: Record<string, unknown>) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload(suggestions, meta ? makeMeta(meta) : undefined)))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/insights"]}>
        <Routes>
          <Route element={<RepositoryInsightsRoute />} path="/app-shell/repositories/:id/insights" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryInsightsRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  describe("dismiss confirmation", () => {
    let mockConfirm: ReturnType<typeof vi.fn>

    beforeEach(() => {
      mockConfirm = vi.fn().mockResolvedValue(true)
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
    })

    it("shows a confirm dialog before dismissing", async () => {
      renderRoute()

      const dismissBtn = await screen.findByRole("button", { name: "Dismiss" })
      fireEvent.click(dismissBtn)

      await waitFor(() => {
        expect(mockConfirm).toHaveBeenCalledWith(
          expect.objectContaining({ destructive: true })
        )
      })
    })

    it("fires the dismiss API when the user confirms", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.includes("/insight_suggestions/1") && init?.method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Suggestion dismissed.", suggestion: makeSuggestion({ state: "dismissed" }) }))
        }
        return Promise.resolve(jsonResponse(payload()))
      })

      renderRoute()
      const dismissBtn = await screen.findByRole("button", { name: "Dismiss" })
      fireEvent.click(dismissBtn)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1",
          expect.objectContaining({ method: "PATCH" })
        )
      })
    })

    it("does not fire the dismiss API when the user cancels", async () => {
      mockConfirm.mockResolvedValue(false)
      const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

      renderRoute()
      const dismissBtn = await screen.findByRole("button", { name: "Dismiss" })
      await act(async () => { fireEvent.click(dismissBtn) })

      await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
      expect(fetchSpy).not.toHaveBeenCalledWith(
        "/api/v1/app/insight_suggestions/1",
        expect.objectContaining({ method: "PATCH" })
      )
    })
  })

  describe("Accept form — collapsed prompt", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("hides the prompt textarea by default when a suggested_prompt exists", async () => {
      renderRoute([makeSuggestion({ suggested_prompt: "Fix the prepare step" })])

      const acceptBtn = await screen.findByRole("button", { name: "Accept" })
      fireEvent.click(acceptBtn)

      expect(screen.queryByRole("textbox", { name: "Prompt" })).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Edit prompt" })).toBeInTheDocument()
    })

    it("shows the prompt textarea after clicking Edit prompt", async () => {
      renderRoute([makeSuggestion({ suggested_prompt: "Fix the prepare step" })])

      const acceptBtn = await screen.findByRole("button", { name: "Accept" })
      fireEvent.click(acceptBtn)

      fireEvent.click(screen.getByRole("button", { name: "Edit prompt" }))

      expect(screen.getByRole("textbox", { name: "Prompt" })).toBeInTheDocument()
    })

    it("shows the prompt textarea expanded by default when no suggested_prompt", async () => {
      renderRoute([makeSuggestion({ suggested_prompt: null, has_memory_suggestion: false })])

      const acceptBtn = await screen.findByRole("button", { name: "Accept" })
      fireEvent.click(acceptBtn)

      expect(screen.getByRole("textbox", { name: "Prompt" })).toBeInTheDocument()
    })

    it("does not show the create-job checkbox", async () => {
      renderRoute()

      const acceptBtn = await screen.findByRole("button", { name: "Accept" })
      fireEvent.click(acceptBtn)

      expect(screen.queryByRole("checkbox")).not.toBeInTheDocument()
    })
  })

  describe("accepted card — job link", () => {
    it("shows a link to the created job next to the Accepted badge", async () => {
      const accepted = makeSuggestion({
        state: "accepted",
        created_job: { id: 42, slug: "JOB-42", title: "Fix thing", state: "open", job_path: "/jobs/42" }
      })
      renderRoute([accepted])

      // switch to Accepted tab
      const acceptedTab = await screen.findByRole("button", { name: /Accepted/ })
      fireEvent.click(acceptedTab)

      const link = await screen.findByRole("link", { name: "JOB-42" })
      expect(link).toHaveAttribute("href", "/jobs/42")
    })
  })

  describe("independent memory save", () => {
    it("shows Save as memory button on accepted cards with a memory suggestion", async () => {
      const accepted = makeSuggestion({
        state: "accepted",
        has_memory_suggestion: true
      })
      renderRoute([accepted])

      const acceptedTab = await screen.findByRole("button", { name: /Accepted/ })
      fireEvent.click(acceptedTab)

      expect(await screen.findByRole("button", { name: "Save as memory" })).toBeInTheDocument()
    })

    it("does not show Save as memory button on accepted cards without a memory suggestion", async () => {
      const accepted = makeSuggestion({
        state: "accepted",
        has_memory_suggestion: false,
        memory_suggestion: null
      })
      renderRoute([accepted])

      const acceptedTab = await screen.findByRole("button", { name: /Accepted/ })
      fireEvent.click(acceptedTab)

      await screen.findByText("Frequent prepare failures")
      expect(screen.queryByRole("button", { name: "Save as memory" })).not.toBeInTheDocument()
    })
  })

  describe("remove-memory proposals", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("renders stale memory details distinctly and accepts by removing memory", async () => {
      const removeMemory = makeSuggestion({
        proposal_type: "remove_memory",
        suggested_prompt: null,
        memory_suggestion: null,
        has_memory_suggestion: false,
        target_memory_id: 44,
        stale_memory_text: "The old flaky test still fails.",
        stale_memory_evidence: "The test was fixed by JOB-200."
      })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.includes("/insight_suggestions/1") && init?.method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Memory removed and suggestion accepted.", suggestion: makeSuggestion({ ...removeMemory, state: "accepted" }), memory_id: 44 }))
        }
        return Promise.resolve(jsonResponse(payload([removeMemory])))
      })

      renderRoute([removeMemory])
      fireEvent.click(await screen.findByRole("button", { name: "Expand" }))

      expect(await screen.findByText("Remove memory #44")).toBeInTheDocument()
      expect(screen.getByText("The old flaky test still fails.")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Remove memory" }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1",
          expect.objectContaining({ method: "PATCH" })
        )
      })
    })
  })

  describe("card body expansion", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("expands and collapses a suggestion when clicking the card body", async () => {
      renderRoute()

      const title = await screen.findByText("Frequent prepare failures")
      expect(screen.queryByText("Suggested prompt")).not.toBeInTheDocument()

      fireEvent.click(title)
      expect(screen.getByText("Suggested prompt")).toBeInTheDocument()

      fireEvent.click(title)
      expect(screen.queryByText("Suggested prompt")).not.toBeInTheDocument()
    })

    it("expands a suggestion when clicking the card shell", async () => {
      renderRoute()

      const title = await screen.findByText("Frequent prepare failures")
      const card = title.closest("article")
      expect(card).toBeInTheDocument()

      fireEvent.click(card!)

      expect(screen.getByText("Suggested prompt")).toBeInTheDocument()
    })

    it("does not collapse a suggestion when clicking an action button", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.includes("/insight_suggestions/1") && init?.method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Saved.", suggestion: makeSuggestion(), memory_id: 4 }))
        }
        return Promise.resolve(jsonResponse(payload()))
      })

      renderRoute()

      fireEvent.click(await screen.findByText("Frequent prepare failures"))
      fireEvent.click(screen.getByRole("button", { name: "Save as memory" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1",
          expect.objectContaining({ method: "PATCH" })
        )
      })
      expect(screen.getByText("Suggested prompt")).toBeInTheDocument()
    })
  })

  describe("undismiss action", () => {
    it("shows Undismiss button on dismissed cards", async () => {
      const dismissed = makeSuggestion({ state: "dismissed" })
      renderRoute([dismissed])

      const dismissedTab = await screen.findByRole("button", { name: /Dismissed/ })
      fireEvent.click(dismissedTab)

      expect(await screen.findByRole("button", { name: "Undismiss" })).toBeInTheDocument()
    })

    it("fires the undismiss API when Undismiss is clicked", async () => {
      const dismissed = makeSuggestion({ state: "dismissed" })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.includes("/insight_suggestions/1") && init?.method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Suggestion restored to pending.", suggestion: makeSuggestion({ state: "pending" }) }))
        }
        return Promise.resolve(jsonResponse(payload([dismissed])))
      })

      renderRoute([dismissed])

      const dismissedTab = await screen.findByRole("button", { name: /Dismissed/ })
      fireEvent.click(dismissedTab)

      const undismissBtn = await screen.findByRole("button", { name: "Undismiss" })
      fireEvent.click(undismissBtn)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1",
          expect.objectContaining({ method: "PATCH" })
        )
      })
    })
  })

  describe("pagination controls", () => {
    it("does not render pagination when total_pages is 1", async () => {
      renderRoute([makeSuggestion()], makeMeta({ total: 1, total_pages: 1 }))

      await screen.findByText("Frequent prepare failures")

      expect(screen.queryByRole("button", { name: "Next" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
    })

    it("renders pagination controls when total_pages > 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, makeMeta({ total: 25, page: 1, per_page: 20, total_pages: 2 }))

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.getByRole("button", { name: "Next" })).toBeInTheDocument()
    })

    it("Previous is disabled (not a button) on page 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, makeMeta({ total: 25, page: 1, per_page: 20, total_pages: 2 }))

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
      expect(screen.getByText("Previous")).toBeInTheDocument()
    })

    it("clicking Next re-fetches with page=2", async () => {
      const page1Suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      const page2Suggestions = [makeSuggestion({ id: 21, title: "Suggestion 21" })]

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
          <MemoryRouter initialEntries={["/app-shell/repositories/1/insights"]}>
            <Routes>
              <Route element={<RepositoryInsightsRoute />} path="/app-shell/repositories/:id/insights" />
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
