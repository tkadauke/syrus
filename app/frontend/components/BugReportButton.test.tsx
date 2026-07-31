import { createRef } from "react"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { BugReportButton, type BugReportButtonHandle } from "./BugReportButton"
import * as bugReportsApi from "../api/bugReports"
import type { BugReportPayload } from "../api/bugReports"
import { getRecentErrors } from "../lib/errorRingBuffer"
import type { ChatMessageItem } from "../api/chats"
import html2canvasModule from "html2canvas-pro"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))

vi.mock("../lib/errorRingBuffer", () => ({
  getRecentErrors: vi.fn().mockReturnValue([])
}))

vi.mock("html2canvas-pro", () => ({
  default: vi.fn().mockResolvedValue({
    toBlob: (cb: (blob: Blob | null) => void) => cb(new Blob(["screenshot"], { type: "image/png" }))
  })
}))

// jsdom does not implement URL.createObjectURL
URL.createObjectURL = vi.fn().mockReturnValue("blob:mock-url")
URL.revokeObjectURL = vi.fn()

const mockCreateBugReport = vi.mocked(bugReportsApi.createBugReport)
const mockGetRecentErrors = vi.mocked(getRecentErrors)
const mockHtml2canvas = vi.mocked(html2canvasModule)

const sampleMessages: ChatMessageItem[] = [
  { type: "message", id: 1, role: "user", text: "Hello, I found a bug.", bookmarkable: false },
  { type: "message", id: 2, role: "assistant", text: "Thanks for reporting!", bookmarkable: false },
  { type: "message", id: 3, role: "tool_use", text: "", bookmarkable: false },
]

function renderButton(props: {
  position?: "bottom-left" | "bottom-right"
  context?: string
  chatId?: number | null
  bugReportMode?: "direct_job" | "github_issue" | null
} = {}) {
  const ref = createRef<BugReportButtonHandle>()
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <BugReportButton context="Dashboard" ref={ref} {...props} />
    </QueryClientProvider>
  )
  return ref
}

function getBugButton() {
  return screen.getByRole("button", { name: "Report a bug" })
}

async function openDialog() {
  fireEvent.click(screen.getByRole("button", { name: "Report a bug" }))
  await screen.findByRole("dialog")
}

describe("BugReportButton", () => {
  beforeEach(() => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } as BugReportPayload)
    mockGetRecentErrors.mockReturnValue([])
    localStorage.clear()
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 })
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 })
    // jsdom does not implement pointer capture APIs; define no-ops so drag handlers work.
    Object.defineProperty(HTMLElement.prototype, "setPointerCapture", { configurable: true, writable: true, value: vi.fn() })
    Object.defineProperty(HTMLElement.prototype, "releasePointerCapture", { configurable: true, writable: true, value: vi.fn() })
  })

  afterEach(() => {
    vi.clearAllMocks()
    // Clean up prototype stubs defined above.
    delete (HTMLElement.prototype as unknown as Record<string, unknown>).setPointerCapture
    delete (HTMLElement.prototype as unknown as Record<string, unknown>).releasePointerCapture
  })

  it("is always visible — no hidden class", () => {
    renderButton()
    expect(getBugButton()).toBeInTheDocument()
    expect(getBugButton().className).not.toContain("hidden")
  })

  it("defaults to the bottom-right when no saved position exists", () => {
    renderButton()
    const button = getBugButton()
    const left = parseFloat(button.style.left)
    const top = parseFloat(button.style.top)
    // bottom-right: left near right edge, top near bottom
    expect(left).toBeGreaterThan(window.innerWidth / 2)
    expect(top).toBeGreaterThan(window.innerHeight / 2)
  })

  it("defaults to the bottom-left when position='bottom-left' and no saved position", () => {
    renderButton({ position: "bottom-left" })
    const button = getBugButton()
    const left = parseFloat(button.style.left)
    expect(left).toBeLessThan(window.innerWidth / 2)
  })

  it("loads a saved position from localStorage", () => {
    localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 123, top: 456 }))
    renderButton()
    const button = getBugButton()
    expect(button.style.left).toBe("123px")
    expect(button.style.top).toBe("456px")
  })

  it("ignores malformed localStorage data and falls back to default", () => {
    localStorage.setItem("bug-report-button-position", "not-json{{{")
    renderButton()
    const button = getBugButton()
    // Should fall back to default (right side, bottom)
    expect(parseFloat(button.style.left)).toBeGreaterThan(0)
    expect(parseFloat(button.style.top)).toBeGreaterThan(0)
  })

  describe("tap vs drag threshold", () => {
    it("treats displacement below 8px as a tap and opens the dialog", async () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      // Move only 5px — below the 8px threshold
      fireEvent.pointerMove(button, { clientX: 204, clientY: 303, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 204, clientY: 303, pointerId: 1 })

      await screen.findByRole("dialog")
    })

    it("treats displacement of exactly 0px as a tap and opens the dialog", async () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 200, clientY: 300, pointerId: 1 })

      await screen.findByRole("dialog")
    })

    it("treats displacement >= 8px as a drag and does not open the dialog", () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 210, clientY: 300, pointerId: 1 }) // 10px
      fireEvent.pointerUp(button, { clientX: 210, clientY: 300, pointerId: 1 })

      expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    })
  })

  describe("drag — position persistence", () => {
    it("saves the new position to localStorage after a drag", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 250, clientY: 320, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 250, clientY: 320, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      expect(saved!.left).toBeCloseTo(250, 0)
      expect(saved!.top).toBeCloseTo(320, 0)
    })

    it("clamps the saved position so the button stays within the viewport", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      // Drag far beyond the right/bottom edge
      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 9999, clientY: 9999, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 9999, clientY: 9999, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      // 1024 - 48 = 976; 768 - 48 = 720
      expect(saved!.left).toBeLessThanOrEqual(window.innerWidth - 48)
      expect(saved!.top).toBeLessThanOrEqual(window.innerHeight - 48)
    })

    it("clamps position to the top-left corner when dragged off-screen to the left/top", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: -9999, clientY: -9999, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: -9999, clientY: -9999, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      expect(saved!.left).toBeGreaterThanOrEqual(0)
      expect(saved!.top).toBeGreaterThanOrEqual(0)
    })
  })

  describe("keyboard access", () => {
    it("opens the dialog when the button receives a keyboard-triggered click", async () => {
      renderButton()
      const button = getBugButton()

      // A keyboard-triggered click is not preceded by pointer events,
      // so pointerHandledRef stays false and the click handler calls openDialog.
      fireEvent.click(button)

      await screen.findByRole("dialog")
    })

    it("does not open the dialog twice when both a pointer tap and the synthetic click fire", async () => {
      renderButton()
      const button = getBugButton()

      // Simulate a tap followed by the synthetic click the browser fires after pointerup.
      fireEvent.pointerDown(button, { clientX: 100, clientY: 100, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 100, clientY: 100, pointerId: 1 })
      // Synthetic click that follows a real pointer tap:
      fireEvent.click(button)

      // Dialog should appear exactly once (not re-opened on the synthetic click).
      const dialogs = await screen.findAllByRole("dialog")
      expect(dialogs).toHaveLength(1)
    })
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

  describe("when opened via the floating button (no messages)", () => {
    it("does not show the transcript section", async () => {
      renderButton()

      fireEvent.click(screen.getByRole("button", { name: /report a bug/i }))

      await screen.findByRole("dialog")
      expect(screen.queryByRole("checkbox", { name: /include chat transcript/i })).not.toBeInTheDocument()
    })
  })

  describe("when opened via handle with messages", () => {
    it("shows the transcript checkbox", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      await screen.findByRole("checkbox", { name: /include chat transcript/i })
    })

    it("does not show transcript preview when checkbox is unchecked (default)", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      await screen.findByRole("checkbox", { name: /include chat transcript/i })
      expect(screen.queryByText("[User]")).not.toBeInTheDocument()
      expect(screen.queryByText("[Assistant]")).not.toBeInTheDocument()
    })

    it("shows transcript preview when checkbox is checked", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      expect(screen.getByText("[User]")).toBeInTheDocument()
      expect(screen.getByText("Hello, I found a bug.")).toBeInTheDocument()
      expect(screen.getByText("[Assistant]")).toBeInTheDocument()
      expect(screen.getByText("Thanks for reporting!")).toBeInTheDocument()
    })

    it("filters tool_use and empty messages from the preview", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      // Only user + assistant messages appear (the tool_use row is skipped)
      const labels = screen.getAllByText(/^\[(User|Assistant)\]$/)
      expect(labels).toHaveLength(2)
    })

    it("submits without transcript file when checkbox is unchecked", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      await screen.findByRole("dialog")
      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(() => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const hasTranscript = (input.attachments ?? []).some((f: File) => f.name === "chat-transcript.txt")
        expect(hasTranscript).toBe(false)
      })
    })

    it("submits with a transcript file when checkbox is checked", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(() => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const transcriptFile = (input.attachments ?? []).find((f: File) => f.name === "chat-transcript.txt")
        expect(transcriptFile).toBeDefined()
        expect(transcriptFile?.type).toBe("text/plain")
      })
    })

    it("includes user and assistant messages in the transcript file content", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(async () => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const transcriptFile = (input.attachments ?? []).find((f: File) => f.name === "chat-transcript.txt")
        expect(transcriptFile).toBeDefined()
        const text = await transcriptFile!.text()
        expect(text).toContain("[User]\nHello, I found a bug.")
        expect(text).toContain("[Assistant]\nThanks for reporting!")
      })
    })

    it("does not include tool_use messages in the transcript file", async () => {
      const ref = renderButton()

      ref.current?.open(sampleMessages)

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(async () => {
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const transcriptFile = (input.attachments ?? []).find((f: File) => f.name === "chat-transcript.txt")
        const text = await transcriptFile!.text()
        expect(text).not.toContain("[Tool")
      })
    })
  })

  describe("when opened via handle without messages", () => {
    it("does not show the transcript section", async () => {
      const ref = renderButton()

      ref.current?.open([])

      await screen.findByRole("dialog")
      expect(screen.queryByRole("checkbox", { name: /include chat transcript/i })).not.toBeInTheDocument()
    })
  })

  describe("resize clamping", () => {
    it("clamps the nub position when the window is resized to a smaller viewport", () => {
      // Start with a position valid for 1024×768 but outside a 400×300 viewport
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 800, top: 400 }))
      renderButton()
      const button = getBugButton()

      expect(parseFloat(button.style.left)).toBe(800)
      expect(parseFloat(button.style.top)).toBe(400)

      // Shrink the window and fire resize
      Object.defineProperty(window, "innerWidth", { configurable: true, value: 400 })
      Object.defineProperty(window, "innerHeight", { configurable: true, value: 300 })
      act(() => {
        fireEvent(window, new Event("resize"))
      })

      // Button should be clamped: max left = 400 - 48 = 352, max top = 300 - 48 = 252
      expect(parseFloat(button.style.left)).toBeLessThanOrEqual(400 - 48)
      expect(parseFloat(button.style.top)).toBeLessThanOrEqual(300 - 48)

      // Clamped position should also be persisted to localStorage
      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as { left: number; top: number } | null
      expect(saved).not.toBeNull()
      expect(saved!.left).toBeLessThanOrEqual(400 - 48)
      expect(saved!.top).toBeLessThanOrEqual(300 - 48)
    })

    it("does not update state or localStorage when the position is already within the resized viewport", () => {
      // Position well within any reasonable viewport
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 50, top: 50 }))
      renderButton()
      const button = getBugButton()

      Object.defineProperty(window, "innerWidth", { configurable: true, value: 400 })
      Object.defineProperty(window, "innerHeight", { configurable: true, value: 300 })
      act(() => {
        fireEvent(window, new Event("resize"))
      })

      // Position unchanged — still within viewport
      expect(parseFloat(button.style.left)).toBe(50)
      expect(parseFloat(button.style.top)).toBe(50)

      // localStorage should remain at the original saved value (savePos not called again)
      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as { left: number; top: number } | null
      expect(saved!.left).toBe(50)
      expect(saved!.top).toBe(50)
    })
  })

  describe("screenshot capture", () => {
    it("excludes the floating trigger button from html2canvas screenshots", () => {
      renderButton()
      expect(screen.getByRole("button", { name: "Report a bug" })).toHaveAttribute("data-html2canvas-ignore")
    })

    it("passes an onclone callback to the viewport capture", async () => {
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      expect(options).toMatchObject({ onclone: expect.any(Function) })
    })

    it("onclone callback converts sticky-positioned elements to relative", async () => {
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      const onclone = options!.onclone as (document: Document, element: HTMLElement) => void

      const stickyEl = document.createElement("div")
      stickyEl.style.position = "sticky"
      document.body.appendChild(stickyEl)

      // Simulate the html2canvas-pro onclone call: second arg is the cloned element;
      // normalizeCloneForCapture reaches the document via element.ownerDocument.
      onclone(document, document.body)

      expect(stickyEl.style.position).toBe("relative")
      document.body.removeChild(stickyEl)
    })

    it("onclone callback hides closed details contents", async () => {
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      const onclone = options!.onclone as (document: Document, element: HTMLElement) => void

      const details = document.createElement("details")
      const summary = document.createElement("summary")
      summary.textContent = "Folders and filters"
      const closedContent = document.createElement("div")
      closedContent.textContent = "Hidden filters"
      details.append(summary, closedContent)
      document.body.appendChild(details)

      onclone(document, document.body)

      expect(summary.style.display).toBe("")
      expect(closedContent.style.getPropertyValue("display")).toBe("none")
      expect(closedContent.style.getPropertyPriority("display")).toBe("important")

      document.body.removeChild(details)
    })

    it("uses viewport windowWidth/windowHeight for full-page capture even when the document overflows the viewport", async () => {
      Object.defineProperty(window, "innerWidth", { configurable: true, value: 402 })
      Object.defineProperty(window, "innerHeight", { configurable: true, value: 714 })
      // Simulate a document wider and taller than the viewport.
      Object.defineProperty(document.body, "scrollWidth", { configurable: true, get: () => 1200 })
      Object.defineProperty(document.body, "scrollHeight", { configurable: true, get: () => 2000 })
      Object.defineProperty(document.documentElement, "scrollWidth", { configurable: true, get: () => 1200 })
      Object.defineProperty(document.documentElement, "scrollHeight", { configurable: true, get: () => 2000 })

      renderButton()
      await openDialog()

      // Reset call count so we can isolate the full-page capture call.
      mockHtml2canvas.mockClear()

      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalledOnce())

      const [, options] = mockHtml2canvas.mock.calls[0]
      // windowWidth/windowHeight must match the viewport, not the document scroll dimensions.
      // onclone must be wired for both capture modes.
      expect(options).toMatchObject({ windowWidth: 402, windowHeight: 714, onclone: expect.any(Function) })
    })

    it("onclone callback syncs scrollTop from inner scroll containers to their clones", async () => {
      // Regression: html2canvas resets scrollTop to 0 in the cloned document.
      // The chat message stream uses overflow-y-auto (not window scroll), so without
      // this sync the screenshot shows the top of the container, not the current view.
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      const onclone = options!.onclone as (document: Document, element: HTMLElement) => void

      const scrolledEl = document.createElement("div")
      document.body.appendChild(scrolledEl)
      const setScrollTop = vi.fn()
      Object.defineProperty(scrolledEl, "scrollTop", { configurable: true, get: () => 500, set: setScrollTop })

      onclone(document, document.body)

      expect(setScrollTop).toHaveBeenCalledWith(500)

      document.body.removeChild(scrolledEl)
    })

    it("onclone callback syncs scrollLeft from horizontally scrolled containers to their clones", async () => {
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      const onclone = options!.onclone as (document: Document, element: HTMLElement) => void

      const scrolledEl = document.createElement("div")
      document.body.appendChild(scrolledEl)
      const setScrollLeft = vi.fn()
      Object.defineProperty(scrolledEl, "scrollLeft", { configurable: true, get: () => 200, set: setScrollLeft })

      onclone(document, document.body)

      expect(setScrollLeft).toHaveBeenCalledWith(200)

      document.body.removeChild(scrolledEl)
    })

    it("onclone callback does not set scrollTop when it is 0", async () => {
      renderButton()
      await openDialog()

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      const onclone = options!.onclone as (document: Document, element: HTMLElement) => void

      const normalEl = document.createElement("div")
      document.body.appendChild(normalEl)
      const setScrollTop = vi.fn()
      Object.defineProperty(normalEl, "scrollTop", { configurable: true, get: () => 0, set: setScrollTop })

      onclone(document, document.body)

      expect(setScrollTop).not.toHaveBeenCalled()

      document.body.removeChild(normalEl)
    })

  })
})
