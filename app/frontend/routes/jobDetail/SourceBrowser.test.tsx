import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../../testSupport"
import { DEFAULT_REVIEW_DIFF_SETTINGS } from "../../api/reviewDiffSettings"
import { ReviewDiffSettingsModal } from "./SourceBrowser"

function renderModal() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <ReviewDiffSettingsModal initialSettings={DEFAULT_REVIEW_DIFF_SETTINGS} onClose={() => {}} />
    </QueryClientProvider>
  )
  return client
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("ReviewDiffSettingsModal", () => {
  it("persists each changed setting immediately and updates the shared query cache", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      review_diff_settings: {
        ...DEFAULT_REVIEW_DIFF_SETTINGS,
        line_wrapping: "scroll"
      },
      message: "Review settings updated."
    }))
    const client = renderModal()

    fireEvent.change(screen.getByLabelText("Line wrapping"), { target: { value: "scroll" } })

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/review_diff_settings", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ review_diff_settings: { line_wrapping: "scroll" } })
    })))
    expect(client.getQueryData(["review_diff_settings"])).toMatchObject({
      review_diff_settings: expect.objectContaining({ line_wrapping: "scroll" })
    })
  })

  it("persists boolean settings without a save button", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      review_diff_settings: {
        ...DEFAULT_REVIEW_DIFF_SETTINGS,
        syntax_highlighting: false
      }
    }))
    renderModal()

    fireEvent.click(screen.getByLabelText("Syntax highlighting"))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/review_diff_settings", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ review_diff_settings: { syntax_highlighting: false } })
    })))
    expect(screen.queryByRole("button", { name: "Save" })).not.toBeInTheDocument()
  })
})
