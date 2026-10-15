import { act, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { CommandButton, useJobCommand } from "./command"
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
    const onNotice = vi.fn()
    renderProbe(onNotice)

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Cancel" }))
    await act(async () => screen.getByRole("button", { name: "Cancel" }).click())

    expect(fetchSpy).not.toHaveBeenCalled()
    expect(onNotice).not.toHaveBeenCalled()
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

describe("useJobCommand notices", () => {
  afterEach(() => vi.restoreAllMocks())

  it("surfaces the server error message when a command fails", async () => {
    const onNotice = vi.fn()
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      error: { code: "validation_failed", message: "Unapprove before replacing the PR branch." }
    }, 422))
    renderProbe(onNotice)

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Unapprove before replacing the PR branch.", "error"))
  })

  it("surfaces a fallback message when a command fails without a server response", async () => {
    const onNotice = vi.fn()
    vi.spyOn(window, "fetch").mockRejectedValue(new Error("network down"))
    renderProbe(onNotice)

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Job command failed.", "error"))
  })

  it("still surfaces successful command notices unchanged", async () => {
    const onNotice = vi.fn()
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Retried." }))
    renderProbe(onNotice)

    act(() => screen.getByRole("button", { name: "retry" }).click())
    await waitFor(() => screen.getByRole("button", { name: "Confirm" }))
    await act(async () => screen.getByRole("button", { name: "Confirm" }).click())

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Retried."))
  })
})

describe("useJobCommand cache sync", () => {
  afterEach(() => vi.restoreAllMocks())

  it("invalidates cached dashboard rows and job previews after a command succeeds", async () => {
    function CloseProbe() {
      const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, () => {})
      return (
        <button onClick={() => command.mutate({ method: "post", path: "/api/v1/app/jobs/1/close" })} type="button">
          close
        </button>
      )
    }

    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    const dashboardKey = ["dashboard", "rows", "?state=running"] as const
    const previewKey = ["jobs", "1"] as const
    const sourceDiffKey = ["jobs", "1", "source_diff", ""] as const
    const reviewCommentsKey = ["jobs", "1", "diff_review_comments", "job_source_diff", ""] as const
    client.setQueryData(dashboardKey, { jobs: [] })
    client.setQueryData(previewKey, { job: { id: 1, state: "running" } })
    client.setQueryData(sourceDiffKey, { files: [] })
    client.setQueryData(reviewCommentsKey, { comments: [] })
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "Closed." }))

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <CloseProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await act(async () => screen.getByRole("button", { name: "close" }).click())

    await waitFor(() => {
      expect(client.getQueryState(dashboardKey)?.isInvalidated).toBe(true)
      expect(client.getQueryState(previewKey)?.isInvalidated).toBe(true)
      expect(client.getQueryState(sourceDiffKey)?.isInvalidated).toBe(false)
      expect(client.getQueryState(reviewCommentsKey)?.isInvalidated).toBe(false)
    })
  })

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

// Every CommandButton shares one mutation object, and mutationFn awaits the
// confirm dialog, so `isPending` is true for as long as a dialog is open.
// Disabling on it directly took every other button on the page down with it,
// which an operator experiences as a working button doing nothing.
describe("CommandButton pending scope", () => {
  afterEach(() => vi.restoreAllMocks())

  function Panel() {
    const command = useJobCommand(1, ["jobs", "1", "detail", ""] as const, undefined, () => {})
    return (
      <div>
        <CommandButton command={command} input={{ method: "post", path: "/retry", body: { a: 1 } }}>retry</CommandButton>
        <CommandButton command={command} input={{ method: "post", path: "/force_push", confirm: "Replace?" }}>replace</CommandButton>
        <CommandButton command={command} input={{ method: "post", path: "/discard" }}>discard</CommandButton>
        {command.dialog}
      </div>
    )
  }

  function renderPanel() {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter><Panel /></MemoryRouter>
      </QueryClientProvider>
    )
  }

  it("leaves other buttons usable while one command's confirm dialog is open", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "ok" }))
    renderPanel()

    act(() => screen.getByRole("button", { name: "replace" }).click())
    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument())

    expect(screen.getByRole("button", { name: "retry" })).not.toBeDisabled()
    expect(screen.getByRole("button", { name: "discard" })).not.toBeDisabled()
  })

  it("disables the button whose own command is in flight", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "ok" }))
    renderPanel()

    act(() => screen.getByRole("button", { name: "replace" }).click())
    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument())

    expect(screen.getByRole("button", { name: "replace" })).toBeDisabled()
  })

  // With the scope fixed, a second confirm is reachable. It must settle the
  // first prompt rather than orphan its promise, or the first mutation hangs
  // forever and its button never comes back.
  it("settles a superseded confirm instead of hanging its mutation", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ message: "ok" }))
    renderPanel()

    act(() => screen.getByRole("button", { name: "replace" }).click())
    await waitFor(() => expect(screen.getByRole("dialog")).toBeInTheDocument())
    act(() => screen.getByRole("button", { name: "discard" }).click())

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/discard", expect.objectContaining({ method: "POST" })))
    await waitFor(() => expect(screen.getByRole("button", { name: "replace" })).not.toBeDisabled())
  })
})
