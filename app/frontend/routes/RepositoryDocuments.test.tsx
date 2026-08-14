import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { RepositoryDocumentsRoute } from "./RepositoryDocuments"
import * as useConfirmModule from "../hooks/useConfirm"

function documentsPayload(overrides: Record<string, unknown> = {}) {
  return {
    repository: { id: 1, slug: "acme/widgets", repository_path: "/repositories/1" },
    tabs: [],
    documents: [
      {
        id: 20,
        kind: "file",
        title: "Architecture notes",
        google_doc_url: null,
        filename: "architecture.pdf",
        content_type: "application/pdf",
        byte_size: 1024,
        uploaded_by: "Ada Lovelace",
        created_at: "2026-01-01T00:00:00Z"
      }
    ],
    accepted_file_content_types: ["image/*", "application/pdf"],
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(documentsPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/documents"]}>
        <Routes>
          <Route element={<RepositoryDocumentsRoute />} path="/app-shell/repositories/:repositoryId/documents" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function renderRouteWithDocuments(documents: Record<string, unknown>[], rawContent: Record<string, string> = {}) {
  const payload = documentsPayload({ documents })
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    const fileMatch = url.match(/\/repository_documents\/(\d+)\/file$/)
    if (fileMatch) {
      return Promise.resolve(new Response(rawContent[fileMatch[1]] ?? "", { status: 200 }))
    }
    return Promise.resolve(jsonResponse(payload))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/documents"]}>
        <Routes>
          <Route element={<RepositoryDocumentsRoute />} path="/app-shell/repositories/:repositoryId/documents" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

describe("RepositoryDocumentsRoute delete", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when deleting a document", async () => {
    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the delete API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/repository_documents/20" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(documentsPayload({ documents: [], message: "Document removed." })))
      }
      return Promise.resolve(jsonResponse(documentsPayload()))
    })

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repository_documents/20",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(documentsPayload()))

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    await act(async () => { fireEvent.click(deleteButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/repository_documents/20",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})

describe("RepositoryDocumentsRoute preview", () => {
  afterEach(() => vi.restoreAllMocks())

  it("opens a preview modal with rendered markdown for a markdown document", async () => {
    renderRouteWithDocuments([
      {
        id: 21,
        kind: "file",
        title: "Notes",
        google_doc_url: null,
        filename: "notes.md",
        content_type: "text/markdown",
        byte_size: 12,
        uploaded_by: "Ada Lovelace",
        created_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/repository_documents/21/file"
      }
    ], { "21": "# Hello there" })

    fireEvent.click(await screen.findByRole("button", { name: /Notes/ }))

    expect(await screen.findByRole("heading", { name: "Hello there", level: 1 })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Preview" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Source" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/repository_documents/21/file")
  })

  it("renders an image document inline without fetching its content as text", async () => {
    const fetchSpy = renderRouteWithDocuments([
      {
        id: 22,
        kind: "file",
        title: "Screenshot",
        google_doc_url: null,
        filename: "screenshot.png",
        content_type: "image/png",
        byte_size: 512,
        uploaded_by: "Ada Lovelace",
        created_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/repository_documents/22/file"
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /Screenshot/ }))

    const image = await screen.findByRole("img", { name: "Screenshot" })
    expect(image).toHaveAttribute("src", "/api/v1/app/repository_documents/22/file")
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/repository_documents/22/file", expect.anything())
  })

  it("opens PDF documents directly in a new tab instead of the preview modal", async () => {
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null)
    renderRouteWithDocuments([
      {
        id: 23,
        kind: "file",
        title: "Architecture notes",
        google_doc_url: null,
        filename: "architecture.pdf",
        content_type: "application/pdf",
        byte_size: 1024,
        uploaded_by: "Ada Lovelace",
        created_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/repository_documents/23/file"
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /Architecture notes/ }))

    await waitFor(() => {
      expect(openSpy).toHaveBeenCalledWith("/api/v1/app/repository_documents/23/file", "_blank", "noopener")
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("opens Google Docs directly in a new tab instead of the preview modal", async () => {
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null)
    renderRouteWithDocuments([
      {
        id: 24,
        kind: "google_doc",
        title: "Launch plan",
        google_doc_url: "https://docs.google.com/document/d/launch/edit",
        filename: null,
        content_type: null,
        byte_size: null,
        uploaded_by: "Ada Lovelace",
        created_at: "2026-01-01T00:00:00Z",
        file_path: null
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /Launch plan/ }))

    await waitFor(() => {
      expect(openSpy).toHaveBeenCalledWith("https://docs.google.com/document/d/launch/edit", "_blank", "noopener")
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})
