import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import createRepoDocumentToolCard from "./create_repo_document"
import deleteRepoDocumentToolCard from "./delete_repo_document"
import listRepoDocumentsToolCard from "./list_repo_documents"
import readRepoDocumentToolCard from "./read_repo_document"
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
      expect(createRepoDocumentToolCard.collapsedSummary?.(cardContext)).toBe("Create API Guide · Create **API Guide**?")
    }
  })

  it("renders an empty document list", () => {
    const parsedResult: unknown[] = []
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult }))).toBe("No repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult }))}</>)
    expect(screen.getByText("No repository documents found.")).toBeInTheDocument()
  })

  it("renders complete document metadata with viewer, repository, and source links", () => {
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult: documentRows }))).toBe("2 repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult: documentRows }))}</>)

    expect(screen.getByRole("link", { name: "API Guide" })).toHaveAttribute("href", "/api/v1/app/repository_documents/12/file")
    expect(screen.getByText("repo-doc-12")).toBeInTheDocument()
    expect(screen.getByText("file")).toBeInTheDocument()
    expect(screen.getByText("attached")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "tkadauke/syrus" })[0]).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByText("text/markdown")).toBeInTheDocument()
    expect(screen.getByText("2.0 KB")).toBeInTheDocument()
    expect(screen.getByText("google_doc")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Launch Notes" })).toHaveAttribute("href", "https://docs.google.com/document/d/abc/edit")
    expect(screen.getByRole("link", { name: "https://docs.google.com/document/d/abc/edit" })).toHaveAttribute(
      "href",
      "https://docs.google.com/document/d/abc/edit"
    )
  })

  it("normalizes root arrays and wrapped provider envelopes for document lists", () => {
    const rootArray = { content: [{ type: "text", text: JSON.stringify(documentRows) }], structured_content: null }
    const wrapped = { structured_content: { documents: documentRows }, content: [{ type: "text", text: "ignored" }] }

    for (const [rawName, envelope] of [
      ["mcp__syrus-chat-sidecar__list_repo_documents", rootArray],
      ["syrus-chat-deferred-sidecar.list_repo_documents", wrapped]
    ] as const) {
      const toolName = normalizedToolName(rawName)
      const cardContext = context(toolName, { parsedResult: normalizedToolCardParsedResult(envelope) })

      expect(toolName).toBe("list_repo_documents")
      expect(listRepoDocumentsToolCard.collapsedSummary?.(cardContext)).toBe("2 repository documents")
    }
  })

  it("falls back to the repository documents page when no document viewer can be derived", () => {
    const parsedResult = [{ id: 14, title: "Uncached notes", kind: "note", repository_id: 7, repository: "tkadauke/syrus" }]

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "Uncached notes" })).toHaveAttribute("href", "/repositories/7/documents")
  })

  it("renders list failures with recovery guidance", () => {
    const failed = context("list_repo_documents", {
      input: { repository_id: 7 },
      resultBody: "Repository is unavailable",
      resultError: true
    })

    expect(listRepoDocumentsToolCard.collapsedSummary?.(failed)).toBe("List repository documents failed: Repository is unavailable")
    render(<>{listRepoDocumentsToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("List repository documents failed")).toBeInTheDocument()
    expect(screen.getByText("Check repository access and retry the request.")).toBeInTheDocument()
  })

  it("renders a document detail/read card with a concise content preview", () => {
    const resultBody = "Overview\nKeep this short.\nUse read_repo_document for full text."

    expect(readRepoDocumentToolCard.collapsedSummary?.(context("read_repo_document", { input: { id: 12 }, resultBody }))).toBe("Document 12 read")
    render(<>{readRepoDocumentToolCard.renderExpanded(context("read_repo_document", { input: { id: 12 }, resultBody }))}</>)

    expect(screen.getByText("document 12")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("Content preview")).toBeInTheDocument()
    expect(screen.getByText(/Keep this short/)).toBeInTheDocument()
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
