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
        created_at: "2026-01-01T00:00:00Z",
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
        created_at: "2026-01-01T00:00:00Z",
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
        created_at: "2026-01-01T00:00:00Z",
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
        created_at: "2026-01-01T00:00:00Z",
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
        created_at: "2026-01-01T00:00:00Z",
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
