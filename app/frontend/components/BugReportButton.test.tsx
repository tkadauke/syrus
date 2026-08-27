import { createRef } from "react"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { BugReportButton, type BugReportButtonHandle } from "./BugReportButton"
import * as bugReportsApi from "../api/bugReports"
import type { BugReportPayload } from "../api/bugReports"
import { getRecentErrors } from "../lib/errorRingBuffer"
import type { ChatMessageItem } from "../api/chats"
import html2canvasModule from "html2canvas-pro"
import { chatTranscriptBugReportAttachment } from "../lib/chatBugReportAttachments"
import type { BugReportOptionalAttachment } from "../lib/bugReportOptionalAttachments"

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
  context?: string
  chatId?: number | null
  bugReportMode?: "direct_job" | "github_issue" | null
  featureFlags?: Record<string, boolean>
  pageAttachments?: BugReportOptionalAttachment[]
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

function reportOptions(messages: ChatMessageItem[]) {
  const attachment = chatTranscriptBugReportAttachment(messages)
  return { optionalAttachments: attachment ? [attachment] : [] }
}

async function openDialog(ref: ReturnType<typeof renderButton>) {
  ref.current?.open()
  await screen.findByRole("dialog")
}

describe("BugReportButton", () => {
  beforeEach(() => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } as BugReportPayload)
    mockGetRecentErrors.mockReturnValue([])
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it("renders nothing of its own — headless until opened via the imperative handle", () => {
    renderButton()
    expect(screen.queryByRole("button")).not.toBeInTheDocument()
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("opens the dialog when the imperative handle's open() is called", async () => {
    const ref = renderButton()
    await openDialog(ref)

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getByLabelText("Title")).toBeInTheDocument()
  })

  it("pre-fills the title with context + ' bug'", async () => {
    const ref = renderButton({ context: "Jobs" })
    await openDialog(ref)

    expect(screen.getByLabelText("Title")).toHaveValue("Jobs bug")
  })

  it("renders the 'What's included' <details> element closed by default", async () => {
    const ref = renderButton()
    await openDialog(ref)

    const summary = screen.getByText("What's included")
    const details = summary.closest("details")
    expect(details).toBeInTheDocument()
    expect(details).not.toHaveAttribute("open")
  })

  it("opens the 'What's included' section when the summary is clicked", async () => {
    const ref = renderButton()
    await openDialog(ref)

    fireEvent.click(screen.getByText("What's included"))

    const details = screen.getByText("What's included").closest("details")
    expect(details).toHaveAttribute("open")
  })

  it("contains context fields (URL, Browser, Viewport, Recent JS errors)", async () => {
    const ref = renderButton()
    await openDialog(ref)

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

    const ref = renderButton()
    await openDialog(ref)

    expect(screen.getByText("TypeError: cannot read x")).toBeInTheDocument()
    expect(screen.getByText("(app.js)")).toBeInTheDocument()
  })

  it("shows the chat session row when chatId is provided", async () => {
    const ref = renderButton({ context: "Chat", chatId: 42 })
    await openDialog(ref)

    expect(screen.getByText("Chat session:")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
  })

  it("omits the chat session row when chatId is not provided", async () => {
    const ref = renderButton()
    await openDialog(ref)

    expect(screen.queryByText("Chat session:")).not.toBeInTheDocument()
  })

  it("shows feature flags in the preview when featureFlags are provided", async () => {
    const ref = renderButton({
      featureFlags: { coding_mode: true, terminal: false, video_walkthroughs: true }
    })
    await openDialog(ref)

    expect(screen.getByText("Features")).toBeInTheDocument()
    expect(screen.getByText("coding_mode")).toBeInTheDocument()
    expect(screen.getByText("terminal")).toBeInTheDocument()
    expect(screen.getByText("video_walkthroughs")).toBeInTheDocument()
  })

  it("omits the features section when featureFlags are not provided", async () => {
    const ref = renderButton()
    await openDialog(ref)

    expect(screen.queryByText("Features")).not.toBeInTheDocument()
  })

  it("includes enabled_features in the submitted context JSON when featureFlags are provided", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)

    const ref = renderButton({ featureFlags: { coding_mode: true, terminal: false } })
    await openDialog(ref)

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(mockCreateBugReport).toHaveBeenCalledOnce())

    const ctx = JSON.parse(mockCreateBugReport.mock.calls[0][0].context as string)
    expect(ctx.enabled_features).toEqual({ coding_mode: true, terminal: false })
  })

  it("omits enabled_features from context when featureFlags are not provided", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)

    const ref = renderButton()
    await openDialog(ref)

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(mockCreateBugReport).toHaveBeenCalledOnce())

    const ctx = JSON.parse(mockCreateBugReport.mock.calls[0][0].context as string)
    expect(ctx.enabled_features).toBeUndefined()
  })

  it("sends context JSON with the bug report submission", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)
    mockGetRecentErrors.mockReturnValue([
      { message: "ReferenceError: x is not defined", source: "chunk.js", at: "2025-06-01T12:00:00.000Z" }
    ])

    const ref = renderButton({ context: "Admin" })
    await openDialog(ref)

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

    const ref = renderButton({ context: "Chat", chatId: 99 })
    await openDialog(ref)

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(mockCreateBugReport).toHaveBeenCalledOnce())

    const ctx = JSON.parse(mockCreateBugReport.mock.calls[0][0].context as string)
    expect(ctx.chat_session_id).toBe(99)
  })

  it("closes the dialog on cancel", async () => {
    const ref = renderButton()
    await openDialog(ref)

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("shows a queued notice on successful direct-job submission", async () => {
    mockCreateBugReport.mockResolvedValue({ message: "Bug report queued." } satisfies BugReportPayload)

    const ref = renderButton({ bugReportMode: "direct_job" })
    await openDialog(ref)

    fireEvent.submit(screen.getByRole("dialog").querySelector("form")!)

    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(screen.getByRole("status")).toHaveTextContent("Bug report queued.")
  })

  describe("when opened without messages", () => {
    it("does not show the transcript section", async () => {
      const ref = renderButton()
      await openDialog(ref)

      expect(screen.queryByRole("checkbox", { name: /include chat transcript/i })).not.toBeInTheDocument()
    })
  })

  describe("when opened via handle with messages", () => {
    it("shows the transcript checkbox", async () => {
      const ref = renderButton()

      ref.current?.open(reportOptions(sampleMessages))

      await screen.findByRole("checkbox", { name: /include chat transcript/i })
    })

    it("does not show transcript preview when checkbox is unchecked (default)", async () => {
      const ref = renderButton()

      ref.current?.open(reportOptions(sampleMessages))

      await screen.findByRole("checkbox", { name: /include chat transcript/i })
      expect(screen.queryByText(/\[User\] Hello, I found a bug\./)).not.toBeInTheDocument()
      expect(screen.queryByText(/\[Assistant\] Thanks for reporting!/)).not.toBeInTheDocument()
    })

    it("shows transcript preview when checkbox is checked", async () => {
      const ref = renderButton()

      ref.current?.open(reportOptions(sampleMessages))

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      expect(screen.getByText(/\[User\] Hello, I found a bug\./)).toBeInTheDocument()
      expect(screen.getByText(/\[Assistant\] Thanks for reporting!/)).toBeInTheDocument()
    })

    it("filters tool_use and empty messages from the preview", async () => {
      const ref = renderButton()

      ref.current?.open(reportOptions(sampleMessages))

      const checkbox = await screen.findByRole("checkbox", { name: /include chat transcript/i })
      fireEvent.click(checkbox)

      expect(screen.getByText(/\[User\] Hello, I found a bug\./)).toBeInTheDocument()
      expect(screen.getByText(/\[Assistant\] Thanks for reporting!/)).toBeInTheDocument()
      expect(screen.queryByText(/\[Tool/)).not.toBeInTheDocument()
    })

    it("submits without transcript file when checkbox is unchecked", async () => {
      const ref = renderButton()

      ref.current?.open(reportOptions(sampleMessages))

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

      ref.current?.open(reportOptions(sampleMessages))

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

      ref.current?.open(reportOptions(sampleMessages))

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

      ref.current?.open(reportOptions(sampleMessages))

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

  describe("optional attachments", () => {
    it("does not submit an unchecked generated attachment", async () => {
      const ref = renderButton({
        pageAttachments: [{
          id: "diagnostics",
          label: "Diagnostics",
          preview: "diagnostic preview",
          defaultChecked: false,
          buildFile: () => new File(["diagnostic body"], "diagnostics.txt", { type: "text/plain" })
        }]
      })

      await openDialog(ref)
      expect(screen.getByRole("checkbox", { name: /diagnostics/i })).not.toBeChecked()
      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(() => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        expect((input.attachments ?? []).some((file: File) => file.name === "diagnostics.txt")).toBe(false)
      })
    })

    it("submits a checked generated attachment with its filename, type, and content", async () => {
      const ref = renderButton({
        pageAttachments: [{
          id: "diagnostics",
          label: "Diagnostics",
          preview: "diagnostic preview",
          defaultChecked: true,
          buildFile: () => new File(["diagnostic body"], "diagnostics.txt", { type: "text/plain" })
        }]
      })

      await openDialog(ref)
      expect(screen.getByText("diagnostic preview")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(async () => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const generatedFile = (input.attachments ?? []).find((file: File) => file.name === "diagnostics.txt")
        expect(generatedFile).toBeDefined()
        expect(generatedFile?.type).toBe("text/plain")
        expect(await generatedFile!.text()).toBe("diagnostic body")
      })
    })

    it("counts selected generated attachments against the attachment limit", async () => {
      const ref = renderButton({
        pageAttachments: [{
          id: "diagnostics",
          label: "Diagnostics",
          defaultChecked: true,
          buildFile: () => new File(["diagnostic body"], "diagnostics.txt", { type: "text/plain" })
        }]
      })

      await openDialog(ref)
      const files = Array.from({ length: 9 }, (_, index) => new File([`file ${index}`], `file-${index}.txt`, { type: "text/plain" }))
      fireEvent.change(screen.getByLabelText(/add files/i), { target: { files } })
      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      expect(await screen.findByText("You can attach at most 9 additional files.")).toBeInTheDocument()
      expect(bugReportsApi.createBugReport).not.toHaveBeenCalled()
    })
  })

  describe("when opened via handle without messages", () => {
    it("does not show the transcript section", async () => {
      const ref = renderButton()

      ref.current?.open({ optionalAttachments: [] })

      await screen.findByRole("dialog")
      expect(screen.queryByRole("checkbox", { name: /include chat transcript/i })).not.toBeInTheDocument()
    })
  })

  describe("screenshot capture", () => {
    it("passes an onclone callback to the viewport capture", async () => {
      const ref = renderButton()
      await openDialog(ref)

      await waitFor(() => expect(mockHtml2canvas).toHaveBeenCalled())

      const [, options] = mockHtml2canvas.mock.calls[0]
      expect(options).toMatchObject({ onclone: expect.any(Function) })
    })

    it("onclone callback converts sticky-positioned elements to relative", async () => {
      const ref = renderButton()
      await openDialog(ref)

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
      const ref = renderButton()
      await openDialog(ref)

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

      const ref = renderButton()
      await openDialog(ref)

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
      // Regression: html2canvas resets scrollTop to 0 in the cloned document. The chat
      // message stream uses overflow-y-auto (not window scroll), so without this sync the
      // screenshot shows the top of the container, not the current view.
      const ref = renderButton()
      await openDialog(ref)

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
      const ref = renderButton()
      await openDialog(ref)

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
      const ref = renderButton()
      await openDialog(ref)

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

  describe("screenshot annotation", () => {
    let imageSrcs: string[]
    let objectUrlCount: number

    beforeEach(() => {
      imageSrcs = []
      objectUrlCount = 0
      URL.createObjectURL = vi.fn(() => `blob:mock-url-${objectUrlCount++}`)

      vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation(function (this: HTMLCanvasElement) {
        const canvas = this as HTMLCanvasElement & { __mockContext?: CanvasRenderingContext2D }
        if (!canvas.__mockContext) {
          canvas.__mockContext = {
            beginPath: vi.fn(), clearRect: vi.fn(), drawImage: vi.fn(), ellipse: vi.fn(),
            fillText: vi.fn(), lineTo: vi.fn(), moveTo: vi.fn(), rect: vi.fn(), save: vi.fn(),
            restore: vi.fn(), setLineDash: vi.fn(), stroke: vi.fn(), fill: vi.fn()
          } as unknown as CanvasRenderingContext2D
        }
        return canvas.__mockContext
      })
      vi.spyOn(HTMLCanvasElement.prototype, "toDataURL").mockReturnValue("data:image/png;base64,YW5ub3RhdGVk")
      vi.spyOn(HTMLCanvasElement.prototype, "getBoundingClientRect").mockReturnValue({
        bottom: 80, height: 80, left: 0, right: 100, top: 0, width: 100, x: 0, y: 0, toJSON: () => ({})
      })

      Object.defineProperty(globalThis, "Image", {
        configurable: true,
        writable: true,
        value: class MockImage {
          naturalWidth = 100
          naturalHeight = 80
          width = 100
          height = 80
          onload: (() => void) | null = null
          set src(value: string) {
            imageSrcs.push(value)
            window.setTimeout(() => this.onload?.(), 0)
          }
        }
      })
    })

    async function annotate() {
      fireEvent.click(screen.getByRole("button", { name: "Annotate screenshot" }))
      await screen.findByRole("dialog", { name: /Annotate/ })
      await waitFor(() => expect(screen.getByRole("button", { name: "Done" })).not.toBeDisabled())
    }

    it("does not show an Annotate button when no screenshot is selected", async () => {
      const ref = renderButton()
      await openDialog(ref)

      fireEvent.click(screen.getByRole("radio", { name: "No screenshot" }))

      expect(screen.queryByRole("button", { name: "Annotate screenshot" })).not.toBeInTheDocument()
    })

    it("shows an Annotate button for the captured viewport screenshot", async () => {
      const ref = renderButton()
      await openDialog(ref)

      expect(screen.getByRole("button", { name: "Annotate screenshot" })).toBeInTheDocument()
    })

    it("opens the annotation editor for the captured screenshot", async () => {
      const ref = renderButton()
      await openDialog(ref)

      await annotate()

      expect(screen.getByRole("dialog", { name: "Annotate bug-report-viewport.png" })).toBeInTheDocument()
    })

    it("closes the annotation editor without changing the screenshot on cancel", async () => {
      const ref = renderButton()
      await openDialog(ref)

      await annotate()
      const annotationDialog = screen.getByRole("dialog", { name: /Annotate/ })
      fireEvent.click(within(annotationDialog).getByRole("button", { name: "Cancel" }))

      expect(screen.queryByRole("dialog", { name: /Annotate/ })).not.toBeInTheDocument()
    })

    it("submits the annotated screenshot instead of the raw capture", async () => {
      const ref = renderButton()
      await openDialog(ref)

      await annotate()
      fireEvent.click(screen.getByRole("button", { name: "Done" }))
      await waitFor(() => expect(screen.queryByRole("dialog", { name: /Annotate/ })).not.toBeInTheDocument())

      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(async () => {
        expect(bugReportsApi.createBugReport).toHaveBeenCalledTimes(1)
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        expect(input.screenshot).toBeInstanceOf(File)
        const text = await (input.screenshot as File).text()
        expect(text).toBe("annotated")
      })
    })

    it("supports annotating the full-page screenshot", async () => {
      const ref = renderButton()
      await openDialog(ref)

      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      await waitFor(() => expect(screen.getByRole("button", { name: "Annotate screenshot" })).toBeInTheDocument())

      await annotate()
      fireEvent.click(screen.getByRole("button", { name: "Done" }))
      await waitFor(() => expect(screen.queryByRole("dialog", { name: /Annotate/ })).not.toBeInTheDocument())

      fireEvent.click(screen.getByRole("button", { name: /create job/i }))

      await waitFor(async () => {
        const [input] = vi.mocked(bugReportsApi.createBugReport).mock.calls[0]
        const text = await (input.screenshot as File).text()
        expect(text).toBe("annotated")
      })
    })

    it("preserves the original screenshot so re-opening the annotator edits from the pristine capture", async () => {
      const ref = renderButton()
      await openDialog(ref)

      await annotate()
      fireEvent.click(screen.getByRole("button", { name: "Done" }))
      await waitFor(() => expect(screen.queryByRole("dialog", { name: /Annotate/ })).not.toBeInTheDocument())

      const firstLoadSrc = imageSrcs[0]

      await annotate()

      // Both the first and second edit session must load pixels from the same pristine
      // screenshot URL, not from the annotated result produced by the first "Done".
      expect(imageSrcs[imageSrcs.length - 1]).toBe(firstLoadSrc)
    })
  })
})
