import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen } from "@testing-library/react"
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
  it("keeps the current tree visible while a different ref loads within the same Job", async () => {
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { release = resolve })
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.includes("ref=aabbccdd1234567")) {
        await gate
        return jsonResponse({ ...jobSourcePayload({ treeItems: [{ path: "base.txt", name: "base.txt", size: 1, language: "plaintext", type: "file" }] }), selected_ref: "aabbccdd1234567" })
      }
      return jsonResponse(jobSourcePayload({ treeItems: [{ path: "head.txt", name: "head.txt", size: 1, language: "plaintext", type: "file" }] }))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <SourceTab jobId="42" coverageInfo={null} />
        </MemoryRouter>
      </QueryClientProvider>
    )
    expect(await screen.findByText("head.txt")).toBeInTheDocument()

    fireEvent.change(screen.getByDisplayValue(/Repair aqueduct/), { target: { value: "aabbccdd1234567" } })

    expect(screen.getByText("head.txt")).toBeInTheDocument()
    await act(async () => { release?.() })
    expect(await screen.findByText("base.txt")).toBeInTheDocument()
  })
})
