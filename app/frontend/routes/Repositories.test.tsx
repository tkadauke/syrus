import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { _clearRecentApiRequestsForTest } from "../api/client"
import { RepositoriesIndex } from "./Repositories"

beforeEach(() => {
  _clearRecentApiRequestsForTest()
  vi.restoreAllMocks()
})

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
    filter_schema: [
      { field: "slug", label: "Repository", bucket: "string", operators: ["contains"], free_text_search: true },
      { field: "github_owner", label: "GitHub owner", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [] },
      {
        field: "health",
        label: "Health",
        bucket: "enum",
        operators: ["is", "is_not", "is_one_of", "is_none_of"],
        values: [
          { value: "healthy", label: "Healthy" },
          { value: "broken", label: "Broken" },
          { value: "inconclusive", label: "Inconclusive" },
          { value: "unknown", label: "Unknown" }
        ]
      },
      { field: "agent_provider", label: "Agent", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [] },
      { field: "has_open_jobs", label: "Has open jobs", bucket: "boolean", operators: ["is_true", "is_false"] }
    ],
    message: null,
    ...overrides
  }
}

afterEach(() => {
  cleanup()
  _clearRecentApiRequestsForTest()
  vi.restoreAllMocks()
})

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload()))
  renderRouteWithClient()
}

function renderRouteWithClient(initialPath = "/app-shell/repositories") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialPath]}>
        <RepositoriesIndex />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function visibleSlugOrder() {
  return screen
    .getAllByRole("row")
    .slice(1)
    .map((row) => within(row).getAllByRole("link")[0]?.textContent)
}

const ALL_OPTIONAL_COLUMNS = [
  "github_owner",
  "open_jobs",
  "last_activity",
  "health",
  "agent",
  "polling_status",
  "last_poll",
  "trigger_label",
  "default_branch",
  "syrus_owner",
  "upstream_slug"
]

function showAllRepositoryColumns() {
  window.localStorage.setItem("syrus.repositories.visible_columns", JSON.stringify(ALL_OPTIONAL_COLUMNS))
}

// Below the lg breakpoint the app sidebar's Repositories subnav collapses
// into the drawer and isn't reachable, so the page renders its own in-page
// "Folders and filters" fallback -- mirrors Dashboard/Agent Activity/Design
// Docs, which use the same narrow-viewport matchMedia mock in their specs.
function mockNarrowViewport() {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query !== "(min-width: 1024px)",
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    }))
  })

  return () => {
    if (original) {
      Object.defineProperty(window, "matchMedia", original)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  }
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

  it("reorders visible columns with the move up/down buttons and persists the new order", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Repository" })

    function optionalColumnOrder() {
      const optionalNames = ["GitHub owner", "Open jobs", "Last activity", "Health", "Agent"]
      return screen
        .getAllByRole("columnheader")
        .map((header) => header.textContent?.trim())
        .filter((name) => optionalNames.includes(name ?? ""))
    }

    expect(optionalColumnOrder()).toEqual(["GitHub owner", "Open jobs", "Last activity", "Health", "Agent"])

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("button", { name: "Move Open jobs up" }))

    await waitFor(() => {
      expect(optionalColumnOrder()).toEqual(["Open jobs", "GitHub owner", "Last activity", "Health", "Agent"])
    })

    expect(JSON.parse(window.localStorage.getItem("syrus.repositories.visible_columns") ?? "[]")).toEqual([
      "open_jobs",
      "github_owner",
      "last_activity",
      "health",
      "agent"
    ])
  })

  it("reorders columns by dragging a header and persists the new order", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Repository" })

    function optionalColumnOrder() {
      const optionalNames = ["GitHub owner", "Open jobs", "Last activity", "Health", "Agent"]
      return screen
        .getAllByRole("columnheader")
        .map((header) => header.textContent?.trim())
        .filter((name) => optionalNames.includes(name ?? ""))
    }

    expect(optionalColumnOrder()).toEqual(["GitHub owner", "Open jobs", "Last activity", "Health", "Agent"])

    const ownerHeader = screen.getByRole("columnheader", { name: "GitHub owner" })
    const openJobsHeader = screen.getByRole("columnheader", { name: /Open jobs/ })
    const transfer = { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }

    fireEvent.dragStart(ownerHeader, { dataTransfer: transfer })
    fireEvent.dragOver(openJobsHeader, { dataTransfer: transfer })
    fireEvent.drop(openJobsHeader, { dataTransfer: transfer })

    await waitFor(() => {
      expect(optionalColumnOrder()).toEqual(["Open jobs", "GitHub owner", "Last activity", "Health", "Agent"])
    })

    expect(JSON.parse(window.localStorage.getItem("syrus.repositories.visible_columns") ?? "[]")).toEqual([
      "open_jobs",
      "github_owner",
      "last_activity",
      "health",
      "agent"
    ])

    // The required Repository/Actions columns never accept a drag -- verify
    // dragging one onto an optional column is a no-op.
    const repositoryHeader = screen.getByRole("columnheader", { name: "Repository" })
    fireEvent.dragStart(repositoryHeader, { dataTransfer: transfer })
    fireEvent.dragOver(openJobsHeader, { dataTransfer: transfer })
    fireEvent.drop(openJobsHeader, { dataTransfer: transfer })

    expect(screen.getAllByRole("columnheader").map((header) => header.textContent?.trim())[0]).toBe("Repository")
  })

  it.each([
    ["Repository", ["acme/zulu", "acme/widgets", "acme/apex"], "descending"],
    ["GitHub owner", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Open jobs", ["acme/widgets", "acme/zulu", "acme/apex"], "ascending"],
    ["Last activity", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Health", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Agent", ["acme/zulu", "acme/apex", "acme/widgets"], "ascending"],
    ["Polling", ["acme/apex", "acme/widgets", "acme/zulu"], "ascending"],
    ["Last poll", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Trigger label", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Default branch", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Syrus owner", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"],
    ["Upstream", ["acme/apex", "acme/zulu", "acme/widgets"], "ascending"]
  ])("sorts repositories by %s with the shared header indicator", async (columnName, expectedOrder, expectedDirection) => {
    showAllRepositoryColumns()
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [
            repositoryRow({
              id: 1,
              slug: "acme/widgets",
              owner: "zeus",
              open_jobs_count: 1,
              last_job_activity_at: "2026-02-01T00:00:00Z",
              main_health: "unknown",
              agent_provider_label: "Zulu",
              polling_enabled: true,
              last_poll_status: "ok",
              last_poll_started_at: "2026-01-03T00:00:00Z",
              trigger_label: "z-label",
              default_branch: "release",
              owner_user: { id: 2, display_name: "Zoe", email_address: "zoe@example.com", admin: false },
              upstream_slug: "core/z",
              upstream_default_branch: "main"
            }),
            repositoryRow({
              id: 2,
              slug: "acme/apex",
              owner: "acme",
              open_jobs_count: 9,
              last_job_activity_at: null,
              main_health: "broken",
              agent_provider_label: "Codex",
              polling_enabled: false,
              last_poll_status: null,
              last_poll_started_at: null,
              trigger_label: "a-label",
              default_branch: "develop",
              owner_user: { id: 3, display_name: "Ada", email_address: "ada@example.com", admin: false },
              upstream_slug: null
            }),
            repositoryRow({
              id: 3,
              slug: "acme/zulu",
              owner: "mid",
              open_jobs_count: 5,
              last_job_activity_at: "2026-01-01T00:00:00Z",
              main_health: "healthy",
              agent_provider_label: "Claude",
              polling_enabled: true,
              last_poll_status: "ok",
              last_poll_started_at: "2026-01-01T00:00:00Z",
              trigger_label: "m-label",
              default_branch: "main",
              owner_user: { id: 4, display_name: "Maya", email_address: "maya@example.com", admin: false },
              upstream_slug: "core/a",
              upstream_default_branch: "main"
            })
          ]
        })
      )
    )
    renderRouteWithClient()

    await screen.findByRole("link", { name: "acme/widgets" })

    expect(visibleSlugOrder()).toEqual(["acme/apex", "acme/widgets", "acme/zulu"])

    const sortButton = screen.getByRole("button", { name: new RegExp(columnName) })
    const header = sortButton.closest("th")
    expect(header?.querySelector("[data-sort-indicator]")).toBeInTheDocument()

    fireEvent.click(sortButton)

    await waitFor(() => {
      expect(visibleSlugOrder()).toEqual(expectedOrder)
    })

    expect(header).toHaveAttribute("aria-sort", expectedDirection)
  })

  it("keeps sorting intact after optional columns are reordered", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [
            repositoryRow({ id: 1, slug: "acme/widgets", open_jobs_count: 1 }),
            repositoryRow({ id: 2, slug: "acme/apex", open_jobs_count: 9 }),
            repositoryRow({ id: 3, slug: "acme/zulu", open_jobs_count: 5 })
          ]
        })
      )
    )
    renderRouteWithClient()

    await screen.findByRole("link", { name: "acme/widgets" })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    const menu = await screen.findByRole("menu")
    fireEvent.click(within(menu).getByRole("button", { name: "Move Open jobs up" }))

    await waitFor(() => {
      expect(
        screen
          .getAllByRole("columnheader")
          .map((header) => header.textContent?.trim())
          .slice(0, 3)
      ).toEqual(["Repository", "Open jobs", "GitHub owner"])
    })

    fireEvent.click(within(screen.getByRole("columnheader", { name: /Open jobs/ })).getByRole("button", { name: /Open jobs/ }))

    await waitFor(() => {
      expect(visibleSlugOrder()).toEqual(["acme/widgets", "acme/zulu", "acme/apex"])
    })
  })

  it("does not render an Archive button on index rows", async () => {
    renderRoute()

    expect(await screen.findByRole("link", { name: "acme/widgets" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Archive" })).not.toBeInTheDocument()
  })

  it("still offers Unarchive on archived rows", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [],
          archived_repositories: [repositoryRow({ id: 2, slug: "acme/attic", archived: true, archived_at: "2026-01-01T00:00:00Z" })]
        })
      )
    )
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

  it("falls back to an in-page Folders and filters panel below the lg breakpoint, since the app sidebar's subnav is unreachable there", async () => {
    const restoreMatchMedia = mockNarrowViewport()
    try {
      renderRoute()

      await screen.findByRole("link", { name: "acme/widgets" })

      fireEvent.click(screen.getByText("Folders and filters"))

      const folderNav = await screen.findByRole("navigation", { name: "Repositories smart folders" })
      expect(within(folderNav).getByRole("link", { name: "All 1" })).toHaveAttribute("href", "/app-shell/repositories?smart_folder_id=1")
      expect(within(folderNav).getByRole("link", { name: "Recent 0" })).toHaveAttribute("href", "/app-shell/repositories?smart_folder_id=2")
      expect(within(folderNav).getByRole("link", { name: "Archived 0" })).toHaveAttribute("href", "/app-shell/repositories?smart_folder_id=3")
    } finally {
      restoreMatchMedia()
    }
  })

  it("shows both active and archived repositories together when no folder narrows them", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [repositoryRow({ id: 1, slug: "acme/widgets" })],
          archived_repositories: [repositoryRow({ id: 2, slug: "acme/attic", archived: true, archived_at: "2026-01-01T00:00:00Z" })]
        })
      )
    )
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
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [],
          archived_repositories: [],
          active_smart_folder_id: 2
        })
      )
    )
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
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        repositoriesPayload({
          active_repositories: [],
          archived_repositories: [],
          active_smart_folder_id: 3
        })
      )
    )
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
      return Promise.resolve(
        jsonResponse(
          repositoriesPayload({
            active_repositories: [],
            archived_repositories: archived ? [archivedRow()] : [],
            active_smart_folder_id: 3
          })
        )
      )
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
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/repositories/2/unarchive", expect.objectContaining({ method: "POST" }))
    })

    await waitFor(() => {
      expect(screen.queryByRole("link", { name: "acme/attic" })).not.toBeInTheDocument()
    })
    expect(await screen.findByText("No archived repositories.")).toBeInTheDocument()
  })
})

describe("RepositoriesIndex filter bar", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
  })

  function ownerFilterSchema() {
    const base = repositoriesPayload().filter_schema as Array<Record<string, unknown>>
    return base.map((field) =>
      field.field === "github_owner"
        ? {
            ...field,
            values: [
              { value: "acme", label: "acme" },
              { value: "bob", label: "bob" }
            ]
          }
        : field
    )
  }

  it("adds a filter chip through the shared FilterBar and narrows the visible repositories", async () => {
    const filter_schema = ownerFilterSchema()
    const fullPayload = repositoriesPayload({
      active_repositories: [repositoryRow({ id: 1, slug: "acme/widgets", owner: "acme" }), repositoryRow({ id: 2, slug: "bob/gadgets", owner: "bob" })],
      filter_schema
    })
    const narrowedPayload = repositoriesPayload({
      active_repositories: [repositoryRow({ id: 1, slug: "acme/widgets", owner: "acme" })],
      filter: { and: [{ field: "github_owner", op: "is", value: "acme" }] },
      filter_schema
    })

    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = String(input)
      // FilterBar encodes the chip tree into a `q=` param -- the presence
      // of `q=` (rather than a bespoke `github_owner=` param) is itself
      // evidence the shared chip-bar wire format is in use, not a bespoke
      // dropdown.
      if (url.includes("q=")) return Promise.resolve(jsonResponse(narrowedPayload))
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

    await screen.findByRole("link", { name: "acme/widgets" })
    expect(screen.getByRole("link", { name: "bob/gadgets" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "GitHub owner list" }))

    await waitFor(() => {
      expect(screen.queryByRole("link", { name: "bob/gadgets" })).not.toBeInTheDocument()
    })
    expect(screen.getByRole("button", { name: "GitHub owner is acme" })).toBeInTheDocument()
  })
})

describe("RepositoriesIndex responsive gutter", () => {
  it("drops the page-level gutter on the root and restores it on the header, letting the table go flush", async () => {
    renderRoute()

    await screen.findByRole("columnheader", { name: "Repository" })

    const main = screen.getByRole("main", { name: "Repositories" })
    expect(main.className).toContain("px-0")
    expect(main.className).toContain("sm:px-[var(--space-page-x)]")

    const heading = screen.getByRole("heading", { name: "Repositories" })
    const header = heading.closest("header")
    expect(header?.className).toContain("px-4 sm:px-0")

    const table = screen.getByRole("columnheader", { name: "Repository" }).closest("table")
    const tableWrapper = table?.parentElement
    expect(tableWrapper?.className ?? "").not.toContain("px-4 sm:px-0")
  })

  it("keeps the filter bar and column menu margined on a narrow viewport", async () => {
    const restore = mockNarrowViewport()
    try {
      renderRoute()
      await screen.findByRole("columnheader", { name: "Repository" })

      const columnsButton = screen.getByRole("button", { name: "Columns" })
      const controlsRow = columnsButton.closest("div.flex.flex-wrap.items-start.justify-between")
      expect(controlsRow?.className).toContain("mx-4 sm:mx-0")
    } finally {
      restore()
    }
  })

  it("keeps the load-error banner margined instead of running it flush", async () => {
    vi.spyOn(window, "fetch").mockRejectedValue(new Error("network down"))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const banner = await screen.findByText("Unable to load repositories.")
    const marginWrapper = banner.parentElement?.parentElement
    expect(marginWrapper?.className).toContain("mx-4 sm:mx-0")
  })

  it("keeps the loading banner margined instead of running it flush", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const banner = screen.getByText("Loading repositories...")
    const marginWrapper = banner.parentElement?.parentElement
    expect(marginWrapper?.className).toContain("mx-4 sm:mx-0")
  })

  it("keeps the inline unarchive-error banner margined instead of running it flush", async () => {
    const payload = repositoriesPayload({
      archived_repositories: [repositoryRow({ id: 2, slug: "acme/attic", archived: true, archived_at: "2026-01-01T00:00:00Z" })]
    })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      const method = init?.method || "GET"
      if (url === "/api/v1/app/repositories/2/unarchive" && method === "POST") {
        return Promise.resolve(jsonResponse({ error: "boom" }, 500))
      }
      return Promise.resolve(jsonResponse(payload))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <RepositoriesIndex />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Unarchive" }))

    const banner = await screen.findByText("Request failed with 500")
    const marginWrapper = banner.parentElement?.parentElement
    expect(marginWrapper?.className).toContain("mx-4 sm:mx-0")
  })
})
