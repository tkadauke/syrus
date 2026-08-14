import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { SearchRoute } from "./Search"

// Stub preview cards so tests don't trigger live API calls from SlugHoverCard
vi.mock("../components/JobPreviewCard", () => ({
  JobPreviewCard: () => <div />,
  JobPreviewSkeleton: () => <div />,
}))
vi.mock("../components/EpicPreviewCard", () => ({
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
