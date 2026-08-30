import { render, screen, fireEvent } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi, beforeEach } from "vitest"
import { AttachmentCard } from "./components"
import type { JobAttachment } from "../../api/jobs"
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
    renderCard(attachment({
      filename: "screenshot.png",
      content_type: "image/png",
      byte_size: 1024,
      file_path: "/api/v1/app/jobs/7/attachments/1/file",
      content_path: "/api/v1/app/jobs/7/attachments/1/content"
    }))

    fireEvent.click(screen.getByRole("button", { name: "screenshot.png" }))

    const image = await screen.findByRole("img", { name: "screenshot.png" })
    expect(image).toHaveAttribute("src", "/api/v1/app/jobs/7/attachments/1/file")
    expect(fetchJobAttachmentContent).not.toHaveBeenCalled()
    expect(screen.getByRole("link", { name: "Open raw" })).toHaveAttribute("href", "/api/v1/app/jobs/7/attachments/1/file")
  })

  it("uses a raw link for PDFs even when a content endpoint exists", () => {
    renderCard(attachment({
      filename: "report.pdf",
      content_type: "application/pdf",
      file_path: "/api/v1/app/jobs/7/attachments/1/file",
      content_path: "/api/v1/app/jobs/7/attachments/1/content"
    }))

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
    renderCard(attachment({
      kind: "google_doc",
      attachment_type: "google_doc_link",
      filename: null,
      content_type: null,
      google_doc_url: "https://docs.google.com/document/d/abc/edit",
      uploaded_file: false,
      file_path: null,
      content_path: null
    }))

    expect(screen.queryByRole("button")).not.toBeInTheDocument()
    expect(fetchJobAttachmentContent).not.toHaveBeenCalled()
  })
})
