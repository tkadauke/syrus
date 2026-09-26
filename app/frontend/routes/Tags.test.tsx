import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import * as useConfirmModule from "../hooks/useConfirm"
import { Tags } from "./Tags"

function mockUseConfirm(confirmed: boolean) {
  const mockConfirm = vi.fn<ReturnType<typeof useConfirmModule.useConfirm>["confirm"]>().mockResolvedValue(confirmed)
  vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm, dialog: <></> })
  return mockConfirm
}

function tagsPayload(overrides: Record<string, unknown> = {}) {
  return {
    palette: [
      { key: "gray", label: "Gray", bg: "bg-gray-100", text: "text-gray-800" },
      { key: "red", label: "Red", bg: "bg-red-100", text: "text-red-800" }
    ],
    tags: [
      { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" }
    ],
    ...overrides
  }
}

function renderRoute() {
  renderRouteAt("/tags")
}

function renderRouteAt(entry: string, payload?: Record<string, unknown>) {
  if (payload) vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[entry]}>
        <Tags />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function tagRows() {
  return screen.getAllByRole("row").slice(1).map((row) => row.textContent || "")
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function encodeFilterTree(tree: Record<string, unknown>) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(tree)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

describe("Tags", () => {
  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("opens the shared confirm dialog before deleting a tag", async () => {
    const mockConfirm = mockUseConfirm(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/tags/4" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(tagsPayload({ tags: [], message: "Tag deleted." })))
      }
      return Promise.resolve(jsonResponse(tagsPayload()))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true })))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/tags/4", expect.objectContaining({ method: "DELETE" }))
    })
    expect(await screen.findByText("No tags yet.")).toBeInTheDocument()
  })

  it("does not delete when the shared confirm dialog is cancelled", async () => {
    const mockConfirm = mockUseConfirm(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(tagsPayload()))

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalled())
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/tags/4", expect.anything())
  })

  it("filters tags through the shared FilterBar", async () => {
    renderRouteAt("/tags", tagsPayload({
      tags: [
        { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
        { id: 5, name: "frontend", color: "red", jobs_count: 7, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-02-02T00:00:00Z" }
      ]
    }))

    expect(await screen.findByText("urgent")).toBeInTheDocument()
    expect(screen.getByText("frontend")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "front" } })
    fireEvent.click(screen.getByRole("button", { name: "Search for front" }))

    await waitFor(() => {
      expect(screen.queryByText("urgent")).not.toBeInTheDocument()
    })
    expect(screen.getByText("frontend")).toBeInTheDocument()
  })

  it("honors OR FilterBar groups when filtering tags", async () => {
    const q = encodeFilterTree({
      and: [{
        or: [
          { field: "query", op: "contains", value: "urgent" },
          { field: "query", op: "contains", value: "frontend" }
        ]
      }]
    })
    renderRouteAt(`/tags?q=${q}`, tagsPayload({
      tags: [
        { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
        { id: 5, name: "frontend", color: "red", jobs_count: 7, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-02-02T00:00:00Z" },
        { id: 6, name: "backend", color: "gray", jobs_count: 1, created_at: "2026-03-01T00:00:00Z", updated_at: "2026-03-02T00:00:00Z" }
      ]
    }))

    await waitFor(() => {
      expect(tagRows().join(" ")).toContain("urgent")
    })
    expect(tagRows().join(" ")).toContain("frontend")
    expect(tagRows().join(" ")).not.toContain("backend")
  })

  it("filters tags by explicit name and timestamp fields", async () => {
    const q = encodeFilterTree({
      and: [
        { field: "name", op: "contains", value: "front" },
        { field: "created_at", op: "after", value: "2026-01-15" }
      ]
    })
    renderRouteAt(`/tags?q=${q}`, tagsPayload({
      tags: [
        { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
        { id: 5, name: "frontend", color: "red", jobs_count: 7, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-02-02T00:00:00Z" }
      ]
    }))

    expect(await screen.findByText("frontend")).toBeInTheDocument()
    expect(screen.queryByText("urgent")).not.toBeInTheDocument()
  })

  it("sorts tags by jobs count", async () => {
    renderRouteAt("/tags", tagsPayload({
      tags: [
        { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
        { id: 5, name: "frontend", color: "red", jobs_count: 7, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-02-02T00:00:00Z" }
      ]
    }))

    await screen.findByText("frontend")
    fireEvent.click(screen.getByRole("button", { name: /Jobs/ }))

    await waitFor(() => {
      expect(tagRows()[0]).toContain("urgent")
    })

    fireEvent.click(screen.getByRole("button", { name: /Jobs/ }))
    expect(tagRows()[0]).toContain("frontend")
  })

  it("hides columns from the selector and reorders visible headers by drag", async () => {
    renderRouteAt("/tags", tagsPayload({
      tags: [
        { id: 4, name: "urgent", color: "gray", jobs_count: 2, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z" },
        { id: 5, name: "frontend", color: "red", jobs_count: 7, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-02-02T00:00:00Z" }
      ]
    }))

    await screen.findByText("urgent")
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Jobs"))

    expect(screen.queryByRole("columnheader", { name: /Jobs/ })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Jobs"))
    const colorCheckbox = screen.getAllByLabelText("Color").find((element) => element instanceof HTMLInputElement && element.type === "checkbox")
    expect(colorCheckbox).toBeDefined()
    fireEvent.click(colorCheckbox!)
    const jobsHeader = screen.getByRole("columnheader", { name: /Jobs/ })
    const colorHeader = screen.getByRole("columnheader", { name: /Color/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(jobsHeader, { dataTransfer: transfer })
    fireEvent.dragOver(colorHeader, { dataTransfer: transfer })
    fireEvent.drop(colorHeader, { dataTransfer: transfer })

    const headers = screen.getAllByRole("columnheader").map((header) => header.textContent)
    expect(headers).toEqual(["Tag", "Color", "Jobs", "Rename / recolor", "Actions"])
  })
})
