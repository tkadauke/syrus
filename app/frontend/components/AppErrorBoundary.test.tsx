import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { AppErrorBoundary } from "./AppErrorBoundary"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))

import { createBugReport } from "../api/bugReports"

const mockCreateBugReport = createBugReport as ReturnType<typeof vi.fn> & typeof createBugReport

function Bomb({ shouldThrow }: { shouldThrow: boolean }) {
  if (shouldThrow) throw new Error("App tree explosion")
  return <div>Safe content</div>
}

describe("AppErrorBoundary", () => {
  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => {})
    sessionStorage.clear()
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

  it("calls createBugReport with correct title and description when report button is clicked", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 42 })

    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() =>
      expect(mockCreateBugReport).toHaveBeenCalledWith(
        expect.objectContaining({
          title: "Frontend error: App tree explosion",
          description: expect.stringContaining("App tree explosion")
        })
      )
    )
  })

  it("shows 'Reported as JOB-42' and stores fingerprint in sessionStorage on success", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 42 })

    render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )

    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() => expect(screen.getByText("Reported as JOB-42")).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()

    const stored = JSON.parse(sessionStorage.getItem("syrus_reported_errors") ?? "[]") as string[]
    expect(stored).toHaveLength(1)
    expect(stored[0]).toBeTypeOf("string")
  })

  it("shows error message and hides report button when fingerprint is already in sessionStorage", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 99 })

    // First render: report successfully so fingerprint is stored
    const { unmount } = render(
      <AppErrorBoundary>
        <Bomb shouldThrow={true} />
      </AppErrorBoundary>
    )
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
