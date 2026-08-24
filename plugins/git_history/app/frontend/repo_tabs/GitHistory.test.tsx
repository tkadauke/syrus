import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { GitHistory } from "./GitHistory"
import type { GitHistoryCommit, GitHistoryPage } from "../api/gitHistory"

describe("GitHistory", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("renders a Syrus-landed commit with its epic, job, user, and issue origin", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      syrusLandedCommit({
        sha: "a1b2c3d4e5",
        job: { id: 42, slug: "job-42", title: "Fix the thing" },
        epic: { id: 7, slug: "epic-7", title: "Big epic" },
        user: { id: 3, display_name: "Ada Lovelace" },
        origin: { type: "github_issue", issue_number: 99, issue_url: "https://github.com/acme/widgets/issues/99" }
      })
    ])))

    renderGitHistory()

    expect(await screen.findByText("Syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/7")
    expect(screen.getByText("by Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "#99" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/99")
  })

  it("renders an externally-opened PR commit distinctly from Syrus-landed commits", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      externalPrCommit({
        sha: "f6e5d4c3b2",
        pr_number: 55,
        pr_url: "https://github.com/acme/widgets/pull/55",
        github_author: "octocat"
      })
    ])))

    renderGitHistory()

    expect(await screen.findByText("External PR")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "PR #55" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/55")
    expect(screen.getByText("by octocat")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /^JOB-/ })).not.toBeInTheDocument()
  })

  it("renders a raw external push commit with git author info and no Job/Epic links", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      externalPushCommit({
        sha: "0011223344",
        author: { name: "Author Name", email: "author@example.com" }
      })
    ])))

    renderGitHistory()

    expect(await screen.findByText("External push")).toBeInTheDocument()
    expect(screen.getByText("by Author Name")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /^JOB-/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /^EPIC-/ })).not.toBeInTheDocument()
  })

  it("does not render a chat link when the API omits chat_session_id", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      syrusLandedCommit({
        sha: "5566778899",
        job: { id: 12, slug: "job-12", title: "Ship it quietly" },
        epic: null,
        user: { id: 1, display_name: "Owner" },
        origin: { type: "chat" }
      })
    ])))

    renderGitHistory()

    expect(await screen.findByRole("link", { name: "JOB-12" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "View chat" })).not.toBeInTheDocument()
  })

  it("renders a chat link when the API includes chat_session_id", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(page([
      syrusLandedCommit({
        sha: "aabbccddee",
        job: { id: 13, slug: "job-13", title: "Ship it" },
        epic: null,
        user: { id: 1, display_name: "Owner" },
        origin: { type: "chat", chat_session_id: 88, chat_title: "Ship the thing" }
      })
    ])))

    renderGitHistory()

    expect(await screen.findByRole("link", { name: "View chat" })).toHaveAttribute("href", "/chats/88")
  })
})

function renderGitHistory() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={["/repositories/9/plugin/git_history"]}>
        <Routes>
          <Route element={<GitHistory />} path="/repositories/:repositoryId/plugin/git_history" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function page(commits: GitHistoryCommit[]): GitHistoryPage {
  return {
    repository: { id: 9, slug: "acme/widgets" },
    available: true,
    commits,
    next_cursor: null,
    has_more: false
  }
}

function syrusLandedCommit(overrides: Partial<Extract<GitHistoryCommit, { classification: "syrus_landed" }>> = {}) {
  return {
    classification: "syrus_landed" as const,
    sha: "sha-syrus",
    short_sha: "sha-syru",
    subject: "Fix the thing",
    authored_at: "2026-08-20T12:00:00Z",
    job: { id: 1, slug: "job-1", title: "Fix the thing" },
    epic: null,
    user: { id: 1, display_name: "Owner" },
    origin: { type: "unknown" as const },
    ...overrides
  }
}

function externalPrCommit(overrides: Partial<Extract<GitHistoryCommit, { classification: "external_pr" }>> = {}) {
  return {
    classification: "external_pr" as const,
    sha: "sha-pr",
    short_sha: "sha-pr12",
    subject: "External contribution",
    authored_at: "2026-08-19T12:00:00Z",
    job: { id: 2, slug: "job-2", title: "External contribution" },
    pr_number: 1,
    pr_url: null,
    author: { name: "Someone", email: "someone@example.com" },
    committer: { name: "Someone", email: "someone@example.com" },
    github_author: "someone",
    ...overrides
  }
}

function externalPushCommit(overrides: Partial<Extract<GitHistoryCommit, { classification: "external_push" }>> = {}) {
  return {
    classification: "external_push" as const,
    sha: "sha-push",
    short_sha: "sha-push1",
    subject: "Raw push straight to main",
    authored_at: "2026-08-18T12:00:00Z",
    author: { name: "Pusher", email: "pusher@example.com" },
    committer: { name: "Pusher", email: "pusher@example.com" },
    ...overrides
  }
}
