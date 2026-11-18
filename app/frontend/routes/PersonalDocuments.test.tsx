import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import * as useConfirmModule from "../hooks/useConfirm"
import type { FilterNode } from "../components/filterBar/types"

function documentsPayload(overrides: Record<string, unknown> = {}) {
  const payload = {
    documents: [
      {
        id: 30,
        kind: "file",
        filename: "notes.pdf",
        content_type: "application/pdf",
        byte_size: 2048,
        source_url: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
        file_path: "/api/v1/app/credentials/documents/30/file",
        origin: { kind: "personal", chat: null }
      }
    ],
    ...overrides
  }
  const documents = (payload.documents as Array<Record<string, unknown>>).map((document) => ({
    origin: { kind: "personal", chat: null },
    ...document
  }))
  return {
    ...payload,
    documents,
    pagination: overrides.pagination || {
      page: 1,
      per_page: 25,
      total: documents.length,
      total_pages: documents.length > 0 ? 1 : 0,
      first_item: documents.length > 0 ? 1 : 0,
      last_item: documents.length
    }
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
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = new URL(String(input), "https://example.test")
    let result = [...documents]
    const encoded = url.searchParams.get("q")
    if (encoded) {
      const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/")
      const decoded = atob(`${normalized}${"=".repeat((4 - (normalized.length % 4)) % 4)}`)
      const tree = JSON.parse(new TextDecoder().decode(Uint8Array.from(decoded, (character) => character.charCodeAt(0))))
      result = result.filter((document) => testFilterMatches(document, tree))
    }
    const sort = url.searchParams.get("sort") || "created_at"
    const direction = url.searchParams.get("direction") || "descending"
    const value = (document: Record<string, unknown>) => (sort === "title" ? document.filename || "" : document[sort] || "")
    result.sort((left, right) => String(value(left)).localeCompare(String(value(right))) * (direction === "ascending" ? 1 : -1))
    return Promise.resolve(jsonResponse(documentsPayload({ documents: result })))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[entry]}>
        <PersonalDocumentsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function testFilterMatches(document: Record<string, unknown>, node: FilterNode): boolean {
  if ("and" in node && Array.isArray(node.and)) return node.and.every((child) => testFilterMatches(document, child))
  if ("or" in node && Array.isArray(node.or)) return node.or.some((child) => testFilterMatches(document, child))
  if ("not" in node && node.not) return !testFilterMatches(document, node.not)
  if (!("field" in node)) return true
  const raw =
    node.field === "query"
      ? Object.values(document)
          .filter((value) => typeof value === "string")
          .join(" ")
      : document[node.field]
  if (node.op === "before") return Date.parse(String(raw)) < Date.parse(String(node.value))
  if (node.op === "is") return String(raw) === String(node.value)
  if (node.op === "is_set") return raw != null && raw !== ""
  return String(raw || "")
    .toLowerCase()
    .includes(String(node.value || "").toLowerCase())
}

function documentRows() {
  return screen
    .getAllByRole("row")
    .slice(1)
    .map((row) => row.textContent || "")
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function encodeFilterTree(tree: Record<string, unknown>) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(tree))))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

const TABLE_DOCUMENTS = [
  {
    id: 41,
    kind: "file",
    filename: "z-notes.md",
    content_type: "text/markdown",
    byte_size: 1024,
    source_url: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    file_path: "/api/v1/app/credentials/documents/41/file"
  },
  {
    id: 42,
    kind: "file",
    filename: "screenshot.png",
    content_type: "image/png",
    byte_size: 512,
    source_url: "https://example.test/screenshot.png",
    created_at: "2026-01-02T00:00:00Z",
    updated_at: "2026-01-03T00:00:00Z",
    file_path: "/api/v1/app/credentials/documents/42/file"
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
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credentials/documents/30", expect.objectContaining({ method: "DELETE" }))
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(documentsPayload()))

    renderRoute()

    const deleteButton = await screen.findByRole("button", { name: "Delete" })
    await act(async () => {
      fireEvent.click(deleteButton)
    })

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/credentials/documents/30", expect.objectContaining({ method: "DELETE" }))
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

    expect(await screen.findByRole("button", { name: /screenshot\.png/ })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /z-notes\.md/ })).not.toBeInTheDocument()
  })

  it("honors negated FilterBar groups when filtering documents", async () => {
    const q = encodeFilterTree({ and: [{ not: { field: "source_url", op: "is_set" } }] })
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS, `/documents?q=${q}`)

    expect(await screen.findByRole("button", { name: /z-notes\.md/ })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /screenshot\.png/ })).not.toBeInTheDocument()
  })

  it("filters documents by source URL and created date fields", async () => {
    const q = encodeFilterTree({
      and: [
        { field: "source_url", op: "contains", value: "example.test" },
        { field: "created_at", op: "before", value: "2026-01-03" }
      ]
    })
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS, `/documents?q=${q}`)

    expect(await screen.findByRole("button", { name: /screenshot\.png/ })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /z-notes\.md/ })).not.toBeInTheDocument()
  })

  it("sorts documents by an eligible column", async () => {
    renderRouteWithDocumentsAt(TABLE_DOCUMENTS)

    expect((await screen.findByRole("button", { name: /screenshot\.png/ })).closest("tr")).toBe(documentRowsElements()[0])

    fireEvent.click(screen.getByRole("button", { name: /Document/ }))
    fireEvent.click(await screen.findByRole("button", { name: /Document/ }))

    await waitFor(() => {
      expect(documentRows()[0]).toContain("z-notes.md")
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
    expect(headers).toEqual(["Document", "Size", "Origin", "Kind", "Created", "Actions"])
  })

  it("renders chat provenance as a human-readable link without exposing the source scheme", async () => {
    renderRouteWithDocumentsAt([
      {
        ...TABLE_DOCUMENTS[1],
        source_url: "chat-message-image://77/123/0",
        origin: { kind: "chat_upload", chat: { id: 77, label: "CHAT-77", path: "/chats/77" } }
      }
    ])

    const chatLink = await screen.findByRole("link", { name: "CHAT-77" })
    expect(chatLink).toHaveAttribute("href", "/chats/77")
    expect(chatLink.closest("span")).toHaveTextContent("Uploaded in a chat")
    expect(screen.queryByText(/chat-message-image:/)).not.toBeInTheDocument()
  })

  it("shows an accurate range and preserves filters and sort in pagination links", async () => {
    const q = encodeFilterTree({ and: [{ field: "kind", op: "is", value: "file" }] })
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        documentsPayload({
          documents: [TABLE_DOCUMENTS[0]],
          pagination: { page: 2, per_page: 25, total: 51, total_pages: 3, first_item: 26, last_item: 50 }
        })
      )
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[`/documents?q=${q}&sort=title&direction=ascending&page=2`]}>
          <PersonalDocumentsRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("26–50 of 51")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous" }).getAttribute("href")).toContain(`q=${q}`)
    expect(screen.getByRole("link", { name: "Next" }).getAttribute("href")).toContain("sort=title")
    expect(screen.getByRole("link", { name: "Next" }).getAttribute("href")).toContain("page=3")
  })
})

function documentRowsElements() {
  return screen.getAllByRole("row").slice(1)
}

describe("PersonalDocumentsRoute preview", () => {
  afterEach(() => vi.restoreAllMocks())

  it("opens a preview modal with rendered markdown for a markdown document", async () => {
    renderRouteWithDocuments(
      [
        {
          id: 31,
          kind: "file",
          filename: "notes.md",
          content_type: "text/markdown",
          byte_size: 12,
          source_url: null,
          created_at: "2026-01-01T00:00:00Z",
          updated_at: "2026-01-01T00:00:00Z",
          file_path: "/api/v1/app/credentials/documents/31/file"
        }
      ],
      { "31": "# Hello there" }
    )

    fireEvent.click(await screen.findByRole("button", { name: /notes\.md/ }))

    expect(await screen.findByRole("heading", { name: "Hello there", level: 1 })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/credentials/documents/31/file")
  })

  it("renders an image document inline without fetching its content as text", async () => {
    const fetchSpy = renderRouteWithDocuments([
      {
        id: 32,
        kind: "file",
        filename: "screenshot.png",
        content_type: "image/png",
        byte_size: 512,
        source_url: null,
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
        filename: "notes.pdf",
        content_type: "application/pdf",
        byte_size: 2048,
        source_url: null,
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
})
