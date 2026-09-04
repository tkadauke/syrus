import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { SearchRoute } from "./Search"

// Stub preview cards so tests don't trigger live API calls from SlugHoverCard
vi.mock("@app/components/JobPreviewCard", () => ({
  JobPreviewCard: () => <div />,
  JobPreviewSkeleton: () => <div />,
}))
vi.mock("@app/components/EpicPreviewCard", () => ({
  EpicPreviewCard: () => <div />,
  EpicPreviewSkeleton: () => <div />,
}))

function searchPayload(results: unknown[]) {
  return {
    results,
    filter: null,
    controls: { filter_schema: [] }
  }
}

function renderRoute(results: unknown[]) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(searchPayload(results)))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/search?query=preview+environment"]}>
        <SearchRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("SearchRoute result rows", () => {
  it("renders a copyable job slug for job results", async () => {
    renderRoute([
      {
        type: "job",
        id: 3037,
        slug: "JOB-3037",
        title: "Reviewer-facing preview UI",
        snippet: "preview environments",
        rank: 0,
        path: "/jobs/3037",
        state: "closed",
        repository_slug: "tkadauke/syrus",
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    expect(await screen.findByRole("button", { name: /JOB-3037/ })).toBeInTheDocument()
  })

  it("renders a copyable epic slug for epic results", async () => {
    renderRoute([
      {
        type: "epic",
        id: 42,
        slug: "EPIC-7",
        title: "Preview Environments",
        snippet: "preview environments",
        rank: 0,
        path: "/epics/42",
        state: "done",
        repository_slug: "tkadauke/syrus",
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    expect(await screen.findByRole("button", { name: /EPIC-7/ })).toBeInTheDocument()
  })

  it("does not render a copyable slug for chat results", async () => {
    renderRoute([
      {
        type: "chat",
        id: 9,
        title: "Syrus Plugin Architecture Design",
        snippet: "preview environments",
        rank: 0,
        path: "/chats/9",
        state: null,
        repository_slug: null,
        created_at: "2026-01-01T00:00:00Z"
      }
    ])

    await screen.findByText("Syrus Plugin Architecture Design")
    expect(screen.queryByRole("button", { name: /copy/i })).not.toBeInTheDocument()
  })
})

function chatGroupPayload(results = [
  {
    type: "chat",
    id: 11,
    title: "Forum planning",
    snippet: "Best <mark>needle</mark>",
    rank: 0,
    path: "/chats/77?message_id=11",
    state: null,
    repository_slug: null,
    created_at: "2026-06-20T10:00:00Z",
    grouped_matches: [
      { id: 12, snippet: "Second <mark>needle</mark>", path: "/chats/77?message_id=12", created_at: "2026-06-20T10:01:00Z" },
      { id: 13, snippet: "Third <mark>needle</mark>", path: "/chats/77?message_id=13", created_at: "2026-06-20T10:02:00Z" }
    ],
    total_match_count: 4,
    has_more_matches: true
  }
]) {
  return {
    results,
    filter: null,
    controls: {
      filter_schema: [
        { field: "repository_id", label: "Repository", bucket: "fk", operators: [ "is", "is_not", "is_one_of", "is_none_of" ], typeahead: true },
        { field: "created_at", label: "Created", bucket: "date", operators: [ "before", "after", "between", "within_last", "more_than_ago", "is_set", "is_unset" ], values: [] },
        { field: "updated_at", label: "Updated", bucket: "date", operators: [ "before", "after", "between", "within_last", "more_than_ago", "is_set", "is_unset" ], values: [] }
      ]
    }
  }
}

function renderWithPayload(payload: unknown) {
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
    const path = String(input)
    if (path.startsWith("/api/v1/app/filters/fk_options")) {
      return Promise.resolve(jsonResponse({ options: [] }))
    }
    if (path.startsWith("/api/v1/app/search")) {
      return Promise.resolve(jsonResponse(payload))
    }
    return Promise.resolve(jsonResponse({}))
  })

  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ "/search?query=needle" ]}>
        <SearchRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )

  return fetchSpy
}

describe("SearchRoute results", () => {
  it("renders grouped chat matches", async () => {
    renderWithPayload(chatGroupPayload())

    expect(await screen.findByRole("link", { name: "Forum planning" })).toHaveAttribute("href", "/chats/77?message_id=11")
    expect(screen.getByText((_content, element) => element?.textContent === "Best needle")).toBeInTheDocument()
    expect(screen.getByText("3 more matches in this chat")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show 2 more matches" }))

    expect(await screen.findByText((_content, element) => element?.textContent === "Second needle")).toBeInTheDocument()
    expect(screen.getByText((_content, element) => element?.textContent === "Third needle")).toBeInTheDocument()
    expect(screen.getByText("Only the top 2 additional matches are shown.")).toBeInTheDocument()
  })

  it("treats a malformed results payload as empty instead of crashing", async () => {
    renderWithPayload({ results: { items: [] }, filter: null, controls: { filter_schema: [] } })

    expect(await screen.findByText("No results match this search.")).toBeInTheDocument()
  })

  it("keeps the search term when applying filters", async () => {
    const fetchSpy = renderWithPayload(chatGroupPayload())

    await screen.findByRole("link", { name: "Forum planning" })
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.click(screen.getByRole("button", { name: "Repository reference" }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => {
        const path = String(call[0])
        return path.startsWith("/api/v1/app/search?") && path.includes("query=needle") && path.includes("q=")
      })).toBe(true)
    })
  })
})
