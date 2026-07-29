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
        created_at: "2026-01-01T00:00:00Z"
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
