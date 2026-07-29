import { act, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { useJobCommand } from "./command"
import { jsonResponse } from "../../testSupport"

function Probe({ onNotice = () => {} }: { onNotice?: (message: string | null) => void }) {
  const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, onNotice)
  return (
    <div>
      <button
        onClick={() => command.mutate({ method: "post", path: "/api/v1/app/jobs/1/retry", confirm: "Retry this job?" })}
        type="button"
      >
        retry
      </button>
      {command.dialog}
    </div>
  )
}

function renderProbe(onNotice?: (message: string | null) => void) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <Probe onNotice={onNotice} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("useJobCommand confirm flow", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows the ConfirmDialog before firing the request", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Retried." }))
    renderProbe()

    act(() => screen.getByRole("button", { name: "retry" }).click())

    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument())
    expect(screen.getByText("Retry this job?")).toBeInTheDocument()
    expect(vi.mocked(window.fetch)).not.toHaveBeenCalled()
  })

  it("fires the request when the operator confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Retried." }))
    renderProbe()

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/1/retry",
      expect.objectContaining({ method: "POST" })
    ))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("does not fire the request when the operator cancels", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Retried." }))
    renderProbe()

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Cancel" }))
    await act(async () => screen.getByRole("button", { name: "Cancel" }).click())

    expect(fetchSpy).not.toHaveBeenCalled()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("fires immediately without a dialog when confirm is absent", async () => {
    function NoConfirmProbe() {
      const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, () => {})
      return (
        <div>
          <button onClick={() => command.mutate({ method: "post", path: "/api/v1/app/jobs/1/close" })} type="button">
            close
          </button>
          {command.dialog}
        </div>
      )
    }

    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Closed." }))
    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <NoConfirmProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await act(async () => screen.getByRole("button", { name: "close" }).click())

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})
