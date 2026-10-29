import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, beforeEach } from "vitest"
import { AttachmentCard, EpicSummaryLink, RunTranscriptLogs } from "./components"
import type { JobAttachment, JobEpic } from "../../api/jobs"
import { fetchJobAttachmentContent } from "../../api/jobs"

vi.mock("../../api/jobs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/jobs")>()
  return {
    ...actual,
    fetchJobAttachmentContent: vi.fn()
  }
})

function client() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function attachment(overrides: Partial<JobAttachment> = {}): JobAttachment {
  return {
    id: 1,
    kind: "file",
    attachment_type: "uploaded_file",
    title: null,
    filename: "notes.md",
    content_type: "text/markdown",
    byte_size: 42,
    google_doc_url: null,
    uploaded_file: true,
    file_path: "/api/v1/app/jobs/7/attachments/1/file",
    content_path: "/api/v1/app/jobs/7/attachments/1/content",
    created_at: null,
    app_delete_path: "/api/v1/app/jobs/7/attachments/1",
    ...overrides
  }
}

function renderCard(value: JobAttachment) {
  return render(
    <QueryClientProvider client={client()}>
      <AttachmentCard attachment={value} />
    </QueryClientProvider>
  )
}

beforeEach(() => {
  vi.mocked(fetchJobAttachmentContent).mockReset()
})

describe("AttachmentCard", () => {
  it("opens the source preview modal for a markdown attachment instead of navigating", async () => {
    vi.mocked(fetchJobAttachmentContent).mockResolvedValue({ path: "notes.md", content: "# Notes\n\nHello", binary: false, too_large: false })
    renderCard(attachment())

    expect(screen.queryByRole("link", { name: "notes.md" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "notes.md" }))

    expect(await screen.findByRole("dialog", { name: /file preview/i })).toBeInTheDocument()
    expect(fetchJobAttachmentContent).toHaveBeenCalledWith("/api/v1/app/jobs/7/attachments/1/content")
    expect(await screen.findByRole("heading", { name: "Notes" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/jobs/7/attachments/1/file")
  })

  it("renders an image attachment from the raw file URL without fetching content", async () => {
    renderCard(
      attachment({
        filename: "screenshot.png",
        content_type: "image/png",
        byte_size: 1024,
        file_path: "/api/v1/app/jobs/7/attachments/1/file",
        content_path: "/api/v1/app/jobs/7/attachments/1/content"
      })
    )

    fireEvent.click(screen.getByRole("button", { name: "screenshot.png" }))

    const image = await screen.findByRole("img", { name: "screenshot.png" })
    expect(image).toHaveAttribute("src", "/api/v1/app/jobs/7/attachments/1/file")
    expect(fetchJobAttachmentContent).not.toHaveBeenCalled()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/jobs/7/attachments/1/file")
  })

  it("uses a raw link for PDFs even when a content endpoint exists", () => {
    renderCard(
      attachment({
        filename: "report.pdf",
        content_type: "application/pdf",
        file_path: "/api/v1/app/jobs/7/attachments/1/file",
        content_path: "/api/v1/app/jobs/7/attachments/1/content"
      })
    )

    expect(screen.queryByRole("button", { name: "report.pdf" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "report.pdf" })).toHaveAttribute("href", "/api/v1/app/jobs/7/attachments/1/file")
    expect(fetchJobAttachmentContent).not.toHaveBeenCalled()
  })

  it("renders source with syntax highlighting when switching out of markdown preview", async () => {
    vi.mocked(fetchJobAttachmentContent).mockResolvedValue({ path: "notes.md", content: "# Notes\n\nHello", binary: false, too_large: false })
    renderCard(attachment())

    fireEvent.click(screen.getByRole("button", { name: "notes.md" }))
    fireEvent.click(await screen.findByRole("button", { name: "Source" }))

    expect(await screen.findByTestId("source-preview-code")).toHaveTextContent("# Notes")
  })

  it("falls back to a plain download link for Google Doc attachments (no content to preview)", () => {
    renderCard(
      attachment({
        kind: "google_doc",
        attachment_type: "google_doc_link",
        filename: null,
        content_type: null,
        google_doc_url: "https://docs.google.com/document/d/abc/edit",
        uploaded_file: false,
        file_path: null,
        content_path: null
      })
    )

    expect(screen.queryByRole("button")).not.toBeInTheDocument()
    expect(fetchJobAttachmentContent).not.toHaveBeenCalled()
  })
})

describe("EpicSummaryLink", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  function epic(overrides: Partial<JobEpic> = {}): JobEpic {
    return {
      id: 385,
      number: 385,
      display_number: "EPIC-385",
      title: "Tailscale Privileged Service Migration",
      state: "in_progress",
      epic_path: "/epics/EPIC-385",
      ...overrides
    }
  }

  it("renders the epic slug as a copyable button separate from the title link", () => {
    render(
      <MemoryRouter>
        <EpicSummaryLink epic={epic()} prefix="/app-shell" />
      </MemoryRouter>
    )

    const copyButton = screen.getByRole("button", { name: "Copy EPIC-385 to clipboard" })
    expect(copyButton).toBeInTheDocument()

    const titleLink = screen.getByRole("link", { name: "Tailscale Privileged Service Migration" })
    expect(titleLink).toHaveAttribute("href", "/app-shell/epics/EPIC-385")
  })

  it("copies the epic slug to the clipboard when clicked", async () => {
    render(
      <MemoryRouter>
        <EpicSummaryLink epic={epic()} prefix="/app-shell" />
      </MemoryRouter>
    )

    const copyButton = screen.getByRole("button", { name: "Copy EPIC-385 to clipboard" })
    fireEvent.click(copyButton)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("EPIC-385")
    // Wait out the async clipboard-write resolution so its state update lands
    // before this test (and its clipboard mock) tears down -- otherwise the
    // update fires during a later test and can flip that test's outcome.
    await waitFor(() => expect(copyButton).toHaveAttribute("title", "Copied"))
  })
})

describe("RunTranscriptLogs", () => {
  it("renders assistant, system, and structured tools with the chat surfaces", () => {
    render(
      <MemoryRouter>
        <RunTranscriptLogs
          agentic
          logs={[
            { id: 1, sequence: 1, kind: "assistant_text", chunk: "**Done** with JOB-42", created_at: null },
            { id: 2, sequence: 2, kind: "system", chunk: "System notice", created_at: null },
            {
              id: 3,
              sequence: 3,
              kind: "tool_call",
              chunk: "[codex command] /bin/bash -lc 'bundle exec rspec' in_progress",
              tool_name: "bash",
              tool_input: { command: "bundle exec rspec" },
              tool_use_id: "cmd-1",
              created_at: null
            },
            {
              id: 4,
              sequence: 4,
              kind: "tool_result",
              chunk: "[codex command] /bin/bash -lc 'bundle exec rspec' completed",
              tool_name: "bash",
              tool_use_id: "cmd-1",
              tool_result_content: "2 examples, 0 failures",
              tool_result_error: false,
              created_at: null
            },
            { id: 5, sequence: 5, kind: "stdout", chunk: "branch-name-without-natural-breakpoints-abcdefghijklmnopqrstuvwxyz", created_at: null }
          ]}
        />
      </MemoryRouter>
    )

    const stream = screen.getByTestId("run-transcript-log-stream")
    expect(stream).toHaveClass("min-w-0", "overflow-y-auto", "overflow-x-hidden")
    expect(stream).toHaveClass("space-y-4", "px-3", "pb-3")
    const assistantDone = screen.getByText("Done", { selector: "strong" })
    expect(assistantDone).toBeInTheDocument()
    expect(assistantDone.closest(".chat-prose")).toHaveClass("[overflow-wrap:anywhere]")
    expect(screen.getByTestId("run-transcript-log-assistant")).toHaveAttribute("data-message-mode", "read-only")
    expect(screen.getByTestId("run-transcript-log-assistant")).not.toHaveTextContent("Agent")
    const systemRows = screen.getAllByTestId("run-transcript-log-system")
    expect(systemRows[0]).toHaveTextContent("System notice")
    expect(systemRows[0]).toHaveAttribute("data-message-mode", "read-only")
    expect(screen.getByTestId("run-transcript-tool-group")).toHaveAttribute("data-message-mode", "read-only")
    expect(screen.getByText("bash")).toBeInTheDocument()
    expect(screen.getByText("Done", { selector: "span" })).toBeInTheDocument()
    expect(stream).not.toHaveTextContent("[codex command]")
    expect(stream).not.toHaveTextContent("/bin/bash -lc")
    expect(systemRows[1]).toHaveTextContent(/branch-name-without/)
  })

  it("coalesces non-agentic chunks into compact ANSI-aware log rows", () => {
    render(
      <MemoryRouter>
        <RunTranscriptLogs
          agentic={false}
          logs={[
            { id: 1, sequence: 1, kind: "system", chunk: "starting grader", created_at: null },
            { id: 2, sequence: 2, kind: "stdout", chunk: "\u001b[32mpassed", created_at: null },
            { id: 3, sequence: 3, kind: "stdout", chunk: "all examples\u001b[0m", created_at: null }
          ]}
        />
      </MemoryRouter>
    )

    const stream = screen.getByTestId("run-transcript-log-stream")
    expect(stream).toHaveClass("space-y-1")
    expect(stream).not.toHaveClass("space-y-4")
    expect(screen.getAllByTestId("run-transcript-log-compact")).toHaveLength(2)
    expect(screen.getAllByTestId("run-transcript-compact-output")[1]).toHaveTextContent("passed all examples")
    expect(stream.textContent).not.toContain("\u001b[")
    expect(screen.queryByTestId("run-transcript-log-system")).not.toBeInTheDocument()
  })
})
