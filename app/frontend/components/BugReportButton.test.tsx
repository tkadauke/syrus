import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { BugReportButton } from "./BugReportButton"
import type { BugReportPayload } from "../api/bugReports"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))

vi.mock("../lib/errorRingBuffer", () => ({
  getRecentErrors: vi.fn().mockReturnValue([])
}))

// html2canvas-pro is dynamically imported; rejecting it exercises the
// capture-failure path which still opens the dialog.
vi.mock("html2canvas-pro", () => ({
  default: vi.fn().mockRejectedValue(new Error("not supported in test env"))
}))

import { createBugReport } from "../api/bugReports"
import { getRecentErrors } from "../lib/errorRingBuffer"

const mockCreateBugReport = createBugReport as ReturnType<typeof vi.fn> & typeof createBugReport
const mockGetRecentErrors = getRecentErrors as ReturnType<typeof vi.fn>

function renderButton(props: {
  context?: string
  chatId?: number | null
  bugReportMode?: "direct_job" | "github_issue" | null
} = {}) {
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <BugReportButton context="Dashboard" {...props} />
    </QueryClientProvider>
  )
}

async function openDialog() {
  fireEvent.click(screen.getByRole("button", { name: "Report a bug" }))
  await screen.findByRole("dialog")
}

describe("BugReportButton", () => {
  beforeEach(() => {
    mockGetRecentErrors.mockReturnValue([])
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it("renders the trigger button", () => {
    renderButton()
    expect(screen.getByRole("button", { name: "Report a bug" })).toBeInTheDocument()
  })

  it("opens the dialog when button is clicked", async () => {
    renderButton()
    await openDialog()

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByLabelText("Title")).toBeInTheDocument()
  })

  it("pre-fills the title with context + ' bug'", async () => {
    renderButton({ context: "Jobs" })
    await openDialog()

    expect(screen.getByLabelText("Title")).toHaveValue("Jobs bug")
  })

  it("renders the 'What's included' <details> element closed by default", async () => {
    renderButton()
    await openDialog()

    const summary = screen.getByText("What's included")
    const details = summary.closest("details")
    expect(details).toBeInTheDocument()
    expect(details).not.toHaveAttribute("open")
  })

  it("opens the 'What's included' section when the summary is clicked", async () => {
    renderButton()
    await openDialog()

    fireEvent.click(screen.getByText("What's included"))

    const details = screen.getByText("What's included").closest("details")
    expect(details).toHaveAttribute("open")
  })

  it("contains context fields (URL, Browser, Viewport, Recent JS errors)", async () => {
    renderButton()
    await openDialog()

    // Content is present in the DOM regardless of details open state
    expect(screen.getByText("URL:")).toBeInTheDocument()
    expect(screen.getByText("Browser:")).toBeInTheDocument()
    expect(screen.getByText("Viewport:")).toBeInTheDocument()
    expect(screen.getByText("Recent JS errors")).toBeInTheDocument()
    // no errors recorded; "None" also appears in the screenshot option, so use getAllByText
    expect(screen.getAllByText("None").length).toBeGreaterThanOrEqual(1)
  })

  it("shows recent errors in the preview when present", async () => {
    mockGetRecentErrors.mockReturnValue([
      { message: "TypeError: cannot read x", source: "app.js", at: "2025-01-01T00:00:00.000Z" }
    ])

    renderButton()
    await openDialog()

    expect(screen.getByText("TypeError: cannot read x")).toBeInTheDocument()
    expect(screen.getByText("(app.js)")).toBeInTheDocument()
  })

  it("shows the chat session row when chatId is provided", async () => {
    renderButton({ context: "Chat", chatId: 42 })
    await openDialog()

    expect(screen.getByText("Chat session:")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
  })

  it("omits the chat session row when chatId is not provided", async () => {
    renderButton()
    await openDialog()

    expect(screen.queryByText("Chat session:")).not.toBeInTheDocument()
  })

  it("sends context JSON with the bug report submission", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)
    mockGetRecentErrors.mockReturnValue([
      { message: "ReferenceError: x is not defined", source: "chunk.js", at: "2025-06-01T12:00:00.000Z" }
    ])

    renderButton({ context: "Admin" })
    await openDialog()

    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Test bug" } })
    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(mockCreateBugReport).toHaveBeenCalledOnce())

    const call = mockCreateBugReport.mock.calls[0][0]
    expect(call.context).toBeDefined()

    const ctx = JSON.parse(call.context as string)
    expect(ctx.url).toBeDefined()
    expect(ctx.user_agent).toBeDefined()
    expect(ctx.viewport).toMatchObject({ width: expect.any(Number), height: expect.any(Number) })
    expect(ctx.device_pixel_ratio).toBeDefined()
    expect(ctx.recent_errors).toHaveLength(1)
    expect(ctx.recent_errors[0].message).toBe("ReferenceError: x is not defined")
  })

  it("includes chat_session_id in the submitted context JSON when chatId is provided", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)

    renderButton({ context: "Chat", chatId: 99 })
    await openDialog()

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(mockCreateBugReport).toHaveBeenCalledOnce())

    const ctx = JSON.parse(mockCreateBugReport.mock.calls[0][0].context as string)
    expect(ctx.chat_session_id).toBe(99)
  })

  it("closes the dialog on cancel", async () => {
    renderButton()
    await openDialog()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("shows a queued notice on successful direct-job submission", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)

    renderButton({ bugReportMode: "direct_job" })
    await openDialog()

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(screen.getByRole("status")).toHaveTextContent("Bug report queued.")
  })
})
