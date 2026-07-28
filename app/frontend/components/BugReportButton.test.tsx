import { createRef } from "react"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { BugReportButton, type BugReportButtonHandle } from "./BugReportButton"
import * as bugReportsApi from "../api/bugReports"
import type { ChatMessageItem } from "../api/chats"

vi.mock("html2canvas-pro", () => ({
  default: vi.fn().mockResolvedValue({
    toBlob: (cb: (blob: Blob | null) => void) => cb(new Blob(["screenshot"], { type: "image/png" }))
  })
}))

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn()
}))

// jsdom does not implement URL.createObjectURL
URL.createObjectURL = vi.fn().mockReturnValue("blob:mock-url")
URL.revokeObjectURL = vi.fn()

const sampleMessages: ChatMessageItem[] = [
  { type: "message", id: 1, role: "user", text: "Hello, I found a bug.", bookmarkable: false },
  { type: "message", id: 2, role: "assistant", text: "Thanks for reporting!", bookmarkable: false },
  { type: "message", id: 3, role: "tool_use", text: "", bookmarkable: false },
]

function renderButton(props: { bugReportMode?: "direct_job" | "github_issue" | null } = {}) {
  const ref = createRef<BugReportButtonHandle>()
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <BugReportButton
        bugReportMode={props.bugReportMode ?? "direct_job"}
        context="Chat"
        ref={ref}
        reportIssueRepoSlug={null}
      />
    </QueryClientProvider>
  )
  return ref
}

describe("BugReportButton", () => {
  beforeEach(() => {
    vi.mocked(bugReportsApi.createBugReport).mockResolvedValue({ message: "Bug report queued." })
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
})
