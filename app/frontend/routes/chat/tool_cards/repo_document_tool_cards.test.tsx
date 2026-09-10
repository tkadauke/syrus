import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import createRepoDocumentToolCard from "./create_repo_document"
import deleteRepoDocumentToolCard from "./delete_repo_document"
import listRepoDocumentsToolCard from "./list_repo_documents"
import readRepoDocumentToolCard from "./read_repo_document"

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
    status: "current",
    repository: "tkadauke/syrus",
    content_type: "text/markdown",
    size_bytes: 2048
  },
  {
    id: 13,
    kind: "google_doc",
    title: "Launch Notes",
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

  it("renders an empty document list", () => {
    const parsedResult: unknown[] = []
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult }))).toBe("No repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult }))}</>)
    expect(screen.getByText("No repository documents found.")).toBeInTheDocument()
  })

  it("renders document list metadata without dumping raw details", () => {
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult: documentRows }))).toBe("2 repository documents")

    render(<>{listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult: documentRows }))}</>)

    expect(screen.getByText("API Guide")).toBeInTheDocument()
    expect(screen.getByText("repo-doc-12")).toBeInTheDocument()
    expect(screen.getByText("file")).toBeInTheDocument()
    expect(screen.getByText("current")).toBeInTheDocument()
    expect(screen.getAllByText("tkadauke/syrus")).toHaveLength(2)
    expect(screen.getByText("text/markdown · 2.0 KB")).toBeInTheDocument()
    expect(screen.getByText("google_doc")).toBeInTheDocument()
    expect(screen.getByText("linked")).toBeInTheDocument()
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
      message: "Create document \"API Guide\" in repository 7?"
    }
    const input = { repository_id: 7, title: "API Guide", body: "Line one\nLine two" }

    expect(createRepoDocumentToolCard.collapsedSummary?.(context("create_repo_document", { input, parsedResult }))).toBe(
      "Create API Guide · Create document \"API Guide\" in repository 7?"
    )
    render(<>{createRepoDocumentToolCard.renderExpanded(context("create_repo_document", { input, parsedResult }))}</>)

    expect(screen.getByText("Create document")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("API Guide")).toBeInTheDocument()
    expect(screen.getByText("7")).toBeInTheDocument()
    expect(screen.getByText("Body preview")).toBeInTheDocument()
  })

  it("renders a delete document pending outcome with confirmation/error state", () => {
    const parsedResult = {
      pending_action_id: 502,
      state: "failed",
      message: "Delete document \"Old notes\"?",
      reason: "Document disappeared before confirmation."
    }
    const input = { document_id: 99 }

    expect(deleteRepoDocumentToolCard.collapsedSummary?.(context("delete_repo_document", { input, parsedResult }))).toBe(
      "Delete document 99 · Delete document \"Old notes\"?"
    )
    render(<>{deleteRepoDocumentToolCard.renderExpanded(context("delete_repo_document", { input, parsedResult }))}</>)

    expect(screen.getByText("Delete document")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("99")).toBeInTheDocument()
    expect(screen.getByText("Document disappeared before confirmation.")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(listRepoDocumentsToolCard.collapsedSummary?.(context("list_repo_documents", { parsedResult: { oops: true } }))).toBeNull()
    expect(listRepoDocumentsToolCard.renderExpanded(context("list_repo_documents", { parsedResult: "not json" }))).toBeNull()
    expect(createRepoDocumentToolCard.renderExpanded(context("create_repo_document", { parsedResult: { oops: true } }))).toBeNull()
    expect(readRepoDocumentToolCard.renderExpanded(context("read_repo_document", { parsedResult: { oops: true }, resultBody: "" }))).toBeNull()
  })
})
