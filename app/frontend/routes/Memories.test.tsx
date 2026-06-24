import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { MemoriesRoute } from "./Memories"

describe("MemoriesRoute", () => {
  it("renders filters, admin owner column, rows, and pagination", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(memoriesPayload({
      current_user: { id: 1, admin: true },
      pagination: { page: 1, per_page: 20, total: 21, total_pages: 2 }
    })))

    renderRoute(<MemoriesRoute />, "/app-shell/memories")

    expect(await screen.findByText("Use Rails for the app.")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Owner" })).toBeInTheDocument()
    expect(screen.getAllByText("acme/widgets").length).toBeGreaterThan(0)
    expect(screen.getByText("Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByText("Use Rails for the app.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create memory" })).toBeInTheDocument()
    expect(screen.getByText("Showing 1-20 of 21")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Next" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/memories", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("updates query params when filters are applied", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(memoriesPayload()))

    renderRoute(
      <Routes>
        <Route element={<MemoriesRoute />} path="/app-shell/memories" />
      </Routes>,
      "/app-shell/memories"
    )

    await screen.findByText("Use Rails for the app.")
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "published" } })
    fireEvent.click(screen.getByRole("button", { name: "Published boolean" }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some(([url]) => String(url).startsWith("/api/v1/app/memories?q="))).toBe(true)
    })
  })

  it("creates, edits, publishes, and deletes through the API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/memories" && init?.method === "POST") return Promise.resolve(jsonResponse(memoriesPayload({ message: "Memory created." })))
      if (url === "/api/v1/app/memories/10" && init?.method === "PATCH") return Promise.resolve(jsonResponse(memoriesPayload({ message: "Memory updated." })))
      if (url === "/api/v1/app/memories/10/publish" && init?.method === "POST") return Promise.resolve(jsonResponse(memoriesPayload({ message: "Memory published." })))
      if (url === "/api/v1/app/memories/10" && init?.method === "DELETE") return Promise.resolve(jsonResponse(memoriesPayload({ memories: [], message: "Memory deleted." })))
      return Promise.resolve(jsonResponse(memoriesPayload()))
    })
    vi.spyOn(window, "confirm").mockReturnValue(true)

    renderRoute(<MemoriesRoute />, "/app-shell/memories")

    await screen.findByText("Use Rails for the app.")
    fireEvent.click(screen.getByRole("button", { name: "Create memory" }))
    const createDialog = await screen.findByRole("dialog", { name: "Create memory" })
    fireEvent.change(within(createDialog).getByLabelText("Content"), { target: { value: "Remember this." } })
    fireEvent.click(within(createDialog).getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/memories", expect.objectContaining({ method: "POST" }))
    })

    const row = screen.getByText("Use Rails for the app.").closest("tr") as HTMLElement
    fireEvent.click(within(row).getByRole("button", { name: "Edit" }))
    const editDialog = await screen.findByRole("dialog", { name: "Edit memory" })
    fireEvent.change(within(editDialog).getByLabelText("Content"), { target: { value: "Use Rails and Vite." } })
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/memories/10", expect.objectContaining({ method: "PATCH" }))
    })

    fireEvent.click(screen.getByRole("button", { name: "Publish" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/memories/10/publish", expect.objectContaining({ method: "POST" }))
    })

    fireEvent.click(within(row).getByRole("button", { name: "Delete" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/memories/10", expect.objectContaining({ method: "DELETE" }))
    })
  })
})

function renderRoute(children: ReactNode, path: string) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function memoriesPayload(overrides: Record<string, unknown> = {}) {
  return {
    memories: [
      {
        id: 10,
        kind: "project_fact",
        scope: "repository",
        scope_id: 3,
        repository_name: "acme/widgets",
        content: "Use Rails for the app.",
        published: false,
        created_at: "2026-06-23T12:00:00Z",
        updated_at: "2026-06-23T12:00:00Z",
        owner: { id: 2, name: "Ada Lovelace" },
        permissions: { can_manage: true, can_publish: true },
        paths: {
          app_memory_path: "/api/v1/app/memories/10",
          app_publish_path: "/api/v1/app/memories/10/publish"
        }
      }
    ],
    kinds: ["user_pref", "project_fact", "feedback", "reference", "decision"],
    scopes: ["global", "repository"],
    repositories: [{ id: 3, name: "acme/widgets" }],
    filter: { and: [] },
    controls: {
      filter_schema: [
        { field: "content", label: "Content", bucket: "string", operators: ["contains"] },
        { field: "scope", label: "Scope", bucket: "enum", operators: ["is"], values: [{ value: "global", label: "Global" }, { value: "repository", label: "Repository" }] },
        { field: "kind", label: "Kind", bucket: "enum", operators: ["is"], values: [{ value: "project_fact", label: "Project fact" }] },
        { field: "repository_id", label: "Repository", bucket: "fk", operators: ["is"], typeahead: true },
        { field: "published", label: "Published", bucket: "boolean", operators: ["is_true", "is_false"] }
      ]
    },
    current_user: { id: 1, admin: false },
    pagination: { page: 1, per_page: 20, total: 1, total_pages: 1 },
    ...overrides
  }
}
