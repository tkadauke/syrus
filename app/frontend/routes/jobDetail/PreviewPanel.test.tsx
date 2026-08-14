import { jsonResponse } from "../../testSupport"
import { render, screen, waitFor, act, fireEvent, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PreviewPanel, PreviewStopModal } from "./PreviewPanel"
import type { PreviewEnvironmentRecord } from "../../api/jobs"

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
    ...overrides
  }
}

function renderPanel(props: Partial<Parameters<typeof PreviewPanel>[0]> = {}) {
  render(
    <QueryClientProvider client={client()}>
      <PreviewPanel
        jobId={42}
        previewPath="/api/v1/app/jobs/42/preview"
        previewLogsPath="/api/v1/app/jobs/42/preview/logs"
        canStart={true}
        initialPreview={null}
        queryKey={["jobs", "42", "detail", ""] as const}
        {...props}
      />
    </QueryClientProvider>
  )
}

describe("PreviewPanel", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders nothing when canStart is false and no preview exists", () => {
    const { container } = render(
      <QueryClientProvider client={client()}>
        <PreviewPanel
          jobId={42}
          previewPath="/api/v1/app/jobs/42/preview"
          previewLogsPath="/api/v1/app/jobs/42/preview/logs"
          canStart={false}
          initialPreview={null}
          queryKey={["jobs", "42", "detail", ""] as const}
        />
      </QueryClientProvider>
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
