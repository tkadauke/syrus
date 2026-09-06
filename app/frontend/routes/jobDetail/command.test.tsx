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

describe("useJobCommand cache sync", () => {
  afterEach(() => vi.restoreAllMocks())

  it("merges the command response's job/actions into the cache synchronously, before the invalidated refetch resolves", async () => {
    function ApproveProbe() {
      const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, () => {})
      return (
        <button
          onClick={() => command.mutate({ method: "post", path: "/api/v1/app/jobs/1/approve" })}
          type="button"
        >
          approve
        </button>
      )
    }

    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    const queryKey = ["jobs", "1", "detail", ""] as const
    client.setQueryData(queryKey, {
      job: { id: 1, state: "implemented" },
      actions: { can_approve: true, can_unapprove: false }
    })

    // The refetch triggered by invalidateQueries never resolves in this test —
    // it must not be what makes can_approve flip.
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      message: "Job approved.",
      job: { id: 1, state: "approved" },
      actions: { can_approve: false, can_unapprove: true }
    }))

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <ApproveProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await act(async () => screen.getByRole("button", { name: "approve" }).click())

    await waitFor(() => {
      const cached = client.getQueryData<{ job: { state: string }; actions: { can_approve: boolean; can_unapprove: boolean } }>(queryKey)
      expect(cached?.job.state).toBe("approved")
      expect(cached?.actions.can_approve).toBe(false)
      expect(cached?.actions.can_unapprove).toBe(true)
    })
  })

  it("does not merge a response describing a different job (restart's replacement job) into this job's cache entry", async () => {
    function RestartProbe() {
      const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, () => {})
      return (
        <button
          onClick={() => command.mutate({ method: "post", path: "/api/v1/app/jobs/1/restart" })}
          type="button"
        >
          restart
        </button>
      )
    }

    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    const queryKey = ["jobs", "1", "detail", ""] as const
    client.setQueryData(queryKey, {
      job: { id: 1, state: "failed" },
      actions: { can_approve: false, can_unapprove: false }
    })

    // restart responds with the newly created replacement Job (id 2), not
    // job 1 that this hook/queryKey is bound to.
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      message: "Started over - new branch and PR will be created.",
      job: { id: 2, state: "queued" },
      actions: { can_approve: false, can_unapprove: false },
      old_job: { id: 1, state: "closed" },
      redirect_to: "/jobs/2"
    }))

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <RestartProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await act(async () => screen.getByRole("button", { name: "restart" }).click())

    await waitFor(() => {
      const cached = client.getQueryData<{ job: { id: number; state: string } }>(queryKey)
      // Must still describe job 1, untouched by job 2's response fields —
      // not silently overwritten with the replacement job's id/state.
      expect(cached?.job.id).toBe(1)
      expect(cached?.job.state).toBe("failed")
    })
  })
})
