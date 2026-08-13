import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach } from "vitest"
import { RepositoryFormRoute } from "./RepositoryForm"

function editPayload(overrides: Record<string, unknown> = {}) {
  return {
    repository: {
      id: 1,
      owner: "acme",
      name: "widgets",
      slug: "acme/widgets",
      default_branch: "main",
      upstream_owner: "",
      upstream_name: "",
      upstream_default_branch: "",
      trigger_label: "syrus",
      polling_enabled: true,
      prepare_enabled: true,
      pr_cost_footer_enabled: true,
      auto_merge_enabled: false,
      trust_clean_rebase_grade: false,
      main_branch_health_enabled: false,
      main_branch_repair_enabled: false,
      main_branch_repair_auto_approve: false,
      treat_grader_timeouts_as_failures: true,
      fork_syncable: false,
      fork_auto_sync_enabled: false,
      external_pr_ingestion_enabled: false,
      agent_provider: "",
      auto_approve_mode: "manual",
      feedback_policy: "confirm",
      epic_dependency_policy: "linear",
      github_owner_id: null,
      github_repository_id: null,
      repository_path: "/repositories/1"
    },
    configured_agent_providers: [],
    user_agent_provider_label: "Claude",
    input_source_types: [
      {
        type: "InputSources::Linear",
        type_key: "linear",
        label: "Linear",
        schema: [
          { key: "api_key", type: "password", required: true, label: "API key", scope: "credentials" },
          { key: "team_id", type: "linear_team", required: true, label: "Team", scope: "config", depends_on: "api_key" },
          { key: "label_filter", type: "string", required: false, label: "Label filter", scope: "config" }
        ],
        source: null,
        path: "/api/v1/app/repositories/1/input_sources/linear"
      }
    ],
    auto_approve_modes: [
      { value: "manual", label: "Manual", preview: "Nothing auto-approves." }
    ],
    repositories_path: "/repositories",
    ...overrides
  }
}

function mockFetch(repositoryOverrides: Record<string, unknown> = {}) {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const url = String(input)
    const method = init?.method || "GET"

    if (url === "/api/v1/app/repositories/1/edit") {
      return Promise.resolve(jsonResponse(editPayload({ repository: { ...editPayload().repository, ...repositoryOverrides } })))
    }
    if (url === "/api/v1/app/repositories/owners") {
      return Promise.resolve(jsonResponse({ error: "no_token" }))
    }
    if (url === "/api/v1/app/repositories/1/input_sources/linear" && method === "GET") {
      return Promise.resolve(jsonResponse({ input_source: null }))
    }
    if (url === "/api/v1/app/repositories/1" && method === "PATCH") {
      return Promise.resolve(jsonResponse({
        message: "Saved.",
        redirect_to: "/repositories/1",
        repository: { id: 1 },
        credential_status: { mode: "app" }
      }))
    }
    if (url === "/api/v1/app/repositories/1/input_sources/linear" && method === "PATCH") {
      return Promise.resolve(jsonResponse({
        input_source: { id: 5, type: "InputSources::Linear", type_key: "linear", label: "Linear", polling_enabled: false, values: {}, last_poll_started_at: null, issues_ingested_count: 0 },
        message: "Linear settings saved."
      }))
    }

    return Promise.resolve(jsonResponse({}))
  })
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/repositories/1/edit"]}>
        <Routes>
          <Route element={<RepositoryFormRoute mode="edit" />} path="/repositories/:id/edit" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryForm plugin input-source decoupling", () => {
  afterEach(() => vi.restoreAllMocks())

  it("saves core repository settings even when a plugin's required fields are empty", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("heading", { name: "Linear" })

    const saveButton = screen.getByRole("button", { name: "Save Repository" })
    fireEvent.click(saveButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1",
        expect.objectContaining({ method: "PATCH" })
      )
    })
  })

  it("still saves the plugin section independently via its own button, without touching core settings", async () => {
    const fetchSpy = mockFetch()
    renderRoute()

    await screen.findByRole("heading", { name: "Linear" })

    fireEvent.change(screen.getByLabelText("API key"), { target: { value: "shh-secret" } })

    const linearSaveButton = screen.getByRole("button", { name: "Save Linear settings" })
    fireEvent.click(linearSaveButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/input_sources/linear",
        expect.objectContaining({ method: "PATCH" })
      )
    })

    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/repositories/1",
      expect.objectContaining({ method: "PATCH" })
    )
  })
})

describe("RepositoryForm Epic dependency policy field", () => {
  afterEach(() => vi.restoreAllMocks())

  it("only offers Linear as a selectable dependency policy", async () => {
    mockFetch()
    renderRoute()

    const select = await screen.findByLabelText("Epic dependency policy")
    expect(select).not.toBeDisabled()
    expect(screen.getByRole("option", { name: /^Linear/ })).toBeInTheDocument()
    expect(screen.queryByRole("option", { name: /Nonlinear/ })).not.toBeInTheDocument()
  })

  it("shows an existing nonlinear policy as disabled/informational, not selectable", async () => {
    mockFetch({ epic_dependency_policy: "nonlinear" })
    renderRoute()

    const select = await screen.findByLabelText("Epic dependency policy")
    expect(select).toBeDisabled()
    expect(select).toHaveValue("nonlinear")
    expect(screen.queryByRole("option", { name: /^Linear/ })).not.toBeInTheDocument()
  })
})
