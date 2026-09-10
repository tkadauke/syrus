import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { AgentActivityFeed } from "./AgentActivityFeed"
import type { AgentActivitySession } from "../api/agentActivity"

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")

function filterSchema() {
  return [
    { field: "repository_id", label: "Repository", bucket: "fk", operators: [ "is" ], typeahead: true },
    { field: "job_id", label: "Job", bucket: "fk", operators: [ "is" ], typeahead: true },
    {
      field: "step_kind",
      label: "Role",
      bucket: "enum",
      operators: [ "is_one_of" ],
      values: [
        { value: "implement", label: "Implement" },
        { value: "adversarial_review", label: "Adversarial review" }
      ]
    },
    { field: "agent_provider", label: "Agent", bucket: "enum", operators: [ "is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset" ], values: [ "claude", "codex" ] },
    {
      field: "status",
      label: "Status",
      bucket: "enum",
      operators: [ "is", "is_one_of" ],
      values: [
        { value: "queued", label: "Queued" },
        { value: "running", label: "Running" },
        { value: "succeeded", label: "Succeeded" },
        { value: "failed", label: "Failed" }
      ]
    },
    { field: "window", label: "Time window", bucket: "date", operators: [ "within_last", "between" ] }
  ]
}

function session(overrides: Partial<AgentActivitySession> = {}): AgentActivitySession {
  return {
    id: 501,
    slug: "RUN-501",
    state: "running",
    step_kind: "implement",
    role: "workflow:implement",
    role_label: "Implement",
    agent_provider: "claude",
    agent_outcome: null,
    outcome_summary: null,
    outcome_verdict: null,
    started_at: "2026-01-01T00:10:00Z",
    finished_at: null,
    created_at: "2026-01-01T00:09:00Z",
    duration_seconds: 120,
    transcript_path: "/api/v1/app/jobs/42/runs/501/artifacts",
    job: { id: 42, slug: "JOB-42", title: "Fix the aqueducts", state: "running" },
    repository: { id: 1, slug: "acme/widgets" },
    workflow_id: 900,
    trigger_kind: "initial",
    ...overrides
  }
}

function sessionsPayload(overrides: Record<string, unknown> = {}) {
  return {
    sessions: [ session() ],
    total: 1,
    page: 1,
    per: 20,
    running_count: 1,
    filter: { and: [] },
    filter_schema: filterSchema(),
    active_smart_folder_id: null,
    smart_folders: [
      {
        id: 10,
        name: "All",
        i18n_key: "agent_activity_all",
        position: 0,
        kind: "builtin",
        subject_type: "agent_session",
        visibility: "always",
        count: 1,
        active: false,
        filter: { and: [] },
        path: "/agent_activity?smart_folder_id=10"
      },
      {
        id: 11,
        name: "Running",
        i18n_key: "agent_activity_running",
        position: 1,
        kind: "builtin",
        subject_type: "agent_session",
        visibility: "always",
        count: 1,
        active: false,
        filter: { and: [ { field: "status", op: "is", value: "running" } ] },
        path: "/agent_activity?smart_folder_id=11"
      }
    ],
    ...overrides
  }
}

function decodeQ(url: string) {
  const q = new URL(url, "http://example.test").searchParams.get("q")
  if (!q) return null

  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

function setupFetchMock(sessionsOverrides: Record<string, unknown> = {}) {
  const calls: string[] = []

  vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)

    if (url.startsWith("/api/v1/app/agent_activity/sessions") || url.startsWith("/api/v1/app/admin/agent_activity/sessions") && !url.includes("/artifacts")) {
      return Promise.resolve(jsonResponse(sessionsPayload({ filter: decodeQ(url) || { and: [] }, ...sessionsOverrides })))
    }
    if (url.includes("/artifacts")) {
      return Promise.resolve(jsonResponse({
        job_id: 42,
        workflow_id: 900,
        run_id: 501,
        base_ref: "abc",
        head_ref: "def",
        agent_diff: null,
        agent_diff_bytes: 0,
        logs_count: 1,
        logs: [ { id: 1, sequence: 1, kind: "assistant_text", chunk: "Looked at the aqueducts.", created_at: "2026-01-01T00:10:00Z" } ]
      }))
    }
    if (url === "/api/v1/app/filters/usage") {
      return Promise.resolve(jsonResponse({ recorded: true }))
    }
    if (url.startsWith("/api/v1/app/filters/suggestions")) {
      return Promise.resolve(jsonResponse({ suggestions: [] }))
    }

    return Promise.reject(new Error(`Unexpected fetch: ${url}`))
  }) as typeof window.fetch)

  return calls
}

function renderFeed(scope: "mine" | "admin" = "mine", initialPath = "/agent_activity") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[ initialPath ]}>
          <AgentActivityFeed scope={scope} />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("AgentActivityFeed", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia)
    else Reflect.deleteProperty(window, "matchMedia")
  })

  it("renders the job slug as a copyable slug with hover-card wiring", async () => {
    const clipboardWrite = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText: clipboardWrite } })
    setupFetchMock()
    renderFeed()

    const copyButton = await screen.findByRole("button", { name: "Copy JOB-42 to clipboard" })
    expect(screen.queryByRole("link", { name: "JOB-42" })).not.toBeInTheDocument()
    expect(copyButton.parentElement?.tagName).toBe("SPAN")

    fireEvent.click(copyButton)

    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-42"))
  })

  it("renders a session card headlined by its submitted outcome summary", async () => {
    setupFetchMock({ sessions: [ session({ outcome_summary: "Added the greeting helper.", role_label: "Implement" }) ] })
    renderFeed()

    expect(await screen.findByText("Added the greeting helper.")).toBeInTheDocument()
    expect(screen.getByText("Implement")).toBeInTheDocument()
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
    expect(screen.getByText("acme/widgets")).toBeInTheDocument()
  })

  it("falls back to a 'no summary submitted' placeholder when the session submitted nothing", async () => {
    setupFetchMock({ sessions: [ session({ outcome_summary: null }) ] })
    renderFeed()

    expect(await screen.findByText("No summary submitted for this session.")).toBeInTheDocument()
  })

  it("shows a pulsing running-now indicator when sessions are running", async () => {
    setupFetchMock({ running_count: 3 })
    renderFeed()

    expect(await screen.findByText("3 running now")).toBeInTheDocument()
  })

  it("does not show the running-now indicator when nothing is running", async () => {
    setupFetchMock({ running_count: 0 })
    renderFeed()

    await screen.findByText("Fix the aqueducts")
    expect(screen.queryByTestId("running-now-indicator")).not.toBeInTheDocument()
  })

  it("shows the empty state when there are no sessions", async () => {
    setupFetchMock({ sessions: [], total: 0, running_count: 0 })
    renderFeed()

    expect(await screen.findByText("No agent sessions match this filter.")).toBeInTheDocument()
  })

  it("leaves folder navigation to the app sidebar for the operator-scoped feed", async () => {
    setupFetchMock()
    renderFeed()

    await screen.findByText("Fix the aqueducts")
    expect(screen.queryByRole("navigation", { name: "Agent Activity smart folders" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Running now" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Needs work" })).not.toBeInTheDocument()
  })

  it("renders operator SmartFolders inside the mobile folders disclosure", async () => {
    mockDesktopViewport(false)
    setupFetchMock()
    renderFeed()

    fireEvent.click(await screen.findByText("Folders and filters"))

    expect(screen.getByRole("navigation", { name: "Agent Activity smart folders" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Running 1" })).toHaveAttribute("href", "/agent_activity?smart_folder_id=11")
  })

  it("renders the admin SmartFolder column inline", async () => {
    setupFetchMock({
      active_smart_folder_id: 11,
      smart_folders: [
        {
          id: 10,
          name: "All",
          i18n_key: "agent_activity_all",
          position: 0,
          kind: "builtin",
          subject_type: "agent_session",
          visibility: "always",
          count: 2,
          active: false,
          filter: { and: [] },
          path: "/admin/agent_activity?smart_folder_id=10"
        },
        {
          id: 11,
          name: "Running",
          i18n_key: "agent_activity_running",
          position: 1,
          kind: "builtin",
          subject_type: "agent_session",
          visibility: "always",
          count: 1,
          active: true,
          filter: { and: [ { field: "status", op: "is", value: "running" } ] },
          path: "/admin/agent_activity?smart_folder_id=11"
        }
      ]
    })
    renderFeed("admin", "/admin/agent_activity?smart_folder_id=11")

    expect(await screen.findByRole("navigation", { name: "Agent Activity smart folders" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "All history" })).toHaveAttribute("href", "/admin/agent_activity?smart_folder_id=")
    expect(await screen.findByRole("link", { name: "Running 1" })).toHaveAttribute("href", "/admin/agent_activity?smart_folder_id=11")
  })

  it("lets admins save an adjusted Agent Activity filter as a SmartFolder", async () => {
    setupFetchMock({
      active_smart_folder_id: 11,
      filter: {
        and: [
          { field: "status", op: "is", value: "running" },
          { field: "agent_provider", op: "is", value: "codex" }
        ]
      },
      smart_folders: [
        {
          id: 11,
          name: "Running",
          i18n_key: "agent_activity_running",
          position: 1,
          kind: "builtin",
          subject_type: "agent_session",
          visibility: "always",
          count: 1,
          active: true,
          filter: { and: [ { field: "status", op: "is", value: "running" } ] },
          path: "/admin/agent_activity?smart_folder_id=11"
        }
      ]
    })
    renderFeed("admin", "/admin/agent_activity?smart_folder_id=11")

    expect(await screen.findByLabelText("Folder name")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
  })

  it("opens a transcript drawer reusing the shared transcript log renderer when a card is expanded", async () => {
    setupFetchMock()
    renderFeed()

    await screen.findByText("Fix the aqueducts")
    fireEvent.click(screen.getByText("Transcript"))

    expect(await screen.findByText("Looked at the aqueducts.")).toBeInTheDocument()
  })

  it("shows an adversarial_review session's verdict pill alongside its critique", async () => {
    setupFetchMock({
      sessions: [ session({ step_kind: "adversarial_review", role_label: "Adversarial review", outcome_summary: "Missing a test.", outcome_verdict: "needs_work" }) ]
    })
    renderFeed()

    expect(await screen.findByText("Missing a test.")).toBeInTheDocument()
    expect(screen.getByText("needs_work")).toBeInTheDocument()
  })

  it("fetches from the admin sessions endpoint when scope is admin", async () => {
    const calls = setupFetchMock()
    renderFeed("admin", "/admin/agent_activity")

    await waitFor(() => {
      expect(calls.some((url) => url.startsWith("/api/v1/app/admin/agent_activity/sessions"))).toBe(true)
    })
  })

  it("requests and renders paginated sessions at 20 per page", async () => {
    const pageSessions = Array.from({ length: 20 }, (_, index) => session({
      id: 501 + index,
      job: { id: 42 + index, slug: `JOB-${42 + index}`, title: `Session ${index + 1}`, state: "running" }
    }))
    const calls = setupFetchMock({ total: 21, per: 20, sessions: pageSessions })
    renderFeed()

    expect(await screen.findByText("Showing 1-20 of 21")).toBeInTheDocument()
    expect(screen.getByText("Page 1 of 2")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/agent_activity?page=2&per=20")
    expect(calls[0]).toBe("/api/v1/app/agent_activity/sessions?per=20")
  })

  it("preserves the filter query when paging", async () => {
    const q = "eyJhbmQiOltdfQ"
    setupFetchMock({ total: 21, page: 2, per: 20 })
    renderFeed("mine", `/agent_activity?q=${q}&page=2`)

    expect(await screen.findByText("Page 2 of 2")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous" })).toHaveAttribute("href", `/agent_activity?q=${q}&page=1&per=20`)
  })
})

function mockDesktopViewport(matches: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}
