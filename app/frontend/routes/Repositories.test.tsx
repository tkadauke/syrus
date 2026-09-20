import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoriesIndex } from "./Repositories"

function repositoryRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    slug: "acme/widgets",
    owner: "acme",
    name: "widgets",
    owner_user: { id: 2, display_name: "Ada Lovelace", email_address: "ada@example.com", admin: false },
    default_branch: "main",
    upstream_owner: null,
    upstream_name: null,
    upstream_default_branch: null,
    upstream_slug: null,
    trigger_label: "syrus",
    polling_enabled: true,
    archived: false,
    archived_at: null,
    agent_provider: null,
    agent_provider_label: "Claude",
    main_health: "unknown",
    open_jobs_count: 0,
    last_job_activity_at: null,
    epic_dependency_policy: "linear",
    last_poll_status: null,
    last_poll_started_at: null,
    last_poll_error: null,
    repository_path: "/repositories/1",
    edit_repository_path: "/repositories/1/edit",
    ...overrides
  }
}

function smartFolder(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    name: "All",
    i18n_key: "repositories_all",
    position: 0,
    kind: "builtin",
    subject_type: "repository",
    visibility: "always",
    count: 1,
    active: false,
    filter: { and: [] },
    path: "/repositories?smart_folder_id=1",
    ...overrides
  }
}

function repositoriesPayload(overrides: Record<string, unknown> = {}) {
  return {
    active_repositories: [repositoryRow()],
    archived_repositories: [],
    new_repository_path: "/repositories/new",
    smart_folders: [
      smartFolder(),
      smartFolder({ id: 2, name: "Recent", i18n_key: "repositories_recent", count: 0, path: "/repositories?smart_folder_id=2" }),
      smartFolder({ id: 3, name: "Archived", i18n_key: "repositories_archived", count: 0, path: "/repositories?smart_folder_id=3" })
    ],
    active_smart_folder_id: null,
    filter: { and: [] },
    message: null,
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories"]}>
        <RepositoriesIndex />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoriesIndex data table", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  it("shows the default visible columns without polling emphasis", async () => {
    renderRoute()

    expect(await screen.findByRole("columnheader", { name: "Repository" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "GitHub owner" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Open jobs" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Last activity" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Health" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Agent" })).toBeInTheDocument()

    expect(screen.queryByRole("columnheader", { name: "Polling" })).not.toBeInTheDocument()
    expect(screen.queryByRole("columnheader", { name: "Last poll" })).not.toBeInTheDocument()
    expect(screen.queryByRole("columnheader", { name: "Trigger label" })).not.toBeInTheDocument()
    expect(screen.queryByRole("columnheader", { name: "Default branch" })).not.toBeInTheDocument()
    expect(screen.queryByRole("columnheader", { name: "Syrus owner" })).not.toBeInTheDocument()
    expect(screen.queryByRole("columnheader", { name: "Upstream" })).not.toBeInTheDocument()
  })

  it("toggles an opt-in column through the column picker", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Repository" })
    expect(screen.queryByRole("columnheader", { name: "Polling" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("checkbox", { name: "Polling" }))

    await waitFor(() => {
      expect(screen.getByRole("columnheader", { name: "Polling" })).toBeInTheDocument()
    })
  })

  it("does not render an Archive button on index rows", async () => {
    renderRoute()

    expect(await screen.findByRole("link", { name: "acme/widgets" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Archive" })).not.toBeInTheDocument()
  })

  it("still offers Unarchive on archived rows", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload({
      active_repositories: [],
      archived_repositories: [repositoryRow({ id: 2, slug: "acme/attic", archived: true, archived_at: "2026-01-01T00:00:00Z" })]
    })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Unarchive" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Archive" })).not.toBeInTheDocument()
  })
})

describe("RepositoriesIndex smart folders", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  it("does not render a page-level smart folder sidebar (it lives in the app sidebar's Repositories section instead)", async () => {
    renderRoute()

    await screen.findByRole("link", { name: "acme/widgets" })
    expect(screen.queryByRole("navigation", { name: "Repositories smart folders" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "All 1" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Recent 0" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Archived 0" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Folder name")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
  })

  it("shows both active and archived repositories together when no folder narrows them", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload({
      active_repositories: [repositoryRow({ id: 1, slug: "acme/widgets" })],
      archived_repositories: [repositoryRow({ id: 2, slug: "acme/attic", archived: true, archived_at: "2026-01-01T00:00:00Z" })]
    })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "acme/widgets" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/attic" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Unarchive" })).toBeInTheDocument()
  })

  it("shows the Recent smart folder's empty state when nothing matches its fixed 30-day cutoff", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload({
      active_repositories: [],
      archived_repositories: [],
      active_smart_folder_id: 2
    })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories?smart_folder_id=2"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No repositories with job activity in the last 30 days.")).toBeInTheDocument()
  })

  it("shows the Archived smart folder's empty state when there is nothing archived", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload({
      active_repositories: [],
      archived_repositories: [],
      active_smart_folder_id: 3
    })))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories?smart_folder_id=3"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No archived repositories.")).toBeInTheDocument()
  })

  it("removes the row from the Archived folder view after inline Unarchive, instead of leaving it stale", async () => {
    let archived = true
    const archivedRow = () => repositoryRow({ id: 2, slug: "acme/attic", archived, archived_at: archived ? "2026-01-01T00:00:00Z" : null })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      const method = init?.method || "GET"

      if (url === "/api/v1/app/repositories/2/unarchive" && method === "POST") {
        archived = false
        return Promise.resolve(jsonResponse(repositoriesPayload({ message: "acme/attic unarchived." })))
      }

      // The index GET always reflects the currently active smart folder
      // (Archived here), so once `archived` flips false the repo drops out
      // of this response entirely -- unlike the unarchive endpoint's own
      // response above, which is unfiltered.
      return Promise.resolve(jsonResponse(repositoriesPayload({
        active_repositories: [],
        archived_repositories: archived ? [ archivedRow() ] : [],
        active_smart_folder_id: 3
      })))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories?smart_folder_id=3"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "acme/attic" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Unarchive" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/2/unarchive",
        expect.objectContaining({ method: "POST" })
      )
    })

    await waitFor(() => {
      expect(screen.queryByRole("link", { name: "acme/attic" })).not.toBeInTheDocument()
    })
    expect(await screen.findByText("No archived repositories.")).toBeInTheDocument()
  })
})

describe("RepositoriesIndex filter dropdown options", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  it("keeps every owner option available after filtering narrows the visible repositories", async () => {
    const fullPayload = repositoriesPayload({
      active_repositories: [
        repositoryRow({ id: 1, slug: "acme/widgets", owner: "acme" }),
        repositoryRow({ id: 2, slug: "bob/gadgets", owner: "bob" })
      ]
    })
    const narrowedPayload = repositoriesPayload({
      active_repositories: [repositoryRow({ id: 1, slug: "acme/widgets", owner: "acme" })]
    })

    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      if (url.includes("github_owner=acme")) return Promise.resolve(jsonResponse(narrowedPayload))
      return Promise.resolve(jsonResponse(fullPayload))
    })

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const ownerSelect = await screen.findByRole("combobox", { name: "GitHub owner" })
    expect(within(ownerSelect).getByRole("option", { name: "bob" })).toBeInTheDocument()

    fireEvent.change(ownerSelect, { target: { value: "acme" } })

    await waitFor(() => {
      expect(screen.queryByText("bob/gadgets")).not.toBeInTheDocument()
    })

    // The result set narrowed to acme's own repository, but the owner
    // dropdown must still offer "bob" -- otherwise there is no way back to
    // it short of clearing every filter.
    expect(within(ownerSelect).getByRole("option", { name: "bob" })).toBeInTheDocument()
  })
})
