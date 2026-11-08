import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import * as useConfirmModule from "../hooks/useConfirm"
import { bootstrapPayload, bootstrapSetupStatusPayload, setupStatus } from "../test/app/bootstrap"
import { repositoriesPayload, repositoryDetailPayload, repositoryFormPayload } from "../test/app/repositoryPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App repositories", () => {
  installAppTestLifecycle()

  it("renders repositories in the data table with no Poll now or index Archive action", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(repositoriesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Repositories" })).toHaveClass("max-w-[96rem]")
    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Repository" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "GitHub owner" })).toBeInTheDocument()
    expect(screen.getByText("old/repo")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Add" })).toHaveAttribute("href", "/app-shell/repositories/new")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.queryByRole("button", { name: "Poll now" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Edit" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Archive" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Unarchive" })).toBeInTheDocument()
  })

  it("points an empty repositories index to the setup next action", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({ setupStatus: bootstrapSetupStatusPayload({ nextStep: "configure_credentials" }) }))
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            ...repositoriesPayload(),
            active_repositories: [],
            archived_repositories: []
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/repositories"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("heading", { name: "Connect credentials first" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Open credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    } finally {
      script.remove()
    }
  })

  it("renders the repository form with GitHub selectors and submits it to the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ error: { code: "validation_failed", message: "Owner has already been taken" } }), {
            status: 422,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ user: "acme", orgs: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/repos?owner=acme&owner_type=user") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              repos: [{ name: "widgets", github_repository_id: 456, github_owner_id: 123 }]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/repositories/branches?owner=acme&name=widgets") {
        return Promise.resolve(
          new Response(JSON.stringify({ branches: ["trunk", "main"], default_branch: "trunk" }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Add Repository" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Working repository" })).toBeInTheDocument()
    expect(screen.getByText("Syrus polls issues, creates branches, and opens PRs in this repository.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Upstream repository" })).toBeInTheDocument()
    expect(screen.getByText("Optional reference repo for fork context. Syrus still opens PRs in the working repository.")).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/repositories")
    expect(await screen.findByRole("option", { name: "acme" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Working owner"), { target: { value: "acme" } })
    expect(await screen.findByRole("option", { name: "widgets" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Working name"), { target: { value: "widgets" } })
    expect(await screen.findByRole("option", { name: "trunk" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Default branch"), { target: { value: "trunk" } })
    fireEvent.change(screen.getByLabelText("Upstream owner"), { target: { value: "rails" } })
    fireEvent.change(screen.getByLabelText("Upstream name"), { target: { value: "rails" } })
    fireEvent.change(screen.getByLabelText("Upstream default branch"), { target: { value: "main" } })
    fireEvent.change(screen.getByLabelText("Auto-approval fallback"), { target: { value: "if_graders_pass" } })
    fireEvent.click(screen.getByLabelText("Run prepare step on this repository's Workflows"))
    fireEvent.click(screen.getByLabelText("Auto-merge approved Syrus PRs"))
    fireEvent.click(screen.getByRole("button", { name: "Create Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({
            repository: {
              owner: "acme",
              name: "widgets",
              default_branch: "trunk",
              upstream_owner: "rails",
              upstream_name: "rails",
              upstream_default_branch: "main",
              trigger_label: "syrus",
              polling_enabled: true,
              prepare_enabled: false,
              pr_cost_footer_enabled: true,
              auto_merge_enabled: true,
              trust_clean_rebase_grade: false,
              main_branch_health_enabled: true,
              main_branch_repair_enabled: false,
              main_branch_repair_blocks_work: true,
              main_branch_repair_auto_approve: false,
              treat_grader_timeouts_as_failures: false,
              auto_approve_mode: "if_graders_pass",
              feedback_policy: "confirm",
              github_owner_id: "123",
              github_repository_id: "456"
            }
          })
        })
      )
    })
    expect(await screen.findByText("Owner has already been taken")).toBeInTheDocument()
  })

  it("creates a repository and navigates within the React shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Repository created.",
              redirect_to: "/repositories/3",
              repository: {
                id: 3,
                slug: "acme/widgets",
                owner: "acme",
                name: "widgets",
                default_branch: "main",
                upstream_owner: null,
                upstream_name: null,
                upstream_default_branch: null,
                upstream_slug: null,
                trigger_label: "syrus",
                polling_enabled: true,
                archived: false,
                archived_at: null,
                agent_provider: "codex",
                agent_provider_label: "Codex",
                last_poll_status: null,
                last_poll_started_at: null,
                last_poll_error: null,
                repository_path: "/repositories/3",
                edit_repository_path: "/repositories/3/edit"
              }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/repositories/3") {
        const detail = repositoryDetailPayload()
        return Promise.resolve(
          new Response(
            JSON.stringify({
              ...detail,
              jobs: undefined,
              pagination: undefined,
              message: "Repository created."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/repositories/3/jobs") {
        const { jobs, pagination } = repositoryDetailPayload()
        return Promise.resolve(new Response(JSON.stringify({ jobs, pagination }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/3/delivery") {
        return Promise.resolve(new Response(JSON.stringify({ delivery: null }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/3/syrus_yml") {
        return Promise.resolve(new Response(JSON.stringify({ syrus_yml: null }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ error: "no_token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/repositories/branches")) {
        return Promise.resolve(
          new Response(JSON.stringify({ branches: ["main"], default_branch: "main" }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByLabelText("Working owner"), { target: { value: "acme" } })
    fireEvent.change(screen.getByLabelText("Working name"), { target: { value: "widgets" } })
    fireEvent.click(screen.getByRole("button", { name: "Create Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.stringContaining('"owner":"acme"')
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Repository" })).toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/jobs",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/delivery",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/syrus_yml",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
  })

  it("renders the edit repository form and patches repository settings", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ error: { code: "validation_failed", message: "Trigger label can't be blank" } }), {
            status: 422,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ error: "no_token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/3/memberships" && (init?.method || "GET") === "GET") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
              memberships: [],
              team_grants: [],
              github_collaborator_discrepancies: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            repositoryFormPayload({
              repository: {
                id: 3,
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
                main_branch_health_enabled: true,
                main_branch_repair_enabled: true,
                main_branch_repair_blocks_work: true,
                main_branch_repair_auto_approve: false,
                treat_grader_timeouts_as_failures: false,
                agent_provider: "",
                auto_approve_mode: "never",
                github_owner_id: null,
                github_repository_id: null,
                repository_path: "/repositories/3"
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Edit Repository" })).toBeInTheDocument()
    expect(await screen.findByDisplayValue("acme")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Back to repository" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/repositories")
    fireEvent.change(screen.getByLabelText("Trigger label"), { target: { value: "delegate" } })
    fireEvent.click(screen.getByRole("button", { name: "Save Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: expect.stringContaining('"trigger_label":"delegate"')
        })
      )
    })
    expect(await screen.findByText("Trigger label can't be blank")).toBeInTheDocument()
  })

  it("redirects the retired repository memberships tab to repository edit", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ error: "no_token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/3/memberships" && (init?.method || "GET") === "GET") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
              memberships: [],
              team_grants: [],
              github_collaborator_discrepancies: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            repositoryFormPayload({
              repository: {
                id: 3,
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
                main_branch_health_enabled: true,
                main_branch_repair_enabled: true,
                main_branch_repair_blocks_work: true,
                main_branch_repair_auto_approve: false,
                treat_grader_timeouts_as_failures: false,
                agent_provider: "",
                auto_approve_mode: "never",
                github_owner_id: null,
                github_repository_id: null,
                repository_path: "/repositories/3"
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3/memberships"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Edit Repository" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Members" })).toBeInTheDocument()
  })

  it("runs repository detail commands through the app API", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn().mockImplementation(async () => true), dialog: <></> })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/poll" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              ...repositoryDetailPayload(),
              message: "Polling acme/widgets now."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "More actions" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Poll now" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/poll",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ return_to: "detail", page: 1 })
        })
      )
    })
    expect(await screen.findByText("Polling acme/widgets now.")).toBeInTheDocument()

    // Archive lives in the edit form's danger zone now, not the detail
    // page's "More actions" menu.
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.queryByRole("menuitem", { name: "Archive" })).not.toBeInTheDocument()
  })
})
