import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { RouteErrorBoundary } from "./RouteErrorBoundary"
import type { BugReportPayload } from "../api/bugReports"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))

import { createBugReport } from "../api/bugReports"

const mockCreateBugReport = createBugReport as ReturnType<typeof vi.fn> & typeof createBugReport

function Bomb({ shouldThrow }: { shouldThrow: boolean }) {
  if (shouldThrow) throw new Error("Test explosion")
  return <div>Safe content</div>
}

describe("RouteErrorBoundary", () => {
  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => {})
    sessionStorage.clear()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders children normally when no error", () => {
    render(
      <RouteErrorBoundary>
        <div>Hello world</div>
      </RouteErrorBoundary>
    )
    expect(screen.getByText("Hello world")).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("shows fallback UI with error message and buttons when child throws", () => {
    render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )

    expect(screen.getByRole("alert")).toBeInTheDocument()
    expect(screen.getByText("Test explosion")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Send error report" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Go back" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reload page" })).toBeInTheDocument()
  })

  it("calls createBugReport with correct title and description when report button is clicked", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 42 })

    render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )

    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() =>
      expect(mockCreateBugReport).toHaveBeenCalledWith(
        expect.objectContaining({
          title: "Frontend error: Test explosion",
          description: expect.stringContaining("Test explosion")
        })
      )
    )
  })

  it("shows 'Reported as JOB-42' and stores fingerprint in sessionStorage on success", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 42 })

    render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )

    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() => expect(screen.getByText("Reported as JOB-42")).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()

    const stored = JSON.parse(sessionStorage.getItem("syrus_reported_errors") ?? "[]") as string[]
    expect(stored).toHaveLength(1)
    expect(stored[0]).toBeTypeOf("string")
  })

  it("shows 'Could not send report' on API error", async () => {
    mockCreateBugReport.mockRejectedValue(new Error("Network error"))

    render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )

    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))

    await waitFor(() =>
      expect(screen.getByText("Could not send report — try refreshing")).toBeInTheDocument()
    )
    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()
  })

  it("does not show the report button when fingerprint is already in sessionStorage", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Report queued", job_id: 99 })

    // First render: report successfully so fingerprint is stored
    const { unmount } = render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )
    fireEvent.click(screen.getByRole("button", { name: "Send error report" }))
    await waitFor(() => expect(screen.getByText("Reported as JOB-99")).toBeInTheDocument())
    unmount()

    // Second render: same error — fingerprint already stored, button should be gone
    render(
      <RouteErrorBoundary>
        <Bomb shouldThrow={true} />
      </RouteErrorBoundary>
    )

    expect(screen.queryByRole("button", { name: "Send error report" })).not.toBeInTheDocument()
    expect(screen.getByText("Error already reported")).toBeInTheDocument()
  })
})
