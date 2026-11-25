import { act, fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter, useNavigate } from "react-router-dom"
import { App } from "./App"
import { jobDetailPayload } from "../test/app/jobPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"
import { jsonResponse } from "../testSupport"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

function Navigator({ to, label }: { to: string; label: string }) {
  const navigate = useNavigate()
  return <button onClick={() => navigate(to)}>{label}</button>
}

function jobPayload(id: number, slug: string) {
  const base = jobDetailPayload()
  return {
    ...base,
    job: { ...base.job, id, workflows_count: 1 },
    workflows: base.workflows.map((workflow) => ({ ...workflow, slug }))
  }
}

describe("App Job query transitions", () => {
  installAppTestLifecycle()

  it("never shows the previous Job's workflows while another Job's workflows load", async () => {
    let releaseJob43: (() => void) | undefined
    const job43Gate = new Promise<void>((resolve) => {
      releaseJob43 = resolve
    })
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      const match = path.match(/^\/api\/v1\/app\/jobs\/(\d+)\/workflows(\?.*)?$/)
      if (match) {
        if (match[1] === "43") await job43Gate
        return jsonResponse(jobPayload(Number(match[1]), match[1] === "43" ? "WF-43" : "WF-42"))
      }
      const detailMatch = path.match(/^\/api\/v1\/app\/jobs\/(\d+)/)
      return jsonResponse({ ...jobPayload(Number(detailMatch?.[1] ?? 42), "WF-0"), workflows: [] })
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
          <Navigator to="/app-shell/jobs/43?tab=workflows" label="other job" />
        </MemoryRouter>
      </QueryClientProvider>
    )
    expect(await screen.findByText("WF-42")).toBeInTheDocument()

    fireEvent.click(screen.getByText("other job"))
    expect(screen.queryByText("WF-42")).not.toBeInTheDocument()
    await act(async () => {
      releaseJob43?.()
    })
    expect(await screen.findByText("WF-43")).toBeInTheDocument()
  })
})
