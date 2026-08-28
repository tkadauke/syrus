import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import type { GitHistoryCommit, GitHistoryPage } from "../api/gitHistory"
import { GitHistory } from "./GitHistory"

function renderRoute(children: ReactNode, initialEntry = "/repositories/7/plugin/git_history") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={children} path="/repositories/:repositoryId/plugin/git_history" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function page(commits: GitHistoryCommit[], overrides: Partial<GitHistoryPage> = {}): GitHistoryPage {
  return {
    repository: { id: 7, slug: "acme/widgets" },
    available: true,
    commits,
    next_cursor: null,
    has_more: false,
    ...overrides
  }
}

describe("GitHistory", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders a Syrus-landed commit with its epic, job, and creating user", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "a".repeat(40),
        short_sha: "aaaaaaaaaa",
        subject: "Add dark mode toggle",
        authored_at: "2026-08-20T10:00:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 3, display_name: "Ada Lovelace" },
        origin: { type: "github_issue", issue_number: 12, issue_url: "https://github.com/acme/widgets/issues/12" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Add dark mode toggle")).toBeInTheDocument()
    expect(screen.getByText("Syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByText("by Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Issue #12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
  })

  it("renders an epic_landed commit with the epic and every member job", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "1".repeat(40),
        short_sha: "1111111111",
        subject: "Merge Epic #9 via Syrus merge-train",
        authored_at: "2026-08-22T10:00:00Z",
        classification: "epic_landed",
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        jobs: [
          { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
          { id: 43, slug: "JOB-43", title: "Add light mode toggle" }
        ]
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Merge Epic #9 via Syrus merge-train")).toBeInTheDocument()
    expect(screen.getByText("Epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "JOB-43" })).toHaveAttribute("href", "/jobs/43")
  })

  it("renders an epic_reconciliation commit with only the epic", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "2".repeat(40),
        short_sha: "2222222222",
        subject: "Syrus merge-train reconciliation",
        authored_at: "2026-08-22T11:00:00Z",
        classification: "epic_reconciliation",
        epic: { id: 9, slug: "EPIC-9", title: "Theming" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Syrus merge-train reconciliation")).toBeInTheDocument()
    expect(screen.getByText("Epic reconciliation")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.queryByRole("link", { name: /JOB-/ })).not.toBeInTheDocument()
  })

  it("renders an externally-opened PR commit distinctly from a raw push", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "b".repeat(40),
        short_sha: "bbbbbbbbbb",
        subject: "Fix typo in readme",
        authored_at: "2026-08-19T10:00:00Z",
        classification: "external_pr",
        job: { id: 100, slug: "JOB-100", title: "external contribution" },
        pr_number: 55,
        pr_url: "https://github.com/acme/widgets/pull/55",
        github_author: "octocat",
        author: { name: "octocat", email: "octocat@example.com" },
        committer: { name: "octocat", email: "octocat@example.com" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Fix typo in readme")).toBeInTheDocument()
    expect(screen.getByText("External PR")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #55" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/55")
    expect(screen.getByText("opened by octocat")).toBeInTheDocument()
  })

  it("renders a raw external push commit with git author attribution", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "c".repeat(40),
        short_sha: "cccccccccc",
        subject: "Direct commit straight to main",
        authored_at: "2026-08-18T10:00:00Z",
        classification: "external_push",
        author: { name: "Grace Hopper", email: "grace@example.com" },
        committer: { name: "Grace Hopper", email: "grace@example.com" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Direct commit straight to main")).toBeInTheDocument()
    expect(screen.getByText("Direct push")).toBeInTheDocument()
    expect(screen.getByText("pushed by Grace Hopper")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /JOB-/ })).not.toBeInTheDocument()
  })

  it("does not render a chat link when the API omits chat_session_id", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "d".repeat(40),
        short_sha: "dddddddddd",
        subject: "Ship it quietly",
        authored_at: "2026-08-17T10:00:00Z",
        classification: "syrus_landed",
        job: { id: 55, slug: "JOB-55", title: "Ship it quietly" },
        epic: null,
        user: { id: 4, display_name: "Owner" },
        origin: { type: "chat" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Ship it quietly")).toBeInTheDocument()
    expect(screen.getByText("via chat")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /^\/chats\// })).not.toBeInTheDocument()
    expect(document.querySelector("a[href^='/chats/']")).not.toBeInTheDocument()
  })

  it("shows an unavailable message when the bare clone has not synced yet", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([], { available: false })))

    renderRoute(<GitHistory />)

    await waitFor(() => expect(screen.getByText(/not available yet/)).toBeInTheDocument())
  })

  it("loads older commits via cursor-based pagination", async () => {
    const fetchSpy = vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse(page([
        {
          sha: "e".repeat(40),
          short_sha: "eeeeeeeeee",
          subject: "Recent commit",
          authored_at: "2026-08-21T10:00:00Z",
          classification: "external_push",
          author: { name: "Someone", email: "someone@example.com" },
          committer: { name: "Someone", email: "someone@example.com" }
        }
      ], { has_more: true, next_cursor: "e".repeat(40) })))
      .mockResolvedValueOnce(jsonResponse(page([
        {
          sha: "f".repeat(40),
          short_sha: "ffffffffff",
          subject: "Older commit",
          authored_at: "2026-08-15T10:00:00Z",
          classification: "external_push",
          author: { name: "Someone Else", email: "else@example.com" },
          committer: { name: "Someone Else", email: "else@example.com" }
        }
      ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Recent commit")).toBeInTheDocument()
    const loadMore = screen.getByRole("button", { name: "Load older commits" })
    loadMore.click()

    await waitFor(() => expect(screen.getByText("Older commit")).toBeInTheDocument())
    expect(fetchSpy).toHaveBeenLastCalledWith(
      `/api/v1/app/repositories/7/git_history/commits?cursor=${"e".repeat(40)}`,
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("nests member Jobs' implementation commits under their Epic group instead of listing them flat", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "1".repeat(40),
        short_sha: "1111111111",
        subject: "Merge Epic #9 via Syrus merge-train",
        authored_at: "2026-08-22T10:00:00Z",
        classification: "epic_landed",
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        jobs: [
          { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
          { id: 43, slug: "JOB-43", title: "Add light mode toggle" }
        ]
      },
      {
        sha: "2".repeat(40),
        short_sha: "2222222222",
        subject: "Implement dark mode toggle",
        authored_at: "2026-08-22T09:00:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 3, display_name: "Ada Lovelace" }
      },
      {
        sha: "3".repeat(40),
        short_sha: "3333333333",
        subject: "Autofix dark mode formatting",
        authored_at: "2026-08-22T08:50:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 3, display_name: "Ada Lovelace" }
      },
      {
        sha: "4".repeat(40),
        short_sha: "4444444444",
        subject: "Implement light mode toggle",
        authored_at: "2026-08-22T08:00:00Z",
        classification: "syrus_landed",
        job: { id: 43, slug: "JOB-43", title: "Add light mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 4, display_name: "Grace Hopper" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Merge Epic #9 via Syrus merge-train")).toBeInTheDocument()
    expect(await screen.findByText("Implement dark mode toggle")).toBeInTheDocument()
    expect(screen.getByText("Autofix dark mode formatting")).toBeInTheDocument()
    expect(screen.getByText("Implement light mode toggle")).toBeInTheDocument()

    // A single top-level list item for the whole Epic -- both jobs' own
    // commits are nested underneath it, not flattened into separate
    // top-level rows.
    expect(screen.getAllByRole("listitem")).toHaveLength(1)

    const job42Links = screen.getAllByRole("link", { name: "JOB-42" })
    expect(job42Links.length).toBeGreaterThan(0)
    for (const link of job42Links) expect(link).toHaveAttribute("href", "/jobs/42")
  })

  it("groups a reconciliation commit under its Epic group, not attached to any member Job", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "1".repeat(40),
        short_sha: "1111111111",
        subject: "Merge Epic #9 via Syrus merge-train",
        authored_at: "2026-08-22T10:00:00Z",
        classification: "epic_landed",
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        jobs: [{ id: 42, slug: "JOB-42", title: "Add dark mode toggle" }]
      },
      {
        sha: "2".repeat(40),
        short_sha: "2222222222",
        subject: "Syrus merge-train reconciliation",
        authored_at: "2026-08-22T09:30:00Z",
        classification: "epic_reconciliation",
        epic: { id: 9, slug: "EPIC-9", title: "Theming" }
      },
      {
        sha: "3".repeat(40),
        short_sha: "3333333333",
        subject: "Implement dark mode toggle",
        authored_at: "2026-08-22T09:00:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 3, display_name: "Ada Lovelace" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Syrus merge-train reconciliation")).toBeInTheDocument()
    expect(screen.getByText("Implement dark mode toggle")).toBeInTheDocument()

    // Everything collapses into the Epic's single top-level group.
    expect(screen.getAllByRole("listitem")).toHaveLength(1)

    // Exactly two JOB-42 links exist: the epic_landed row's inline member
    // link, and JOB-42's own nested implementation commit. The
    // reconciliation row contributes none -- it belongs to the Epic only.
    expect(screen.getAllByRole("link", { name: "JOB-42" })).toHaveLength(2)
  })

  it("renders a legacy-fallback syrus_landed commit (pre-migration history, no LandedCommit row) identically to a normal one", async () => {
    // CommitAttributor's legacy fallback (matching Job#landed_sha directly)
    // produces the exact same "syrus_landed" wire shape as the new
    // LandedCommit-backed path -- there is no marker distinguishing the two,
    // so the frontend has nothing special to do and should render this
    // exactly like the standard Syrus-landed case.
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "a".repeat(40),
        short_sha: "aaaaaaaaaa",
        subject: "Add dark mode toggle",
        authored_at: "2026-08-20T10:00:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: { id: 9, slug: "EPIC-9", title: "Theming" },
        user: { id: 3, display_name: "Ada Lovelace" },
        origin: { type: "github_issue", issue_number: 12, issue_url: "https://github.com/acme/widgets/issues/12" }
      }
    ])))

    renderRoute(<GitHistory />)

    expect(await screen.findByText("Add dark mode toggle")).toBeInTheDocument()
    expect(screen.getByText("Syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "EPIC-9" })).toHaveAttribute("href", "/epics/9")
    expect(screen.getByText("by Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Issue #12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
  })

  it("visually de-emphasizes external commits relative to Syrus-attributed ones", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      {
        sha: "a".repeat(40),
        short_sha: "aaaaaaaaaa",
        subject: "Add dark mode toggle",
        authored_at: "2026-08-20T10:00:00Z",
        classification: "syrus_landed",
        job: { id: 42, slug: "JOB-42", title: "Add dark mode toggle" },
        epic: null,
        user: { id: 3, display_name: "Ada Lovelace" }
      },
      {
        sha: "b".repeat(40),
        short_sha: "bbbbbbbbbb",
        subject: "Fix typo in readme",
        authored_at: "2026-08-19T10:00:00Z",
        classification: "external_pr",
        job: { id: 100, slug: "JOB-100", title: "external contribution" },
        pr_number: 55,
        pr_url: "https://github.com/acme/widgets/pull/55",
        github_author: "octocat",
        author: { name: "octocat", email: "octocat@example.com" },
        committer: { name: "octocat", email: "octocat@example.com" }
      }
    ])))

    renderRoute(<GitHistory />)

    const syrusSubject = await screen.findByText("Add dark mode toggle")
    const externalSubject = await screen.findByText("Fix typo in readme")

    expect(syrusSubject.className).toContain("font-semibold")
    expect(externalSubject.className).not.toContain("font-semibold")
    expect(externalSubject.className).toContain("font-normal")
  })
})
