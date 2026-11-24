import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jobSourcePayload } from "../../test/app/jobPayloads"
import { jsonResponse } from "../../testSupport"
import { SourceTab } from "./SourceBrowser"

vi.mock("@rails/actioncable", async () => (await import("../../test/app/appMocks")).actionCableModule())

afterEach(() => vi.restoreAllMocks())

describe("SourceTab query transitions", () => {
  it("never shows the previous Job's source tree while another Job's source loads", async () => {
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { release = resolve })
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/jobs/43/source")) {
        await gate
        return jsonResponse(jobSourcePayload({ treeItems: [{ path: "job43.txt", name: "job43.txt", size: 1, language: "plaintext", type: "file" }] }))
      }
      return jsonResponse(jobSourcePayload({ treeItems: [{ path: "job42.txt", name: "job42.txt", size: 1, language: "plaintext", type: "file" }] }))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const tree = (jobId: string) => (
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <SourceTab jobId={jobId} coverageInfo={null} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    const { rerender } = render(tree("42"))
    expect(await screen.findByText("job42.txt")).toBeInTheDocument()

    rerender(tree("43"))

    expect(screen.queryByText("job42.txt")).not.toBeInTheDocument()
    await act(async () => { release?.() })
    expect(await screen.findByText("job43.txt")).toBeInTheDocument()
  })
})
