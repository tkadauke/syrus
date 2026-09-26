import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import * as useConfirmModule from "../hooks/useConfirm"

function documentsPayload(overrides: Record<string, unknown> = {}) {
  return {
    documents: [
      {
        id: 30,
        kind: "file",
        google_doc_url: null,
        filename: "notes.pdf",
        content_type: "application/pdf",
        byte_size: 2048,
        source_url: null,
        content_cache_state: "empty",
        content_cached_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/credentials/documents/30/file"
      }
    ],
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(documentsPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <PersonalDocumentsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function renderRouteWithDocuments(documents: Record<string, unknown>[], rawContent: Record<string, string> = {}) {
  const payload = documentsPayload({ documents })
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    const fileMatch = url.match(/\/credentials\/documents\/(\d+)\/file$/)
    if (fileMatch) {
      return Promise.resolve(new Response(rawContent[fileMatch[1]] ?? "", { status: 200 }))
    }
    return Promise.resolve(jsonResponse(payload))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <PersonalDocumentsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchSpy
}

function renderRouteWithDocumentsAt(documents: Record<string, unknown>[], entry = "/documents") {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(documentsPayload({ documents })))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[entry]}>
        <PersonalDocumentsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function documentRows() {
  return screen.getAllByRole("row").slice(1).map((row) => row.textContent || "")
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function encodeFilterTree(tree: Record<string, unknown>) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(tree)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const TABLE_DOCUMENTS = [
  {
    id: 41,
    kind: "file",
    google_doc_url: null,
    filename: "z-notes.md",
    content_type: "text/markdown",
    byte_size: 1024,
    source_url: null,
    content_cache_state: "empty",
    content_cached_at: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    file_path: "/api/v1/app/credentials/documents/41/file"
  },
  {
    id: 42,
    kind: "file",
    google_doc_url: null,
    filename: "screenshot.png",
    content_type: "image/png",
    byte_size: 512,
    source_url: "https://example.test/screenshot.png",
    content_cache_state: "empty",
    content_cached_at: null,
    created_at: "2026-01-02T00:00:00Z",
    updated_at: "2026-01-03T00:00:00Z",
    file_path: "/api/v1/app/credentials/documents/42/file"
  },
  {
    id: 43,
    kind: "google_doc",
    google_doc_url: "https://docs.google.com/document/d/a-plan/edit",
    filename: null,
    content_type: null,
    byte_size: null,
    source_url: "https://docs.google.com/document/d/a-plan/edit",
    content_cache_state: "cached",
    content_cached_at: "2026-01-04T00:00:00Z",
    created_at: "2025-12-31T00:00:00Z",
    updated_at: "2026-01-04T00:00:00Z",
    file_path: null
  }
]

describe("PersonalDocumentsRoute delete", () => {
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
      if (url === "/api/v1/app/credentials/documents/30" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(documentsPayload({ documents: [], message: "Document removed." })))
      }
      return Promise.resolve(jsonResponse(documentsPayload()))
    })

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    fireEvent.click(deleteButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/documents/30",
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
      "/api/v1/app/credentials/documents/30",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})

describe("PersonalDocumentsRoute table controls", () => {
  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("filters documents through the shared FilterBar", async () => {
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS)

    expect(await screen.findByRole("button", { name: /z-notes\.md/ })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /screenshot\.png/ })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "shot" } })
    fireEvent.click(screen.getByRole("button", { name: "Search for shot" }))

    await waitFor(() => {
      expect(screen.queryByRole("button", { name: /z-notes\.md/ })).not.toBeInTheDocument()
    })
    expect(screen.getByRole("button", { name: /screenshot\.png/ })).toBeInTheDocument()
  })

  it("honors negated FilterBar groups when filtering documents", async () => {
    const q = encodeFilterTree({ and: [{ not: { field: "kind", op: "is", value: "file" } }] })
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS, `/documents?q=${q}`)

    expect(await screen.findByRole("button", { name: /Google Doc/ })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /z-notes\.md/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /screenshot\.png/ })).not.toBeInTheDocument()
  })

  it("filters documents by cache state, source URL, and created date fields", async () => {
    const q = encodeFilterTree({
      and: [
        { field: "content_cache_state", op: "is", value: "cached" },
        { field: "source_url", op: "contains", value: "docs.google.com" },
        { field: "created_at", op: "before", value: "2026-01-01" }
      ]
    })
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS, `/documents?q=${q}`)

    expect(await screen.findByRole("button", { name: /Google Doc/ })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /z-notes\.md/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /screenshot\.png/ })).not.toBeInTheDocument()
  })

  it("sorts documents by an eligible column", async () => {
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS)

    expect((await screen.findByRole("button", { name: /screenshot\.png/ })).closest("tr")).toBe(documentRowsElements()[0])

    fireEvent.click(screen.getByRole("button", { name: /Document/ }))

    await waitFor(() => {
      expect(documentRows()[0]).toContain("https://docs.google.com/document/d/a-plan/edit")
    })
  })

  it("hides columns from the selector and reorders visible headers by drag", async () => {
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS)
    await screen.findByRole("button", { name: /screenshot\.png/ })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Kind"))

    expect(screen.queryByRole("columnheader", { name: /Kind/ })).not.toBeInTheDocument()

    fireEvent.click(screen.getByLabelText("Kind"))
    const kindHeader = screen.getByRole("columnheader", { name: /Kind/ })
    const createdHeader = screen.getByRole("columnheader", { name: /Created/ })
    const transfer = dataTransfer()

    fireEvent.dragStart(kindHeader, { dataTransfer: transfer })
    fireEvent.dragOver(createdHeader, { dataTransfer: transfer })
    fireEvent.drop(createdHeader, { dataTransfer: transfer })

    const headers = screen.getAllByRole("columnheader").map((header) => header.textContent)
    expect(headers).toEqual(["Document", "Size", "Kind", "Created", "Actions"])
  })
})

function documentRowsElements() {
  return screen.getAllByRole("row").slice(1)
}

describe("PersonalDocumentsRoute preview", () => {
  afterEach(() => vi.restoreAllMocks())

  it("opens a preview modal with rendered markdown for a markdown document", async () => {
    renderRouteWithDocuments([
      {
        id: 31,
        kind: "file",
        google_doc_url: null,
        filename: "notes.md",
        content_type: "text/markdown",
        byte_size: 12,
        source_url: null,
        content_cache_state: "empty",
        content_cached_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/credentials/documents/31/file"
      }
    ], { "31": "# Hello there" })

    fireEvent.click(await screen.findByRole("button", { name: /notes\.md/ }))

    expect(await screen.findByRole("heading", { name: "Hello there", level: 1 })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/credentials/documents/31/file")
  })

  it("renders an image document inline without fetching its content as text", async () => {
    const fetchSpy = renderRouteWithDocuments([
      {
        id: 32,
        kind: "file",
        google_doc_url: null,
        filename: "screenshot.png",
        content_type: "image/png",
        byte_size: 512,
        source_url: null,
        content_cache_state: "empty",
        content_cached_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/credentials/documents/32/file"
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /screenshot\.png/ }))

    const image = await screen.findByRole("img", { name: "screenshot.png" })
    expect(image).toHaveAttribute("src", "/api/v1/app/credentials/documents/32/file")
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/credentials/documents/32/file", expect.anything())
  })

  it("opens PDF documents directly in a new tab instead of the preview modal", async () => {
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null)
    renderRouteWithDocuments([
      {
        id: 33,
        kind: "file",
        google_doc_url: null,
        filename: "notes.pdf",
        content_type: "application/pdf",
        byte_size: 2048,
        source_url: null,
        content_cache_state: "empty",
        content_cached_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/credentials/documents/33/file"
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /notes\.pdf/ }))

    await waitFor(() => {
      expect(openSpy).toHaveBeenCalledWith("/api/v1/app/credentials/documents/33/file", "_blank", "noopener")
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("opens Google Docs directly in a new tab instead of the preview modal", async () => {
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null)
    renderRouteWithDocuments([
      {
        id: 34,
        kind: "google_doc",
        google_doc_url: "https://docs.google.com/document/d/personal/edit",
        filename: null,
        content_type: null,
        byte_size: null,
        source_url: "https://docs.google.com/document/d/personal/edit",
        content_cache_state: "cached",
        content_cached_at: "2026-01-01T00:00:00Z",
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: null
      }
    ])

    fireEvent.click(await screen.findByRole("button", { name: /Google Doc/ }))

    await waitFor(() => {
      expect(openSpy).toHaveBeenCalledWith("https://docs.google.com/document/d/personal/edit", "_blank", "noopener")
    })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})
