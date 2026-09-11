import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryInsightsRoute } from "./RepositoryInsights"
import * as useConfirmModule from "@app/hooks/useConfirm"
import i18n from "@app/i18n"

function makeSuggestion(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    slug: "INSIGHT-1",
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
    retired_reason: null,
    superseded_by_insight_id: null,
    superseded_by_job_id: null,
    evidence: [],
    job_slug: "JOB-100",
    job_path: "/jobs/100",
    accepted_at: null,
    dismissed_at: null,
    retired_at: null,
    created_at: "2026-07-01T00:00:00Z",
    created_job: null,
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

function makeCounts(suggestions: unknown[]) {
  const counts = { pending: 0, accepted: 0, dismissed: 0, retired: 0, all: suggestions.length }
  suggestions.forEach((suggestion) => {
    const state = (suggestion as { state?: string }).state
    if (state === "pending" || state === "accepted" || state === "dismissed" || state === "retired") counts[state] += 1
  })
  return counts
}

function smartFolders(counts = { pending: 1, accepted: 0, dismissed: 0, retired: 0, all: 1 }, activeId: number | null = 11) {
  return [
    { id: 11, name: "Pending", i18n_key: "agent_insights_pending", position: 0, kind: "builtin", subject_type: "agent_insight", visibility: "always", count: counts.pending, active: activeId === 11, filter: { and: [{ field: "state", op: "is", value: "pending" }] }, path: "/repositories/1/plugin/insights?smart_folder_id=11" },
    { id: 12, name: "Accepted", i18n_key: "agent_insights_accepted", position: 1, kind: "builtin", subject_type: "agent_insight", visibility: "always", count: counts.accepted, active: activeId === 12, filter: { and: [{ field: "state", op: "is", value: "accepted" }] }, path: "/repositories/1/plugin/insights?smart_folder_id=12" },
    { id: 13, name: "Dismissed", i18n_key: "agent_insights_dismissed", position: 2, kind: "builtin", subject_type: "agent_insight", visibility: "always", count: counts.dismissed, active: activeId === 13, filter: { and: [{ field: "state", op: "is", value: "dismissed" }] }, path: "/repositories/1/plugin/insights?smart_folder_id=13" },
    { id: 14, name: "Retired", i18n_key: "agent_insights_retired", position: 3, kind: "builtin", subject_type: "agent_insight", visibility: "always", count: counts.retired, active: activeId === 14, filter: { and: [{ field: "state", op: "is", value: "retired" }] }, path: "/repositories/1/plugin/insights?smart_folder_id=14" }
  ]
}

function filterSchema() {
  return [
    { field: "created_at", label: "Created", bucket: "date", operators: ["before", "after", "between", "within_last", "more_than_ago"], values: [], date_precision: "datetime" },
    { field: "state", label: "State", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"], values: [{ value: "pending", label: "pending" }, { value: "accepted", label: "accepted" }, { value: "dismissed", label: "dismissed" }, { value: "retired", label: "retired" }] },
    { field: "severity", label: "Severity", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"], values: [{ value: "high", label: "high" }, { value: "medium", label: "medium" }, { value: "low", label: "low" }] },
    { field: "proposal_type", label: "Proposal type", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"], values: [{ value: "create_job", label: "create_job" }] },
    { field: "category", label: "Category", bucket: "string", operators: ["contains", "equals"], values: [] },
    { field: "confidence", label: "Confidence", bucket: "number", operators: ["equals", "greater_than", "less_than", "between"], values: [] },
    { field: "created_job_present", label: "Created job", bucket: "boolean", operators: ["is_true", "is_false"], values: [] }
  ]
}

function payload(suggestions: unknown[] = [makeSuggestion()], meta = makeMeta({ total: suggestions.length }), counts = makeCounts(suggestions)) {
  const activeId = meta.state === "accepted" ? 12 : meta.state === "dismissed" ? 13 : meta.state === "retired" ? 14 : meta.state === "all" ? null : 11
  return {
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1", insights_path: "/repositories/1/plugin/insights" },
    tabs: [],
    counts,
    filter: { and: activeId ? [smartFolders(counts, activeId).find((folder) => folder.id === activeId)?.filter?.and?.[0]] : [] },
    filter_schema: filterSchema(),
    active_smart_folder_id: activeId,
    smart_folders: smartFolders(counts, activeId),
    suggestions,
    meta
  }
}

function renderRoute(suggestions?: unknown[], meta?: Record<string, unknown>) {
  if (!vi.isMockFunction(window.fetch)) {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload(suggestions, meta ? makeMeta(meta) : undefined)))
  }
  renderRepositoryInsightsRoute()
}

function renderRouteByState(responses: Partial<Record<StateFilter, { suggestions: unknown[]; meta?: Record<string, unknown>; counts?: Record<StateFilter, number> }>>) {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = new URL(String(input), "http://example.test")
    const folderState: Record<string, StateFilter> = { "11": "pending", "12": "accepted", "13": "dismissed", "14": "retired" }
    const state = (folderState[url.searchParams.get("smart_folder_id") || "11"] || "all") as StateFilter
    const response = responses[state] || responses.all || responses.pending || { suggestions: [] }
    return Promise.resolve(jsonResponse(payload(
      response.suggestions,
      response.meta ? makeMeta({ state, ...response.meta }) : makeMeta({ total: response.suggestions.length, state }),
      response.counts || makeCounts(response.suggestions)
    )))
  })
  renderRepositoryInsightsRoute()
}

function renderRepositoryInsightsRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories/1/plugin/insights"]}>
          <Routes>
            <Route element={<RepositoryInsightsRoute />} path="/app-shell/repositories/:repositoryId/plugin/insights" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

type StateFilter = "pending" | "accepted" | "dismissed" | "retired" | "all"

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}{location.search}</div>
}

function decodedFilterFromLocation() {
  const location = screen.getByTestId("location").textContent || ""
  const query = location.split("?")[1] || ""
  const q = new URLSearchParams(query).get("q")
  if (!q) return null

  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

describe("RepositoryInsightsRoute", () => {
  afterEach(async () => {
    cleanup()
    vi.useRealTimers()
    await i18n.changeLanguage("en")
    vi.restoreAllMocks()
  })

  it("shows insight age next to confidence in suggestion headers", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-06-25T12:00:00Z"))

    renderRoute([
      makeSuggestion({
        title: "Trim repeated setup retries",
        category: "workflow",
        severity: "medium",
        confidence: 0.4,
        suggested_prompt: null,
        memory_suggestion: null,
        has_memory_suggestion: false,
        created_at: "2026-06-25T10:00:00Z"
      })
    ])

    expect(await screen.findByRole("heading", { level: 3, name: "Trim repeated setup retries" })).toBeInTheDocument()
    const confidence = screen.getByText(/40% confidence/)
    expect(within(confidence).getByText("2 hours ago")).toHaveAttribute("dateTime", "2026-06-25T10:00:00Z")
  })

  it("renders a copyable insight slug on suggestion cards", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    })

    renderRoute()

    const copyButton = await screen.findByRole("button", { name: "Copy INSIGHT-1 to clipboard" })
    expect(copyButton).toHaveTextContent("INSIGHT-1")

    fireEvent.click(copyButton)

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("INSIGHT-1")
    })
  })

  it("submits created date filters through the URL and clears pagination", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/repositories/1/plugin/insights?page=3"]}>
            <Routes>
              <Route element={<><RepositoryInsightsRoute /><LocationProbe /></>} path="/app-shell/repositories/:repositoryId/plugin/insights" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      </I18nextProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Created date" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual(expect.objectContaining({
        and: expect.arrayContaining([expect.objectContaining({ field: "created_at" })])
      }))
      expect(screen.getByTestId("location")).not.toHaveTextContent("page=3")
    })
  })

  it("rewrites saved smart-folder redirects back to the repository plugin insights route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = new URL(String(input), "http://example.test")
      const method = init?.method
      if (url.pathname === "/api/v1/app/smart_folders" && method === "POST") {
        return Promise.resolve(jsonResponse({
          redirect_to: "/agent_insights?smart_folder_id=22",
          smart_folder: { id: 22, name: "High confidence", path: "/agent_insights?smart_folder_id=22" }
        }))
      }
      return Promise.resolve(jsonResponse({
        ...payload(),
        active_smart_folder_id: null,
        filter: { and: [{ field: "severity", op: "is", value: "high" }] }
      }))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <MemoryRouter initialEntries={["/app-shell/repositories/1/plugin/insights?q=severity"]}>
            <Routes>
              <Route element={<><RepositoryInsightsRoute /><LocationProbe /></>} path="/app-shell/repositories/:repositoryId/plugin/insights" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      </I18nextProvider>
    )

    fireEvent.change(await screen.findByLabelText(/Folder name/), { target: { value: "High confidence" } })
    fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/smart_folders",
        expect.objectContaining({ method: "POST" })
      )
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/repositories/1/plugin/insights?smart_folder_id=22")
    })
  })

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
      renderRouteByState({
        pending: { suggestions: [] },
        accepted: { suggestions: [accepted] }
      })

      // switch to Accepted tab
      const acceptedTab = await screen.findByRole("link", { name: /Accepted/ })
      fireEvent.click(acceptedTab)

      const link = await screen.findByRole("link", { name: "JOB-42" })
      expect(link).toHaveAttribute("href", "/jobs/42")
    })
  })

  describe("smart folders", () => {
    it("supports changing state through smart-folder links", async () => {
      const dismissed = makeSuggestion({ state: "dismissed" })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = new URL(String(input), "http://example.test")
        const selectedDismissed = url.searchParams.get("smart_folder_id") === "13"
        return Promise.resolve(jsonResponse(payload(
          selectedDismissed ? [dismissed] : [],
          makeMeta({ state: selectedDismissed ? "dismissed" : "pending", total: selectedDismissed ? 1 : 0 })
        )))
      })

      renderRepositoryInsightsRoute()

      const dismissedFolder = await screen.findByRole("link", { name: /Dismissed/ })
      expect(dismissedFolder).toHaveAttribute("href", "/app-shell/repositories/1/plugin/insights?smart_folder_id=13")
      fireEvent.click(dismissedFolder)

      await screen.findByText("Frequent prepare failures")
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          expect.stringContaining("smart_folder_id=13"),
          expect.anything()
        )
      })
    })
  })

  describe("independent memory save", () => {
    it("does not show the create-job accept action for pending memory-only suggestions", async () => {
      renderRoute([
        makeSuggestion({
          proposal_type: "save_memory",
          suggested_prompt: null,
          memory_suggestion: "Always check the logs first",
          has_memory_suggestion: true
        })
      ])

      expect(await screen.findByText("Frequent prepare failures")).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Save as memory" })).toBeInTheDocument()
    })

    it("shows Save as memory button on accepted cards with a memory suggestion", async () => {
      const accepted = makeSuggestion({
        state: "accepted",
        has_memory_suggestion: true
      })
      renderRouteByState({
        pending: { suggestions: [] },
        accepted: { suggestions: [accepted] }
      })

      const acceptedTab = await screen.findByRole("link", { name: /Accepted/ })
      fireEvent.click(acceptedTab)

      expect(await screen.findByRole("button", { name: "Save as memory" })).toBeInTheDocument()
    })

    it("does not show Save as memory button on accepted cards without a memory suggestion", async () => {
      const accepted = makeSuggestion({
        state: "accepted",
        has_memory_suggestion: false,
        memory_suggestion: null
      })
      renderRouteByState({
        pending: { suggestions: [] },
        accepted: { suggestions: [accepted] }
      })

      const acceptedTab = await screen.findByRole("link", { name: /Accepted/ })
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

  describe("discussion chat", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("renders a Discuss in new chat button for every proposal type", async () => {
      renderRoute([
        makeSuggestion({ id: 1, title: "Create job", proposal_type: "create_job" }),
        makeSuggestion({ id: 2, title: "Save memory", proposal_type: "save_memory" }),
        makeSuggestion({ id: 3, title: "Remove memory", proposal_type: "remove_memory" }),
        makeSuggestion({ id: 4, title: "Revise insight", proposal_type: "revise_existing_insight" }),
        makeSuggestion({ id: 5, title: "Informational", proposal_type: "informational" })
      ])

      expect(await screen.findByText("Create job")).toBeInTheDocument()
      expect(screen.getAllByRole("button", { name: "Discuss in new chat" })).toHaveLength(5)
    })

    it("opens the returned chat path in a new tab after creating the discussion chat", async () => {
      const openSpy = vi.spyOn(window, "open").mockReturnValue(null)
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const url = String(input)
        if (url.endsWith("/api/v1/app/insight_suggestions/1/discuss") && init?.method === "POST") {
          return Promise.resolve(jsonResponse({ redirect_to: "/chats/42" }))
        }
        return Promise.resolve(jsonResponse(payload()))
      })

      renderRoute()
      fireEvent.click(await screen.findByRole("button", { name: "Discuss in new chat" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/insight_suggestions/1/discuss",
          expect.objectContaining({ method: "POST" })
        )
      })
      expect(openSpy).toHaveBeenCalledWith("/chats/42", "_blank")
    })
  })

  describe("legacy revise-insight proposals", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("renders legacy revise rows as context without a normal accept action", async () => {
      const legacy = makeSuggestion({
        title: "Revise old insight",
        proposal_type: "revise_existing_insight",
        target_insight_id: 55,
        suggested_prompt: null,
        memory_suggestion: null,
        has_memory_suggestion: false
      })

      renderRoute([legacy])

      expect(await screen.findByText("Revise old insight")).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Discuss in new chat" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Dismiss" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Expand" }))

      expect(screen.getByText("Legacy revision suggestion")).toBeInTheDocument()
      expect(screen.getByText(/insight #55/)).toBeInTheDocument()
    })
  })

  describe("evidence table", () => {
    beforeEach(() => {
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn() as any, dialog: <></> })
    })

    it("does not render evidence links in the card header", async () => {
      renderRoute([
        makeSuggestion({
          evidence: [
            { job_id: 42, run_id: 7, kind: "prepare_failure", job_path: "/jobs/42", run_transcript_path: "/admin/runs/7/transcript" }
          ]
        })
      ])

      await screen.findByText("Frequent prepare failures")
      expect(screen.queryByRole("link", { name: "#42" })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "transcript" })).not.toBeInTheDocument()
    })

    it("shows an Evidence toggle inside the expanded card but not the table yet", async () => {
      renderRoute([
        makeSuggestion({
          evidence: [
            { job_id: 42, run_id: 7, kind: "prepare_failure", job_path: "/jobs/42", run_transcript_path: "/admin/runs/7/transcript" }
          ]
        })
      ])

      await screen.findByText("Frequent prepare failures")
      expect(screen.queryByRole("button", { name: /Evidence/ })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Expand" }))

      expect(screen.getByRole("button", { name: "Evidence (1)" })).toBeInTheDocument()
      expect(screen.queryByRole("columnheader", { name: "Job" })).not.toBeInTheDocument()
    })

    it("reveals the evidence table with job, finding, and transcript columns on second expand", async () => {
      renderRoute([
        makeSuggestion({
          evidence: [
            { job_id: 42, run_id: 7, kind: "prepare_failure", job_path: "/jobs/42", run_transcript_path: "/admin/runs/7/transcript" }
          ]
        })
      ])

      fireEvent.click(await screen.findByRole("button", { name: "Expand" }))
      fireEvent.click(screen.getByRole("button", { name: "Evidence (1)" }))

      expect(screen.getByRole("columnheader", { name: "Job" })).toBeInTheDocument()
      expect(screen.getByRole("columnheader", { name: "Finding" })).toBeInTheDocument()
      expect(screen.getByRole("columnheader", { name: "Transcript" })).toBeInTheDocument()

      const jobLink = screen.getByRole("link", { name: "#42" })
      expect(jobLink).toHaveAttribute("href", "/jobs/42")

      expect(screen.getByText("prepare_failure")).toBeInTheDocument()

      const transcriptLink = screen.getByRole("link", { name: "transcript" })
      expect(transcriptLink).toHaveAttribute("href", "/admin/runs/7/transcript")
    })

    it("collapses the evidence table when the card is collapsed", async () => {
      renderRoute([
        makeSuggestion({
          evidence: [
            { job_id: 42, run_id: 7, kind: "prepare_failure", job_path: "/jobs/42", run_transcript_path: "/admin/runs/7/transcript" }
          ]
        })
      ])

      fireEvent.click(await screen.findByRole("button", { name: "Expand" }))
      fireEvent.click(screen.getByRole("button", { name: "Evidence (1)" }))
      expect(screen.getByRole("columnheader", { name: "Job" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Collapse" }))
      expect(screen.queryByRole("columnheader", { name: "Job" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Expand" }))
      expect(screen.queryByRole("columnheader", { name: "Job" })).not.toBeInTheDocument()
    })

    it("handles evidence items without a job or transcript gracefully", async () => {
      renderRoute([
        makeSuggestion({
          evidence: [
            { job_id: null, run_id: null, kind: "anomaly detected", job_path: null, run_transcript_path: null }
          ]
        })
      ])

      fireEvent.click(await screen.findByRole("button", { name: "Expand" }))
      fireEvent.click(screen.getByRole("button", { name: "Evidence (1)" }))

      expect(screen.getByText("anomaly detected")).toBeInTheDocument()
      expect(screen.getAllByText("—").length).toBeGreaterThanOrEqual(2)
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
      renderRouteByState({
        pending: { suggestions: [] },
        dismissed: { suggestions: [dismissed] }
      })

      const dismissedTab = await screen.findByRole("link", { name: /Dismissed/ })
      fireEvent.click(dismissedTab)

      expect(await screen.findByRole("button", { name: "Undismiss" })).toBeInTheDocument()
    })

    it("fires the undismiss API when Undismiss is clicked", async () => {
      const dismissed = makeSuggestion({ state: "dismissed" })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const request = typeof Request !== "undefined" && input instanceof Request ? input : null
        const url = request?.url || String(input)
        const method = init?.method || request?.method
        if (url.includes("/insight_suggestions/1") && method === "PATCH") {
          return Promise.resolve(jsonResponse({ message: "Suggestion restored to pending.", suggestion: makeSuggestion({ state: "pending" }) }))
        }
        const selectedDismissed = new URL(url, "http://example.test").searchParams.get("smart_folder_id") === "13"
        return Promise.resolve(jsonResponse(payload(
          selectedDismissed ? [dismissed] : [],
          makeMeta({ state: selectedDismissed ? "dismissed" : "pending", total: selectedDismissed ? 1 : 0 })
        )))
      })

      renderRepositoryInsightsRoute()

      const dismissedTab = await screen.findByRole("link", { name: /Dismissed/ })
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

  describe("retired insights", () => {
    it("shows a Retired folder and switching to it fetches that folder", async () => {
      const retired = makeSuggestion({
        state: "retired",
        retired_reason: "Folded into a newer finding.",
        superseded_by_insight_id: 7
      })
      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = new URL(String(input), "http://example.test")
        const selectedRetired = url.searchParams.get("smart_folder_id") === "14"
        return Promise.resolve(jsonResponse(payload(
          selectedRetired ? [retired] : [],
          makeMeta({ state: selectedRetired ? "retired" : "pending", total: selectedRetired ? 1 : 0 })
        )))
      })

      renderRepositoryInsightsRoute()

      const retiredTab = await screen.findByRole("link", { name: /Retired/ })
      fireEvent.click(retiredTab)

      await screen.findByText("Frequent prepare failures")
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          expect.stringContaining("smart_folder_id=14"),
          expect.anything()
        )
      })
    })

    it("shows the retirement reason and superseding insight but no action buttons when expanded", async () => {
      const retired = makeSuggestion({
        state: "retired",
        retired_reason: "Folded into a newer finding.",
        superseded_by_insight_id: 7
      })
      renderRouteByState({
        pending: { suggestions: [] },
        retired: { suggestions: [retired] }
      })

      fireEvent.click(await screen.findByRole("link", { name: /Retired/ }))
      fireEvent.click(await screen.findByRole("button", { name: "Expand" }))

      expect(screen.getAllByText("Retired").length).toBeGreaterThanOrEqual(2)
      expect(screen.getByText("Folded into a newer finding.")).toBeInTheDocument()
      expect(screen.getByText("Superseded by insight #7")).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Dismiss" })).not.toBeInTheDocument()
    })
  })

  describe("pagination controls", () => {
    it("does not render pagination when total_pages is 1", async () => {
      renderRoute([makeSuggestion()], makeMeta({ total: 1, total_pages: 1 }))

      await screen.findByText("Frequent prepare failures")

      expect(screen.queryByRole("link", { name: "Next" })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "Previous" })).not.toBeInTheDocument()
    })

    it("renders pagination controls when total_pages > 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, makeMeta({ total: 25, page: 1, per_page: 20, total_pages: 2 }))

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.getByRole("link", { name: "Next" })).toBeInTheDocument()
    })

    it("Previous is disabled (not a button) on page 1", async () => {
      const suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      renderRoute(suggestions, makeMeta({ total: 25, page: 1, per_page: 20, total_pages: 2 }))

      await screen.findByText("Showing 1–20 of 25")

      expect(screen.queryByRole("link", { name: "Previous" })).not.toBeInTheDocument()
      expect(screen.getByText("Previous")).toBeInTheDocument()
    })

    it("links Next to the same repository plugin route with page=2", async () => {
      const page1Suggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Suggestion ${i + 1}` })
      )
      renderRoute(page1Suggestions, { total: 21, page: 1, per_page: 20, total_pages: 2 })

      const nextLink = await screen.findByRole("link", { name: "Next" })
      expect(nextLink).toHaveAttribute("href", "/app-shell/repositories/1/plugin/insights?page=2")
    })

    it("fetches and paginates the selected state tab", async () => {
      const pendingSuggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 1, title: `Pending ${i + 1}`, state: "pending" })
      )
      const acceptedSuggestions = Array.from({ length: 20 }, (_, i) =>
        makeSuggestion({ id: i + 101, title: `Accepted ${i + 1}`, state: "accepted" })
      )
      const counts = { pending: 20, accepted: 25, dismissed: 2, retired: 0, all: 47 }

      const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = String(input)
        if (url.includes("smart_folder_id=12")) {
          return Promise.resolve(jsonResponse(payload(acceptedSuggestions, makeMeta({ total: 25, page: 1, per_page: 20, total_pages: 2 }), counts)))
        }
        return Promise.resolve(jsonResponse(payload(pendingSuggestions, makeMeta({ total: 20, page: 1, per_page: 20, total_pages: 1 }), counts)))
      })

      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      render(
        <I18nextProvider i18n={i18n}>
          <QueryClientProvider client={client}>
            <MemoryRouter initialEntries={["/app-shell/repositories/1/plugin/insights"]}>
              <Routes>
                <Route element={<RepositoryInsightsRoute />} path="/app-shell/repositories/:repositoryId/plugin/insights" />
              </Routes>
            </MemoryRouter>
          </QueryClientProvider>
        </I18nextProvider>
      )

      await screen.findByText("Pending 1")
      expect(screen.queryByRole("link", { name: "Next" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("link", { name: /Accepted/ }))

      await screen.findByText("Accepted 1")
      expect(screen.getByText("Showing 1–20 of 25")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Next" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.stringContaining("smart_folder_id=12"),
        expect.anything()
      )
    })
  })
})
