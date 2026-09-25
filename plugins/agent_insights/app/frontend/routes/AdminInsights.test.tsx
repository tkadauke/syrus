import { jsonResponse } from "@app/testSupport"
import { resetApiClientStateForTests } from "@app/api/clientTestState"
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
    retired_reason: null,
    superseded_by_insight_id: null,
    superseded_by_job_id: null,
    evidence: [],
    job_slug: "JOB-200",
    job_path: "/jobs/200",
    accepted_at: null,
    dismissed_at: null,
    retired_at: null,
    created_at: "2026-07-01T00:00:00Z",
    created_job: null,
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1", insights_path: "/repositories/1/plugin/insights" },
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
    counts: { pending: 1, accepted: 0, dismissed: 0, retired: 0, all: 1 },
    ...overrides
  }
}

function makeSmartFolders(activeId = 1) {
  return [
    {
      id: 1,
      name: "Pending",
      i18n_key: "agent_insights_pending",
      position: 0,
      kind: "builtin",
      subject_type: "agent_insight",
      visibility: "always",
      count: 1,
      active: activeId === 1,
      filter: { and: [{ field: "state", op: "is", value: "pending" }] },
      path: "/admin/insights?smart_folder_id=1"
    },
    {
      id: 2,
      name: "Accepted",
      i18n_key: "agent_insights_accepted",
      position: 1,
      kind: "builtin",
      subject_type: "agent_insight",
      visibility: "always",
      count: 0,
      active: activeId === 2,
      filter: { and: [{ field: "state", op: "is", value: "accepted" }] },
      path: "/admin/insights?smart_folder_id=2"
    },
    {
      id: 3,
      name: "Dismissed",
      i18n_key: "agent_insights_dismissed",
      position: 2,
      kind: "builtin",
      subject_type: "agent_insight",
      visibility: "always",
      count: 0,
      active: activeId === 3,
      filter: { and: [{ field: "state", op: "is", value: "dismissed" }] },
      path: "/admin/insights?smart_folder_id=3"
    },
    {
      id: 4,
      name: "Retired",
      i18n_key: "agent_insights_retired",
      position: 3,
      kind: "builtin",
      subject_type: "agent_insight",
      visibility: "always",
      count: 0,
      active: activeId === 4,
      filter: { and: [{ field: "state", op: "is", value: "retired" }] },
      path: "/admin/insights?smart_folder_id=4"
    },
    {
      id: 5,
      name: "All",
      i18n_key: "agent_insights_all",
      position: 4,
      kind: "builtin",
      subject_type: "agent_insight",
      visibility: "always",
      count: 1,
      active: activeId === 5,
      filter: { and: [] },
      path: "/admin/insights?smart_folder_id=5"
    }
  ]
}

const filterSchema = [
  {
    bucket: "enum",
    field: "state",
    label: "State",
    operators: ["is"],
    values: [
      { label: "Pending", value: "pending" },
      { label: "Accepted", value: "accepted" },
      { label: "Dismissed", value: "dismissed" },
      { label: "Retired", value: "retired" }
    ]
  },
  {
    bucket: "enum",
    field: "severity",
    label: "Severity",
    operators: ["is"],
    values: [
      { label: "High", value: "high" },
      { label: "Medium", value: "medium" },
      { label: "Low", value: "low" }
    ]
  }
]

function payload(suggestions: unknown[] = [makeSuggestion()], meta = makeMeta({ total: suggestions.length }), overrides: Record<string, unknown> = {}) {
  return {
    active_smart_folder_id: 1,
    filter: { and: [{ field: "state", op: "is", value: "pending" }] },
    filter_schema: filterSchema,
    smart_folders: makeSmartFolders(),
    suggestions,
    meta,
    ...overrides
  }
}

function renderInsightsRoute() {
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

function renderRoute(suggestions?: unknown[], metaOverrides?: Record<string, unknown>) {
  const meta = makeMeta({ total: suggestions?.length ?? 1, ...metaOverrides })
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload(suggestions, meta)))
  renderInsightsRoute()
}

describe("AdminInsightsRoute", () => {
  afterEach(() => {
    resetApiClientStateForTests()
    vi.restoreAllMocks()
  })

  describe("chrome", () => {
    it("renders the page heading and eyebrow while the suggestions are loading", () => {
      vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))

      renderInsightsRoute()

      expect(screen.getByRole("heading", { level: 1, name: "Insights" })).toBeInTheDocument()
      expect(screen.getByText("Admin")).toBeInTheDocument()
      expect(screen.getByText("Loading insights…")).toBeInTheDocument()
    })

    it("fetches fresh data after a same-path loading render leaves a request unresolved", async () => {
      vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))

      renderInsightsRoute()
      expect(screen.getByText("Loading insights…")).toBeInTheDocument()

      resetApiClientStateForTests()
      vi.restoreAllMocks()
      vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload([makeSuggestion({ title: "Fresh insight" })])))

      renderInsightsRoute()

      expect(await screen.findByText("Fresh insight")).toBeInTheDocument()
    })

    it("renders the page heading and eyebrow when the suggestions fail to load", async () => {
      vi.spyOn(window, "fetch").mockRejectedValue(new Error("network down"))

      renderInsightsRoute()

      expect(await screen.findByText("Unable to load insights.")).toBeInTheDocument()
      expect(screen.getByRole("heading", { level: 1, name: "Insights" })).toBeInTheDocument()
      expect(screen.getByText("Admin")).toBeInTheDocument()
    })

    it("renders the page heading and eyebrow once the suggestions load", async () => {
      renderRoute([makeSuggestion()])

      await screen.findByText("Cross-repo cache miss")

      expect(screen.getByRole("heading", { level: 1, name: "Insights" })).toBeInTheDocument()
      expect(screen.getByText("Admin")).toBeInTheDocument()
    })
  })

  describe("pagination controls", () => {
    it("does not render pagination when total_pages is 1", async () => {
      renderRoute([makeSuggestion()])

      await screen.findByText("Cross-repo cache miss")

      expect(screen.queryByRole("button", { name: "Next" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
    })

    it("renders pagination controls when total_pages > 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) => makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` }))
      renderRoute(suggestions, { total: 25, page: 1, per_page: 20, total_pages: 2 })

      await waitFor(() => expect(screen.getAllByText("Showing 1–20 of 25").length).toBeGreaterThan(0))

      expect(screen.getAllByRole("button", { name: "Next" }).length).toBeGreaterThan(0)
    })

    it("Previous is disabled (not a button) on page 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) => makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` }))
      renderRoute(suggestions, { total: 25, page: 1, per_page: 20, total_pages: 2 })

      await waitFor(() => expect(screen.getAllByText("Showing 1–20 of 25").length).toBeGreaterThan(0))

      expect(screen.getAllByRole("button", { name: "Previous" }).every((button) => button.hasAttribute("disabled"))).toBe(true)
    })

    it("clicking Next re-fetches with page=2", async () => {
      const page1Suggestions = Array.from({ length: 20 }, (_, i) => makeSuggestion({ id: i + 1, title: `Admin Suggestion ${i + 1}` }))
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

      await waitFor(() => expect(screen.getAllByRole("button", { name: "Next" }).length).toBeGreaterThan(0))

      fireEvent.click(screen.getAllByRole("button", { name: "Next" })[0])

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("page=2"), expect.anything())
      })
    })

    it("uses smart folders instead of the old state tabs", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload([makeSuggestion()])))

      renderRoute()

      const dismissedFolder = await screen.findByRole("link", { name: /Dismissed/ })
      fireEvent.click(dismissedFolder)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("smart_folder_id=3"), expect.anything())
      })
      expect(screen.queryByRole("button", { name: /Dismissed/ })).not.toBeInTheDocument()
    })

    it("clicking a sortable table header re-fetches with sort params", async () => {
      const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload([makeSuggestion()])))

      renderRoute()

      fireEvent.click(await screen.findByRole("button", { name: "Repository" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("sort=repository"), expect.anything())
      })
    })

    it("keeps saved smart folder redirects on the admin insights route", async () => {
      const editedFilterPayload = payload([makeSuggestion()], makeMeta(), {
        filter: { and: [{ field: "severity", op: "is", value: "high" }] }
      })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.endsWith("/api/v1/app/smart_folders") && init?.method === "POST") {
          return Promise.resolve(
            jsonResponse({
              message: "Smart folder created.",
              redirect_to: "/agent_insights?smart_folder_id=42",
              smart_folder: {
                id: 42,
                name: "High severity",
                position: 0,
                kind: "user_defined",
                subject_type: "agent_insight",
                visibility: "always",
                count: 1,
                active: true,
                filter: { and: [{ field: "severity", op: "is", value: "high" }] },
                path: "/agent_insights?smart_folder_id=42"
              }
            })
          )
        }

        return Promise.resolve(jsonResponse(editedFilterPayload))
      })

      renderInsightsRoute()

      fireEvent.change(await screen.findByLabelText("Folder name"), { target: { value: "High severity" } })
      fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("/api/v1/app/admin/insights?smart_folder_id=42"), expect.anything())
      })
    })
  })

  describe("retired insight row", () => {
    it("shows the retirement reason and superseding insight when expanded", async () => {
      const retired = makeSuggestion({
        state: "retired",
        retired_reason: "Folded into a newer finding.",
        superseded_by_insight_id: 9
      })
      renderRoute([retired])

      fireEvent.click(await screen.findByRole("button", { name: "Cross-repo cache miss" }))

      expect(screen.getAllByText("Retired").length).toBeGreaterThanOrEqual(2)
      expect(screen.getByText("Folded into a newer finding.")).toBeInTheDocument()
      expect(screen.getByText("Superseded by insight #9")).toBeInTheDocument()
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
          return Promise.resolve(
            jsonResponse({
              message: "Memory removed and suggestion accepted.",
              suggestion: makeSuggestion({ ...removeMemory, state: "accepted" }),
              memory_id: 88
            })
          )
        }
        return Promise.resolve(jsonResponse(payload([removeMemory])))
      })

      renderRoute([removeMemory])

      fireEvent.click(await screen.findByRole("button", { name: "Cross-repo cache miss" }))
      expect(await screen.findByText("Remove memory #88")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Remove memory" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/insight_suggestions/1", expect.objectContaining({ method: "PATCH" }))
      })
    })
  })
})
