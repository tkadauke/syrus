import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoriesIndex } from "./Repositories"
import * as useConfirmModule from "../hooks/useConfirm"

function repositoryRow() {
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
    last_poll_status: null,
    last_poll_started_at: null,
    last_poll_error: null,
    repository_path: "/repositories/1",
    edit_repository_path: "/repositories/1/edit"
  }
}

function repositoriesPayload(overrides: Record<string, unknown> = {}) {
  return {
    active_repositories: [repositoryRow()],
    archived_repositories: [],
    new_repository_path: "/repositories/new",
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

describe("RepositoriesIndex archive", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when archiving a repository", async () => {
    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the archive API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repositories/1/archive" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(repositoriesPayload({ active_repositories: [], message: "Repository archived." })))
      }
      return Promise.resolve(jsonResponse(repositoriesPayload()))
    })

    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    fireEvent.click(archiveButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/1/archive",
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("does not call the archive API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(repositoriesPayload()))

    renderRoute()

    const archiveButton = await screen.findByRole("button", { name: "Archive" })
    await act(async () => { fireEvent.click(archiveButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/repositories/1/archive",
      expect.objectContaining({ method: "POST" })
    )
  })
})
