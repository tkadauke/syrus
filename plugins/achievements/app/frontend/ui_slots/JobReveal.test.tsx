import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import JobReveal from "./JobReveal"

const pendingUnlock = {
  id: 7,
  key: "example.first_job_landed",
  version: 1,
  scope: "user",
  category: "landing",
  rarity: "common",
  visibility: "visible",
  presentation: { title_key: "achievements:example.first_job_landed.title" },
  unlocked_at: "2026-11-24T10:00:00Z",
  acknowledged: false,
  acknowledged_at: null
}

function renderReveal() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <JobReveal job_id={42} />
    </QueryClientProvider>
  )
}

afterEach(() => vi.restoreAllMocks())

describe("JobReveal", () => {
  it("reveals a pending unlock for the Job and acknowledges it through the shared API", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes("/pending")) return jsonResponse({ achievements: [pendingUnlock] })
      return jsonResponse({ achievement: { ...pendingUnlock, acknowledged: true } })
    })
    renderReveal()

    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => String(url).endsWith("/api/v1/app/achievements/7/acknowledge"))).toBe(true))
    expect(fetchMock.mock.calls.some(([url]) => String(url).includes("/pending?subject_type=job&subject_id=42"))).toBe(true)

    fireEvent.click(screen.getByRole("button", { name: "Continue" }))
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull())
  })

  it("renders nothing when nothing is pending or loading fails", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ achievements: [] }))
    const { container } = renderReveal()
    await waitFor(() => expect(window.fetch).toHaveBeenCalled())
    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByRole("dialog")).toBeNull()
  })
})
