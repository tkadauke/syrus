import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import createRepoDocumentToolCard from "./create_repo_document"
import deleteRepoDocumentToolCard from "./delete_repo_document"
import listRepoDocumentsToolCard from "./list_repo_documents"
import readRepoDocumentToolCard, { examples as readRepoDocumentExamples } from "./read_repo_document"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const documentRows = [
  {
    id: 12,
    ref: "repo-doc-12",
    kind: "file",
    title: "API Guide",
    status: "attached",
    repository_id: 7,
    repository: "tkadauke/syrus",
    content_type: "text/markdown",
    size_bytes: 2048
  },
  {
    id: 13,
    kind: "google_doc",
    title: "Launch Notes",
    status: "pending",
    repository_id: 7,
    repository_slug: "tkadauke/syrus",
    url: "https://docs.google.com/document/d/abc/edit"
  }
]

describe("repository document tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(listRepoDocumentsToolCard.toolName).toBe("list_repo_documents")
    expect(readRepoDocumentToolCard.toolName).toBe("read_repo_document")
    expect(createRepoDocumentToolCard.toolName).toBe("create_repo_document")
    expect(deleteRepoDocumentToolCard.toolName).toBe("delete_repo_document")
  })

  it("renders provider-specific MCP envelopes through the shared normalizers", () => {
    const payload = { pending_action_id: 501, state: "pending", message: "Create **API Guide**?" }
    const codexEnvelope = { content: [{ type: "text", text: JSON.stringify(payload) }], structured_content: null }
    const claudeEnvelope = { structured_content: payload, content: [{ type: "text", text: "ignored fallback" }] }

    for (const [rawName, envelope] of [
      ["mcp__syrus-chat-sidecar__create_repo_document", codexEnvelope],
      ["syrus-chat-deferred-sidecar.create_repo_document", claudeEnvelope]
    ] as const) {
      const toolName = normalizedToolName(rawName)
      const cardContext = context(toolName, {
        input: { repository_id: 7, title: "API Guide", body: "# Guide" },
        parsedResult: normalizedToolCardParsedResult(envelope)
      })

      expect(toolName).toBe("create_repo_document")
      expect(createRepoDocumentToolCard.collapsedSummary?.(cardContext)).toBe("Create API Guide · Create API Guide?")
    }
  })

  it("renders an empty document list", () => {
    const parsedResult: unknown[] = []
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult }))).toBe("No repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult }))}</>)
    expect(screen.getByText("No repository documents found.")).toBeInTheDocument()
  })

  it("renders document list metadata without dumping raw details", () => {
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult: documentRows }))).toBe("2 repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult: documentRows }))}</>)

    const documentLink = screen.getByRole("link", { name: "API Guide" })
    expect(documentLink).toHaveAttribute("href", "/api/v1/app/repository_documents/12/file")
    expect(documentLink).toHaveClass("break-all")
    expect(documentLink.closest("article")).toHaveClass("min-w-0")
    expect(screen.queryByRole("table")).not.toBeInTheDocument()
    expect(screen.getByText("repo-doc-12")).toBeInTheDocument()
    expect(screen.getByText("file")).toBeInTheDocument()
    expect(screen.getByText("attached")).toBeInTheDocument()
    const repositoryLinks = screen.getAllByRole("link", { name: "tkadauke/syrus" })
    expect(repositoryLinks).toHaveLength(2)
    expect(repositoryLinks[0]).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByText("text/markdown")).toBeInTheDocument()
    expect(screen.getByText("2.0 KB")).toBeInTheDocument()
    expect(screen.getByText("google_doc")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Launch Notes" })).toHaveAttribute("href", "https://docs.google.com/document/d/abc/edit")
    expect(screen.getByRole("link", { name: "https://docs.google.com/document/d/abc/edit" })).toHaveAttribute(
      "href",
      "https://docs.google.com/document/d/abc/edit"
    )
  })

  it("normalizes root-array and wrapped list envelopes from different providers", () => {
    const envelopes = [
      {
        rawName: "mcp__syrus-chat-sidecar__list_repo_documents",
        envelope: { content: [{ type: "text", text: JSON.stringify(documentRows) }], structured_content: null }
      },
      {
        rawName: "syrus-chat-deferred-sidecar.list_repo_documents",
        envelope: { structured_content: { documents: documentRows }, content: [{ type: "text", text: "ignored fallback" }] }
      }
    ]

    for (const { rawName, envelope } of envelopes) {
      const toolName = normalizedToolName(rawName)
      const cardContext = context(toolName, { parsedResult: normalizedToolCardParsedResult(envelope) })

      expect(toolName).toBe("list_repo_documents")
      expect(listRepoDocumentsToolCard.collapsedSummary?.(cardContext)).toBe("2 repository documents")
    }
  })

  it("renders list failures as a dedicated error card", () => {
    const failed = context("list_repo_documents", {
      resultBody: "Repository documents are temporarily unavailable",
      resultError: true
    })

    expect(listRepoDocumentsToolCard.collapsedSummary?.(failed)).toBe("List repository documents failed: Repository documents are temporarily unavailable")
    render(<>{listRepoDocumentsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("List repository documents failed")).toBeInTheDocument()
    expect(screen.getByText("Repository documents are temporarily unavailable")).toBeInTheDocument()
  })

  it("renders a document detail/read card with a concise content preview", () => {
    const resultBody = "# Overview\nKeep this **short**.\nUse read_repo_document for full text."

    expect(readRepoDocumentToolCard.collapsedSummary?.(context("read_repo_document", { input: { id: 12 }, resultBody }))).toBe("Document 12 read")
    render(
      <>
        {readRepoDocumentToolCard.renderExpanded(
          context("read_repo_document", { input: { id: 12, title: "API Guide", content_type: "text/markdown" }, resultBody })
        )}
      </>
    )

    expect(screen.getByText("API Guide")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("Content preview")).toBeInTheDocument()
    expect(screen.getByText("short", { selector: "strong" })).toBeInTheDocument()
  })

  it("uses prior list metadata to link the document and show a truncation badge", () => {
    const resultBody = `${"Long notes. ".repeat(140)}\n\n[Document truncated after 65536 bytes; omitted 2048 bytes.]`
    const cardContext = context("read_repo_document", {
      input: { id: 12 },
      resultBody,
      priorResults: { list_repo_documents: { documents: documentRows } }
    })

    render(<>{readRepoDocumentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: "API Guide" })).toHaveAttribute("href", "/api/v1/app/repository_documents/12/file")
    expect(screen.getByText("text/markdown")).toBeInTheDocument()
    expect(screen.getByText("2.0 KB")).toBeInTheDocument()
    expect(screen.getByText("server truncated")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("keeps plain-text document content monospace in the preview and expanded modal", () => {
    const resultBody = `First line\n${"Plain text content. ".repeat(100)}`
    render(
      <>
        {readRepoDocumentToolCard.renderExpanded(
          context("read_repo_document", { input: { id: 18, title: "Plain notes", content_type: "text/plain" }, resultBody })
        )}
      </>
    )

    expect(screen.getByTestId("markdown-preview-content")).toHaveClass("font-mono")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    const dialog = screen.getByRole("dialog", { name: "Plain notes content" })
    expect(dialog.querySelector(".chat-prose")).toHaveClass("font-mono", "whitespace-pre-wrap")
  })

  it("renders image content blocks from differently shaped provider envelopes", () => {
    const image = { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }
    const envelopes = [{ content: [image] }, { output: { payload: { content: [{ ...image, mime_type: "image/png", mimeType: undefined }] } } }]

    for (const [index, parsedResult] of envelopes.entries()) {
      const { unmount } = render(
        <>{readRepoDocumentToolCard.renderExpanded(context("read_repo_document", { input: { id: 20 + index, title: `Screenshot ${index}` }, parsedResult }))}</>
      )
      const thumbnail = screen.getByRole("button", { name: `Open Screenshot ${index}` })
      expect(thumbnail).toBeInTheDocument()
      fireEvent.click(thumbnail)
      expect(screen.getByRole("dialog", { name: `Screenshot ${index} preview` })).toBeInTheDocument()
      unmount()
    }
  })

  it("provides a valid, linked image fixture for the tool card catalog", () => {
    const example = readRepoDocumentExamples.find((item) => item.id === "image")
    expect(example).toBeDefined()
    const cardContext = context("read_repo_document", {
      input: example?.input,
      parsedResult: example?.parsedResult,
      resultSettled: true
    })

    render(<>{readRepoDocumentToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByRole("link", { name: "Architecture sketch" })).toHaveAttribute("href", "/api/v1/app/repository_documents/13/file")
    const thumbnail = screen.getByRole("img", { name: "Architecture sketch" })
    expect(thumbnail).toHaveAttribute("src", expect.stringMatching(/^data:image\/svg\+xml;base64,PHN2Zy/))
    fireEvent.click(screen.getByRole("button", { name: "Open Architecture sketch" }))
    expect(screen.getByRole("dialog", { name: "Architecture sketch preview" })).toBeInTheDocument()
  })

  it("renders failed, pending, and settled blank reads distinctly", () => {
    const failed = context("read_repo_document", { input: { id: 404 }, resultBody: "document not found", resultError: true })
    expect(readRepoDocumentToolCard.collapsedSummary?.(failed)).toBe("Read repository document failed: document not found")
    const { unmount } = render(<>{readRepoDocumentToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Read repository document failed")).toBeInTheDocument()
    unmount()

    render(<>{readRepoDocumentToolCard.renderPending?.(context("read_repo_document", { input: { id: 12, title: "Notes" }, resultSettled: false }))}</>)
    expect(screen.getByText("Waiting for the document result.")).toBeInTheDocument()
    unmount()

    render(<>{readRepoDocumentToolCard.renderExpanded(context("read_repo_document", { input: { id: 12, title: "Notes" }, resultSettled: true }))}</>)
    expect(screen.getByText("This document is blank.")).toBeInTheDocument()
  })

  it("renders a create document pending outcome with the affected document", () => {
    const parsedResult = {
      pending_action_id: 501,
      state: "pending",
      message: 'Create document "API Guide" in repository 7?'
    }
    const input = {
      repository_id: 7,
      repository_slug: "tkadauke/syrus",
      title: "API Guide",
      body: "# Line one\n\nSee **JOB-42** and https://example.test/docs."
    }

    expect(createRepoDocumentToolCard.collapsedSummary?.(context("create_repo_document", { input, parsedResult }))).toBe(
      'Create API Guide · Create document "API Guide" in repository 7?'
    )
    render(<>{createRepoDocumentToolCard.renderExpanded(context("create_repo_document", { input, parsedResult }))}</>)

    expect(screen.getByText("Create document")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("API Guide")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByText("text/markdown")).toBeInTheDocument()
    expect(screen.getByText(/B$/)).toBeInTheDocument()
    expect(screen.getByText("Body preview")).toBeInTheDocument()
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.test/docs" })).toHaveAttribute("href", "https://example.test/docs")
  })

  it("renders plain validation failures instead of falling back to the generic card", () => {
    const failed = context("create_repo_document", {
      input: { repository_id: 7, title: "", body: "Notes" },
      resultBody: "title is required",
      resultError: true
    })

    expect(createRepoDocumentToolCard.collapsedSummary?.(failed)).toBe("Create repository document failed: title is required")
    render(<>{createRepoDocumentToolCard.renderExpanded(failed)}</>)

    expect(screen.getByText("Create repository document failed")).toBeInTheDocument()
    expect(screen.getByText("title is required")).toBeInTheDocument()
  })

  it("renders Markdown pending copy and a blank-body empty state", () => {
    const parsedResult = {
      pending_confirmation_id: 503,
      state: "pending",
      message: "Create **Notes**?",
      reason: "Review [policy](https://example.test/policy)."
    }
    const input = { repository_id: 7, title: "Notes", body: "" }

    render(<>{createRepoDocumentToolCard.renderExpanded(context("create_repo_document", { input, parsedResult }))}</>)

    expect(screen.getByText("Notes", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "policy" })).toHaveAttribute("href", "https://example.test/policy")
    expect(screen.getByText("No document body provided.")).toBeInTheDocument()
  })

  it("links a completed document from the live serialized pending-action result", () => {
    const parsedResult = { pending_action_id: 504, state: "pending", message: "Create Runbook?" }
    const livePendingAction = {
      id: 504,
      action: "create_repo_document",
      state: "confirmed" as const,
      label: "Create document Runbook",
      detail: "title: Runbook",
      execution_status: "applied",
      document: {
        id: 22,
        title: "Runbook",
        repository_id: 7,
        repository_slug: "tkadauke/syrus",
        content_type: "text/markdown",
        size_bytes: 2048,
        url: "/api/v1/app/repository_documents/22/file"
      },
      resource_title: "Runbook",
      resource_url: "/api/v1/app/repository_documents/22/file",
      app_confirm_path: "/confirm",
      app_reject_path: "/reject"
    }

    render(
      <>
        {createRepoDocumentToolCard.renderExpanded(
          context("create_repo_document", { input: { repository_id: 7, body: "# Runbook" }, parsedResult, livePendingAction })
        )}
      </>
    )

    expect(screen.getByRole("link", { name: "Runbook" })).toHaveAttribute("href", "/api/v1/app/repository_documents/22/file")
    expect(screen.getByText("2.0 KB")).toBeInTheDocument()
  })

  it("renders a delete document pending outcome with confirmation/error state", () => {
    const parsedResult = {
      pending_action_id: 502,
      state: "failed",
      message: 'Delete document "Old notes"?',
      reason: "Document disappeared before confirmation."
    }
    const input = { document_id: 99 }

    expect(deleteRepoDocumentToolCard.collapsedSummary?.(context("delete_repo_document", { input, parsedResult }))).toBe(
      'Delete Old notes · Delete document "Old notes"?'
    )
    render(<>{deleteRepoDocumentToolCard.renderExpanded(context("delete_repo_document", { input, parsedResult }))}</>)

    expect(screen.getByText("Delete document")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Old notes" })).toHaveAttribute("href", "/api/v1/app/repository_documents/99/file")
    expect(screen.getByText("Document disappeared before confirmation.")).toBeInTheDocument()
  })

  it("summarizes failed delete outcomes even when collapsed rendering lacks tool input", () => {
    const parsedResult = {
      pending_action_id: 502,
      state: "failed",
      message: 'Delete document "Old notes"?',
      reason: "Document disappeared before confirmation."
    }

    expect(deleteRepoDocumentToolCard.collapsedSummary?.(context("delete_repo_document", { parsedResult, resultError: true }))).toBe(
      'Delete repository document failed: Delete document "Old notes"?'
    )
  })

  it("renders document-not-found failures with recovery context", () => {
    const failed = context("delete_repo_document", {
      input: { document_id: 404 },
      parsedResult: { error: "Document not found" },
      resultBody: JSON.stringify({ error: "Document not found" }),
      resultError: true
    })

    render(<>{deleteRepoDocumentToolCard.renderExpanded(failed)}</>)

    expect(screen.getByText("Delete repository document failed")).toBeInTheDocument()
    expect(screen.getByText("Document not found")).toBeInTheDocument()
    expect(screen.getByText("Delete document 404")).toBeInTheDocument()
    expect(screen.getByText(/Check that the document still exists/)).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult: { oops: true } }))).toBeNull()
    expect(listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult: "not json" }))).toBeNull()
    expect(createRepoDocumentToolCard.renderExpanded(context("create_repo_document", { parsedResult: { oops: true } }))).toBeNull()
    expect(readRepoDocumentToolCard.renderExpanded(context("read_repo_document", { parsedResult: { oops: true }, resultBody: "" }))).toBeNull()
  })
})
