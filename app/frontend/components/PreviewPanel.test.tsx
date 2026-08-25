import { jsonResponse } from "../testSupport"
import { render, screen, waitFor, act, fireEvent, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PreviewPanel, PreviewStopModal } from "./PreviewPanel"
import type { DeployWorkflowRecord, PreviewEnvironmentRecord } from "../api/jobs"

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function preview(overrides: Partial<PreviewEnvironmentRecord> = {}): PreviewEnvironmentRecord {
  return {
    id: 1,
    state: "running",
    url: "http://preview-42.lvh.me",
    expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    error_message: null,
    error_reason: null,
    ...overrides
  }
}

function deploy(overrides: Partial<DeployWorkflowRecord> = {}): DeployWorkflowRecord {
  return {
    id: 1,
    state: "running",
    failure_reason: null,
    created_at: new Date().toISOString(),
    started_at: new Date().toISOString(),
    finished_at: null,
    path: "/jobs/42?tab=workflows#workflow-1",
    ...overrides
  }
}

function renderPanel(props: Partial<Parameters<typeof PreviewPanel>[0]> = {}) {
  render(
    <MemoryRouter>
      <QueryClientProvider client={client()}>
        <PreviewPanel
          queryKeyPrefix="job"
          entityId={42}
          repositoryId={7}
          previewPath="/api/v1/app/jobs/42/preview"
          previewLogsPath="/api/v1/app/jobs/42/preview/logs"
          canStart={true}
          initialPreview={null}
          deployPath="/api/v1/app/jobs/42/deploy"
          canDeploy={false}
          initialDeploy={null}
          queryKey={["jobs", "42", "detail", ""] as const}
          {...props}
        />
      </QueryClientProvider>
    </MemoryRouter>
  )
}

describe("PreviewPanel", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing when canStart is false and no preview exists", () => {
    const { container } = render(
      <MemoryRouter>
        <QueryClientProvider client={client()}>
          <PreviewPanel
            queryKeyPrefix="job"
            entityId={42}
            repositoryId={7}
            previewPath="/api/v1/app/jobs/42/preview"
            previewLogsPath="/api/v1/app/jobs/42/preview/logs"
            canStart={false}
            initialPreview={null}
            queryKey={["jobs", "42", "detail", ""] as const}
          />
        </QueryClientProvider>
      </MemoryRouter>
    )
    expect(container.firstChild).toBeNull()
  })

  it("shows Start Preview button when canStart is true and no preview exists", () => {
    renderPanel({ canStart: true, initialPreview: null })
    expect(screen.getByRole("button", { name: "Start Preview" })).toBeInTheDocument()
  })

  it("shows spinner and 'Starting preview…' when state is starting", () => {
    renderPanel({ initialPreview: preview({ state: "starting", url: null, expires_at: null }) })
    expect(screen.getByText("Starting preview…")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Start Preview" })).not.toBeInTheDocument()
  })

  it("shows spinner and 'Seeding database…' when state is seeding", () => {
    renderPanel({ initialPreview: preview({ state: "seeding", url: null, expires_at: null }) })
    expect(screen.getByText("Seeding database…")).toBeInTheDocument()
  })

  it("shows Open Preview link and Stop Preview button when running", () => {
    renderPanel({ initialPreview: preview({ state: "running" }) })
    expect(screen.getByRole("link", { name: "Open Preview" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open Preview" })).toHaveAttribute("href", "http://preview-42.lvh.me")
    expect(screen.getByRole("button", { name: "Stop Preview" })).toBeInTheDocument()
  })

  it("shows TTL countdown when running and not expired", () => {
    renderPanel({ initialPreview: preview({ state: "running" }) })
    expect(screen.getByText(/Expires in/)).toBeInTheDocument()
  })

  it("shows Restart Preview button when expired", () => {
    renderPanel({
      initialPreview: preview({ state: "running", expires_at: new Date(Date.now() - 1000).toISOString() })
    })
    expect(screen.getByRole("button", { name: "Restart Preview" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Open Preview" })).not.toBeInTheDocument()
  })

  it("shows 'Preview expired — restart?' message when expired", () => {
    renderPanel({
      initialPreview: preview({ state: "running", expires_at: new Date(Date.now() - 1000).toISOString() })
    })
    expect(screen.getByText("Preview expired — restart?")).toBeInTheDocument()
  })

  it("shows spinner and 'Stopping…' when stopping", () => {
    renderPanel({ initialPreview: preview({ state: "stopping", url: null, expires_at: null }) })
    expect(screen.getByText("Stopping…")).toBeInTheDocument()
  })

  it("shows Start Preview button after stopped state", () => {
    renderPanel({ canStart: true, initialPreview: preview({ state: "stopped", url: null, expires_at: null }) })
    expect(screen.getByRole("button", { name: "Start Preview" })).toBeInTheDocument()
  })

  it("shows error message for failed state", () => {
    renderPanel({
      initialPreview: preview({ state: "failed", url: null, expires_at: null, error_message: "No preview provider found." })
    })
    expect(screen.getByText("No preview provider found.")).toBeInTheDocument()
  })

  it("does not show a Fix preview button for failures without a not_reachable reason", () => {
    renderPanel({
      initialPreview: preview({ state: "failed", url: null, expires_at: null, error_message: "No preview provider found." })
    })
    expect(screen.queryByRole("button", { name: "Fix preview" })).not.toBeInTheDocument()
  })

  it("shows a Fix preview button when the failure is diagnosed as not reachable", () => {
    renderPanel({
      initialPreview: preview({
        state: "failed",
        url: null,
        expires_at: null,
        error_message: "preview process is healthy on 127.0.0.1:28009 but is not reachable at syrus-preview:28009; configure the preview start command to bind to 0.0.0.0",
        error_reason: "not_reachable"
      })
    })
    expect(screen.getByRole("button", { name: "Fix preview" })).toBeInTheDocument()
  })

  it("creates a direct job scoped to the repository and navigates there when Fix preview is clicked", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        message: "Direct job created.",
        create_more: false,
        redirect_to: "/jobs/99",
        job: { id: 99, title: "Fix preview", state: "queued", repository: { id: 7 }, job_path: "/jobs/99" }
      }, 201)
    )

    renderPanel({
      repositoryId: 7,
      initialPreview: preview({
        state: "failed",
        url: null,
        expires_at: null,
        error_message: "preview process is healthy on 127.0.0.1:28009 but is not reachable at syrus-preview:28009; configure the preview start command to bind to 0.0.0.0",
        error_reason: "not_reachable"
      })
    })

    fireEvent.click(screen.getByRole("button", { name: "Fix preview" }))

    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith(
        "/api/v1/app/jobs",
        expect.objectContaining({ method: "POST" })
      )
    })

    const call = (window.fetch as ReturnType<typeof vi.fn>).mock.calls.find(([input]) => String(input) === "/api/v1/app/jobs")
    const formData = call?.[1]?.body as FormData
    expect(formData.get("repository_id")).toBe("7")
    expect(String(formData.get("prompt"))).toContain("is not reachable at syrus-preview:28009")
  })

  it("loads preview logs in a modal on demand", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.endsWith("/preview/logs")) {
        return Promise.resolve(jsonResponse({
          preview: preview({ state: "running" }),
          logs: [
            { path: "log/development.log", content: "Started POST /signup\nCompleted 500", missing: false },
            { path: "log/vite.log", content: "", missing: true }
          ]
        }))
      }
      return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }) }))
    })

    renderPanel({ initialPreview: preview({ state: "running" }) })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "View logs" }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/preview/logs",
        expect.objectContaining({ credentials: "same-origin" })
      )
    })
    const dialog = screen.getByRole("dialog")
    expect(await within(dialog).findByText(/Started POST \/signup/)).toBeInTheDocument()
    expect(within(dialog).getByText(/Completed 500/)).toBeInTheDocument()
    expect(within(dialog).getByText("log/vite.log")).toBeInTheDocument()
    expect(within(dialog).getByText("missing")).toBeInTheDocument()
  })

  it("closes the preview logs modal when the close button is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.endsWith("/preview/logs")) {
        return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }), logs: [] }))
      }
      return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }) }))
    })

    renderPanel({ initialPreview: preview({ state: "running" }) })
    fireEvent.click(screen.getByRole("button", { name: "View logs" }))
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Close" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("closes the preview logs modal on Escape", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.endsWith("/preview/logs")) {
        return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }), logs: [] }))
      }
      return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }) }))
    })

    renderPanel({ initialPreview: preview({ state: "running" }) })
    fireEvent.click(screen.getByRole("button", { name: "View logs" }))
    expect(screen.getByRole("dialog")).toBeInTheDocument()

    fireEvent.keyDown(document, { key: "Escape" })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("closes the preview logs modal when the backdrop is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.endsWith("/preview/logs")) {
        return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }), logs: [] }))
      }
      return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }) }))
    })

    renderPanel({ initialPreview: preview({ state: "running" }) })
    fireEvent.click(screen.getByRole("button", { name: "View logs" }))
    const dialog = screen.getByRole("dialog")
    const backdrop = dialog.parentElement as HTMLElement

    fireEvent.click(backdrop)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("shows loading and error states in the preview logs modal", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.endsWith("/preview/logs")) {
        return Promise.reject(new Error("network error"))
      }
      return Promise.resolve(jsonResponse({ preview: preview({ state: "running" }) }))
    })

    renderPanel({ initialPreview: preview({ state: "running" }) })
    fireEvent.click(screen.getByRole("button", { name: "View logs" }))

    expect(screen.getByText("Loading logs...")).toBeInTheDocument()
    expect(await screen.findByText("Preview logs could not be loaded.")).toBeInTheDocument()
  })

  it("starts a preview when Start Preview is clicked", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ preview: preview({ state: "starting", url: null, expires_at: null }), message: "Preview environment starting." })
    )

    renderPanel({ canStart: true, initialPreview: null })
    fireEvent.click(screen.getByRole("button", { name: "Start Preview" }))

    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/preview",
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("stops a preview when Stop Preview is clicked", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ preview: preview({ state: "stopping", url: null, expires_at: null }), message: "Preview environment stopping." })
    )

    renderPanel({ initialPreview: preview({ state: "running" }) })
    fireEvent.click(screen.getByRole("button", { name: "Stop Preview" }))

    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/preview",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("shows fetch error message when start fails", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ error: { code: "validation_failed", message: "Job not implemented." } }, 422)
    )

    renderPanel({ canStart: true, initialPreview: null })
    fireEvent.click(screen.getByRole("button", { name: "Start Preview" }))

    await waitFor(() => {
      expect(screen.getByRole("alert")).toBeInTheDocument()
    })
  })

  it("keeps job and repository preview caches independent via queryKeyPrefix", async () => {
    const queryClient = client()
    const runningPreview = preview({ state: "running" })
    render(
      <MemoryRouter>
        <QueryClientProvider client={queryClient}>
          <PreviewPanel
            queryKeyPrefix="repository"
            entityId={7}
            repositoryId={7}
            previewPath="/api/v1/app/repositories/7/preview"
            previewLogsPath="/api/v1/app/repositories/7/preview/logs"
            canStart={true}
            initialPreview={runningPreview}
            queryKey={["repositories", "7", "detail", ""] as const}
          />
        </QueryClientProvider>
      </MemoryRouter>
    )

    expect(queryClient.getQueryData(["repository-preview", 7])).toEqual({ preview: runningPreview })
    expect(queryClient.getQueryData(["job-preview", 7])).toBeUndefined()
  })
})

describe("PreviewPanel Deploy controls", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing when neither preview nor deploy are available", () => {
    const { container } = render(
      <MemoryRouter>
        <QueryClientProvider client={client()}>
          <PreviewPanel
            queryKeyPrefix="job"
            entityId={42}
            repositoryId={7}
            previewPath="/api/v1/app/jobs/42/preview"
            previewLogsPath="/api/v1/app/jobs/42/preview/logs"
            canStart={false}
            initialPreview={null}
            deployPath="/api/v1/app/jobs/42/deploy"
            canDeploy={false}
            initialDeploy={null}
            queryKey={["jobs", "42", "detail", ""] as const}
          />
        </QueryClientProvider>
      </MemoryRouter>
    )
    expect(container.firstChild).toBeNull()
  })

  it("does not show a Deploy button when canDeploy is false and no deploy exists", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: false, initialDeploy: null })
    expect(screen.queryByRole("button", { name: "Deploy" })).not.toBeInTheDocument()
  })

  it("shows a Deploy button in the same section as Preview when canDeploy is true", () => {
    renderPanel({ canStart: true, initialPreview: null, canDeploy: true, initialDeploy: null })

    const section = screen.getByRole("region", { name: "Preview" })
    expect(within(section).getByRole("button", { name: "Start Preview" })).toBeInTheDocument()
    expect(within(section).getByRole("button", { name: "Deploy" })).toBeInTheDocument()
  })

  it("shows deploy button even when Preview is unavailable", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: null })
    expect(screen.getByRole("button", { name: "Deploy" })).toBeInTheDocument()
  })

  it("shows a queued status while the deploy is queued", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: deploy({ state: "queued" }) })
    expect(screen.getByText("Deploy queued…")).toBeInTheDocument()
  })

  it("shows a running status while the deploy is running", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: deploy({ state: "running" }) })
    expect(screen.getByText("Deploying…")).toBeInTheDocument()
  })

  it("shows a succeeded status and a Deploy again button once finished", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: deploy({ state: "succeeded" }) })
    expect(screen.getByText("Deployed")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Deploy again" })).toBeInTheDocument()
  })

  it("shows a failed status and a Deploy again button when the deploy failed" , () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: deploy({ state: "failed", failure_reason: "boom" }) })
    expect(screen.getByText("Deploy failed")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Deploy again" })).toBeInTheDocument()
  })

  it("does not show a Deploy again button once finished when canDeploy is false", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: false, initialDeploy: deploy({ state: "succeeded" }) })
    expect(screen.getByText("Deployed")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Deploy again" })).not.toBeInTheDocument()
  })

  it("links to the deploy workflow", () => {
    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: deploy({ path: "/jobs/42?tab=workflows#workflow-7" }) })
    expect(screen.getByRole("link", { name: "View deploy" })).toHaveAttribute("href", "/jobs/42?tab=workflows#workflow-7")
  })

  it("starts a deploy when the Deploy button is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(jsonResponse({ deploy: deploy({ state: "queued" }), message: "Deploy workflow enqueued." }, 201))
    )

    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: null })
    fireEvent.click(screen.getByRole("button", { name: "Deploy" }))

    await waitFor(() => {
      expect(window.fetch).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/deploy",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Deploy queued…")).toBeInTheDocument()
  })

  it("shows an error message when starting a deploy fails" , async () => {
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(jsonResponse({ error: { code: "forbidden", message: "Approve the Job first." } }, 403))
    )

    renderPanel({ canStart: false, initialPreview: null, canDeploy: true, initialDeploy: null })
    fireEvent.click(screen.getByRole("button", { name: "Deploy" }))

    await waitFor(() => {
      expect(screen.getByRole("alert")).toBeInTheDocument()
    })
  })
})

describe("PreviewStopModal", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the modal with title and action buttons", () => {
    render(
      <PreviewStopModal
        onStop={vi.fn()}
        onKeepRunning={vi.fn()}
      />
    )
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByText("A preview environment is running")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Yes, stop it" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Keep running" })).toBeInTheDocument()
  })

  it("calls onStop when Yes button is clicked", async () => {
    const onStop = vi.fn()
    render(<PreviewStopModal onStop={onStop} onKeepRunning={vi.fn()} />)
    fireEvent.click(screen.getByRole("button", { name: "Yes, stop it" }))
    expect(onStop).toHaveBeenCalledOnce()
  })

  it("calls onKeepRunning when Keep running is clicked", async () => {
    const onKeepRunning = vi.fn()
    render(<PreviewStopModal onStop={vi.fn()} onKeepRunning={onKeepRunning} />)
    fireEvent.click(screen.getByRole("button", { name: "Keep running" }))
    expect(onKeepRunning).toHaveBeenCalledOnce()
  })

  it("calls onKeepRunning when Escape is pressed", async () => {
    const onKeepRunning = vi.fn()
    render(<PreviewStopModal onStop={vi.fn()} onKeepRunning={onKeepRunning} />)
    fireEvent.keyDown(document, { key: "Escape" })
    expect(onKeepRunning).toHaveBeenCalledOnce()
  })

  it("calls onKeepRunning when backdrop is clicked", async () => {
    const onKeepRunning = vi.fn()
    const { container } = render(<PreviewStopModal onStop={vi.fn()} onKeepRunning={onKeepRunning} />)
    // click the backdrop (the fixed overlay, not the dialog itself)
    const backdrop = container.firstChild as HTMLElement
    fireEvent.click(backdrop)
    expect(onKeepRunning).toHaveBeenCalledOnce()
  })
})
