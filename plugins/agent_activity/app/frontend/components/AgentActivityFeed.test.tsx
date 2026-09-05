import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { AgentActivityFeed } from "./AgentActivityFeed"
import type { AgentActivitySession } from "../api/agentActivity"

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
      operators: [ "is_one_of" ],
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
    per: 25,
    running_count: 1,
    filter: { and: [] },
    filter_schema: filterSchema(),
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

  it("applies the 'Running now' quick filter as a status=running chip", async () => {
    const calls = setupFetchMock()
    renderFeed()

    await screen.findByText("Fix the aqueducts")
    fireEvent.click(screen.getByRole("button", { name: "Running now" }))

    await waitFor(() => {
      const last = calls.filter((url) => url.includes("q=")).at(-1)
      expect(last && decodeQ(last)).toEqual({ and: [ { field: "status", op: "is_one_of", value: [ "running" ] } ] })
    })
  })

  it("applies the 'Needs work' quick filter as a status=failed chip", async () => {
    const calls = setupFetchMock()
    renderFeed()

    await screen.findByText("Fix the aqueducts")
    fireEvent.click(screen.getByRole("button", { name: "Needs work" }))

    await waitFor(() => {
      const last = calls.filter((url) => url.includes("q=")).at(-1)
      expect(last && decodeQ(last)).toEqual({ and: [ { field: "status", op: "is_one_of", value: [ "failed" ] } ] })
    })
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
})
