import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AppErrorBoundary } from "./AppErrorBoundary"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))
vi.mock("../api/eventActions", () => ({
  fileEventJob: vi.fn()
}))
vi.mock("../api/browserErrors", () => ({
  buildBrowserErrorPayload: vi.fn((error: Error, options: Record<string, unknown>) => ({
    message: error.message,
    fingerprint: options.fingerprint,
    metadata: { boundary: options.boundary }
  })),
  recordBrowserError: vi.fn()
}))

import { createBugReport } from "../api/bugReports"
import { recordBrowserError } from "../api/browserErrors"
import { fileEventJob } from "../api/eventActions"

const mockCreateBugReport = createBugReport as ReturnType<typeof vi.fn> & typeof createBugReport
const mockRecordBrowserError = recordBrowserError as ReturnType<typeof vi.fn> & typeof recordBrowserError
const mockFileEventJob = fileEventJob as ReturnType<typeof vi.fn> & typeof fileEventJob

function Bomb({ shouldThrow }: { shouldThrow: boolean }) {
  if (shouldThrow) throw new Error("App tree explosion")
  return <div>Safe content</div>
}

describe("AppErrorBoundary", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(console, "error").mockImplementation(() => {})
    sessionStorage.clear()
    mockRecordBrowserError.mockResolvedValue({ id: 456, fingerprint: "fp" })
    mockFileEventJob.mockResolvedValue({ message: "Job filed.", job_id: 42 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders children normally when no error", () => {
    render(
      <AppErrorBoundary>
        <div>Hello world</div>
      </AppErrorBoundary>
    )
    expect(screen.getByText("Hello world")).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("shows full-page fallback with app name, crash heading, error message, and buttons when child throws", () => {
    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    expect(screen.getByRole("alert")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Syrus" })).toBeInTheDocument()
    expect(screen.getByText("An unexpected error has occurred.")).toBeInTheDocument()
    expect(screen.getByText("App tree explosion")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Send error report" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reload page" })).toBeInTheDocument()
  })

  it("records a browser error event automatically", async () => {
    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    await waitFor(() => expect(mockRecordBrowserError).toHaveBeenCalledWith(expect.objectContaining({
      message: "App tree explosion",
      metadata: { boundary: "app" }
    })))
    expect(await screen.findByRole("link", { name: "Browser error #456 captured" })).toHaveAttribute("href", "/admin/browser_errors?id=456&revision_scope=all")
  })

  it("files a job from the captured browser error event when report button is clicked", async () => {
    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    await screen.findByRole("link", { name: "Browser error #456 captured" })
    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() =>
      expect(mockFileEventJob).toHaveBeenCalledWith({ event_type: "browser_error", event_id: 456 })
    )
    expect(mockCreateBugReport).not.toHaveBeenCalled()
  })

  it("shows 'Reported as JOB-42' and stores fingerprint in sessionStorage on success", async () => {
    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    await screen.findByRole("link", { name: "Browser error #456 captured" })
    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() => expect(screen.getByText("Reported as JOB-42")).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()

    const stored = JSON.parse(sessionStorage.getItem("syrus_reported_errors") ?? "[]") as string[]
    expect(stored).toHaveLength(1)
    expect(stored[0]).toBeTypeOf("string")
  })

  it("shows error message and hides report button when fingerprint is already in sessionStorage", async () => {
    mockFileEventJob.mockResolvedValue({ message: "Job filed.", job_id: 99 })

    // First render: report successfully so fingerprint is stored
    const { unmount } = render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )
    await screen.findByRole("link", { name: "Browser error #456 captured" })
    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))
    await waitFor(() => expect(screen.getByText("Reported as JOB-99")).toBeInTheDocument())
    unmount()

    // Second render: same error — fingerprint already stored, button should be gone
    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()
    expect(screen.getByText("Error already reported")).toBeInTheDocument()
  })
})
