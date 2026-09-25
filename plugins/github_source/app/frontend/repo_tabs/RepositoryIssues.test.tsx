import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import RepositoryIssuesTab from "./RepositoryIssues"
import type { RepositoryIssue, RepositoryIssuesPayload } from "../api/issues"
import type { RepositoryDetailRecord } from "@app/api/repositories"

function repository() {
  return { id: 1, slug: "acme/widgets", github_url: "https://github.com/acme/widgets", trigger_label: "syrus" } as unknown as RepositoryDetailRecord
}

function tabs() {
  return [
    { key: "overview", label: "Overview", path: "/repositories/1" },
    { key: "github_source.issues", label: "GitHub Issues", path: "/repositories/1/plugin/issues" }
  ]
}

function issue(overrides: Partial<RepositoryIssue> = {}): RepositoryIssue {
  return {
    number: 7,
    title: "Fix the forum",
    state: "open",
    html_url: "https://github.com/acme/widgets/issues/7",
    body_excerpt: "Line one Line two",
    user_login: "alice",
    created_at: "2026-01-01T00:00:00Z",
    labels: [ { name: "bug", color: "d73a4a" } ],
    delegated: false,
    ...overrides
  }
}

function paths() {
  return {
    github_issues_path: "https://github.com/acme/widgets/issues",
    app_close_issue_path: "/api/v1/app/repositories/1/issues/close",
    app_delegate_issue_path: "/api/v1/app/repositories/1/issues/delegate",
    app_bulk_issues_path: "/api/v1/app/repositories/1/issues/bulk"
  }
}

function folderPaths() {
  return {
    inbox: "/repositories/1?tab=github_issues&folder=inbox",
    delegated: "/repositories/1?tab=github_issues&folder=delegated",
    open: "/repositories/1?tab=github_issues&folder=open",
    closed: "/repositories/1?tab=github_issues&folder=closed"
  }
}

const ISSUE_FILTER_SCHEMA = [
  { field: "query", label: "Search", bucket: "string", operators: [ "contains" ], values: [], free_text_search: true }
]

function issuesPayload(overrides: Partial<RepositoryIssuesPayload> = {}): RepositoryIssuesPayload {
  return {
    repository: repository(),
    tabs: tabs(),
    folder: "inbox",
    query: null,
    filter: { and: [] },
    filter_schema: ISSUE_FILTER_SCHEMA,
    issue_count: 1,
    issues: [ issue() ],
    folder_counts: { inbox: 1, delegated: 0, open: 1, closed: 0 },
    folder_paths: folderPaths(),
    paths: paths(),
    ...overrides
  }
}

function decodeFilterTree(q: string): { and?: Array<{ field: string; op: string; value?: unknown }> } {
  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

function renderRoute(initialEntry = "/repositories/1/plugin/issues") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ initialEntry ]}>
        <Routes>
          <Route element={<RepositoryIssuesTab />} path="/repositories/:repositoryId/plugin/issues" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function findRowContaining(text: string) {
  const rows = screen.getAllByRole("row")
  const match = rows.find((row) => row.textContent?.includes(text))
  if (!match) throw new Error(`No row found containing "${text}"`)
  return match
}

describe("RepositoryIssuesTab", () => {
  afterEach(() => vi.restoreAllMocks())

  it("highlights the GitHub Issues tab using the real repo_page_tab id, not a mismatched literal", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({ issues: [], issue_count: 0 })))
    renderRoute()

    const issuesLink = await screen.findByRole("link", { name: "GitHub Issues" })
    expect(issuesLink.className).toContain("border-brand")
  })

  it("renders the standard smart folder navigation with counts and highlights the active folder", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({
      folder: "inbox",
      folder_counts: { inbox: 3, delegated: 2, open: 5, closed: 8 }
    })))
    renderRoute()

    const inboxLink = await screen.findByRole("link", { name: /Inbox/ })
    expect(inboxLink.className).toContain("bg-brand/10")
    expect(inboxLink).toHaveTextContent("3")

    const delegatedLink = screen.getByRole("link", { name: /Delegated/ })
    expect(delegatedLink.className).not.toContain("bg-brand/10")
    expect(delegatedLink).toHaveTextContent("2")
    expect(screen.getByRole("link", { name: /Open/ })).toHaveTextContent("5")
    expect(screen.getByRole("link", { name: /Closed/ })).toHaveTextContent("8")
  })

  it("renders issue rows in the shared data table with labels, author, and delegated state", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({
      issues: [ issue({ number: 7, title: "Fix the forum", delegated: true, labels: [ { name: "bug", color: "d73a4a" } ] }) ]
    })))
    renderRoute()

    expect(await screen.findByRole("link", { name: "#7" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/7")
    expect(screen.getByRole("link", { name: "Fix the forum" })).toBeInTheDocument()

    const row = findRowContaining("Fix the forum")
    expect(within(row).getByText("bug")).toBeInTheDocument()
    expect(within(row).getByText(/alice/)).toBeInTheDocument()
    expect(within(row).getByText("Delegated")).toBeInTheDocument()
    expect(within(row).queryByRole("button", { name: "Delegate" })).not.toBeInTheDocument()
  })

  it("closes an issue from the row action and refreshes the list", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.includes("/issues/close") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(issuesPayload({ folder: "open", issues: [], issue_count: 0, message: "Issue #7 closed." })))
      }
      return Promise.resolve(jsonResponse(issuesPayload({ folder: "open" })))
    })
    renderRoute("/repositories/1/plugin/issues?folder=open")

    fireEvent.click(await screen.findByRole("button", { name: "Close" }))

    await screen.findByText("Issue #7 closed.")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/issues/close",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ issue_number: 7, folder: "open", q: "" }) })
    )
  })

  it("delegates an issue from the row action", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.includes("/issues/delegate") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(issuesPayload({ issues: [ issue({ delegated: true }) ], message: "Issue #7 delegated to Syrus." })))
      }
      return Promise.resolve(jsonResponse(issuesPayload()))
    })
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Delegate" }))

    await screen.findByText("Issue #7 delegated to Syrus.")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/issues/delegate",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ issue_number: 7, folder: "inbox", q: "" }) })
    )
  })

  it("does not render the removed issue comment action", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload()))
    renderRoute()

    await screen.findByRole("link", { name: "Fix the forum" })

    expect(screen.queryByRole("button", { name: "Comment" })).not.toBeInTheDocument()
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument()
  })

  it("selects issues and performs a bulk delegate, disabling the button while pending", async () => {
    let resolveBulk: ((response: Response) => void) | null = null
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.includes("/issues/bulk") && init?.method === "POST") {
        return new Promise<Response>((resolve) => { resolveBulk = resolve })
      }
      return Promise.resolve(jsonResponse(issuesPayload({
        folder: "open",
        issues: [ issue({ number: 7 }), issue({ number: 8, title: "Second issue" }) ],
        issue_count: 2
      })))
    })
    renderRoute("/repositories/1/plugin/issues?folder=open")

    fireEvent.click(await screen.findByRole("checkbox", { name: "Select all issues" }))
    const delegateSelected = screen.getByRole("button", { name: "Delegate selected" })
    fireEvent.click(delegateSelected)

    await waitFor(() => expect(delegateSelected).toBeDisabled())

    resolveBulk!(jsonResponse(issuesPayload({ folder: "open", issues: [], issue_count: 0, message: "2 issues delegated to Syrus." })))

    await screen.findByText("2 issues delegated to Syrus.")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/issues/bulk",
      expect.objectContaining({ method: "POST", body: JSON.stringify({ issue_numbers: [ 7, 8 ], bulk_action: "delegate", folder: "open", q: "" }) })
    )
  })

  it("hides Close selected and the per-row Close action in the closed folder", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({
      folder: "closed",
      issues: [ issue({ state: "closed" }) ]
    })))
    renderRoute("/repositories/1/plugin/issues?folder=closed")

    fireEvent.click(await screen.findByRole("checkbox", { name: "Select all issues" }))

    expect(screen.queryByRole("button", { name: "Close selected" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Delegate selected" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Close" })).not.toBeInTheDocument()
  })

  it("renders folder-specific empty states", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({
      folder: "delegated",
      issues: [],
      issue_count: 0,
      folder_counts: { inbox: 0, delegated: 0, open: 0, closed: 0 }
    })))
    renderRoute("/repositories/1/plugin/issues?folder=delegated")

    expect(await screen.findByText("No issues in Delegated")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "View inbox" })).toBeInTheDocument()
  })

  it("renders the applied search as a FilterBar chip with a working clear-filters link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(issuesPayload({
      folder: "open",
      query: "forum",
      filter: { and: [ { field: "query", op: "contains", value: "forum" } ] },
      issue_count: 1
    })))
    renderRoute("/repositories/1/plugin/issues?folder=open")

    expect(await screen.findByRole("button", { name: "Search contains forum" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Clear filters" })).toBeInTheDocument()
  })

  it("filters the issue list through the FilterBar's free-text search chip", async () => {
    const matching = issue({ number: 1, title: "Fix the forum" })
    const other = issue({ number: 2, title: "Unrelated bug" })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://test.host")
      const q = url.searchParams.get("q")
      const tree = q ? decodeFilterTree(q) : { and: [] }
      const query = tree.and?.find((chip) => chip.field === "query")?.value
      const issues = typeof query === "string" ? [ matching, other ].filter((candidate) => candidate.title.toLowerCase().includes(query.toLowerCase())) : [ matching, other ]

      return Promise.resolve(jsonResponse(issuesPayload({
        folder: "open",
        filter: tree,
        query: typeof query === "string" ? query : null,
        issues,
        issue_count: issues.length
      })))
    })
    renderRoute("/repositories/1/plugin/issues?folder=open")

    await screen.findByText("Unrelated bug")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "forum" } })
    fireEvent.click(screen.getByText("Search for forum"))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("q="), expect.anything()))
    expect(await screen.findByRole("button", { name: "Search contains forum" })).toBeInTheDocument()
    expect(screen.getByText("Fix the forum")).toBeInTheDocument()
    expect(screen.queryByText("Unrelated bug")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("link", { name: "Clear filters" }))
    await screen.findByText("Unrelated bug")
  })
})
