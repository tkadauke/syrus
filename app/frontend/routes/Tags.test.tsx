import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import * as useConfirmModule from "../hooks/useConfirm"
import { Tags } from "./Tags"

function tagsPayload(overrides: Record<string, unknown> = {}) {
  return {
    palette: [
      { key: "gray", label: "Gray", bg: "bg-gray-100", text: "text-gray-800" }
    ],
    tags: [
      { id: 4, name: "urgent", color: "gray", jobs_count: 2 }
    ],
    ...overrides
  }
}

function renderRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/tags"]}>
        <Tags />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("Tags", () => {
  it("opens the shared confirm dialog before deleting a tag", async () => {
    const mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
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
    const mockConfirm = vi.fn().mockResolvedValue(false)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(tagsPayload()))

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalled())
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/tags/4", expect.anything())
  })
})
