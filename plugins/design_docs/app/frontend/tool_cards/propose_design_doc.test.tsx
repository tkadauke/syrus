import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import proposeDesignDocToolCard, { examples } from "./propose_design_doc"

beforeEach(() =>
  setSlugReferenceRegistryForTests([
    {
      prefix: "JOB",
      type: "job",
      displayLabel: "Job",
      copyable: true,
      linkable: true,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: "/jobs/:id",
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    }
  ])
)
afterEach(() => setSlugReferenceRegistryForTests(null))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "propose_design_doc", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const input = {
  title: "Proposal input title",
  markdown: `# Proposed body\n\nSee JOB-42 and https://example.test/details. ${"More context. ".repeat(100)}`,
  visibility: "public",
  repository_ids: [41, "42"],
  collaborator_user_ids: [7, "8"],
  change_summary: "Adds **placement** guidance."
}

const parsedResult = {
  design_doc: {
    id: 42,
    doc_ref: "DOC-42",
    title: "Created result title",
    visibility: "private",
    state: "draft",
    current_version_number: 3,
    markdown: `# Created body\n\nThe complete result for DOC-42. ${"Result details. ".repeat(100)}`,
    repositories: [{ id: 41, slug: "acme/widgets" }],
    collaborators: [{ id: 7, name: "Ada" }]
  },
  note: "For later changes, use **suggest_design_doc_change**."
}

function renderCard(cardContext: ToolCardContext) {
  return render(<MemoryRouter>{proposeDesignDocToolCard.renderExpanded(cardContext)}</MemoryRouter>)
}

describe("propose_design_doc tool card", () => {
  it("registers under the exact MCP tool name and provides catalog states", () => {
    expect(proposeDesignDocToolCard.toolName).toBe("propose_design_doc")
    expect(examples.map((example) => example.id)).toEqual(["created_design_doc", "permission_error", "pending"])
  })

  it("summarizes and renders every proposal input plus the created document metadata", () => {
    const cardContext = context({ input, parsedResult })
    expect(proposeDesignDocToolCard.collapsedSummary?.(cardContext)).toBe("Created DOC-42 — Created result title")
    renderCard(cardContext)

    expect(screen.getByText("Created")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "DOC-42" })).toHaveAttribute("href", "/design_docs/42")
    expect(screen.getByText("v3")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getByText("Created result title")).toBeInTheDocument()
    expect(screen.getByText("Proposed title")).toBeInTheDocument()
    expect(screen.getByText("Proposal input title")).toBeInTheDocument()
    expect(screen.getByText("public")).toBeInTheDocument()
    expect(screen.getByText("7, 8")).toBeInTheDocument()
    expect(screen.getByText("placement").tagName).toBe("STRONG")
    expect(screen.getByText("Ada")).toBeInTheDocument()

    for (const [label, href] of [
      ["Repository 41", "/repositories/41"],
      ["Repository 42", "/repositories/42"],
      ["acme/widgets", "/repositories/41"]
    ]) {
      expect(screen.getByRole("link", { name: label })).toHaveAttribute("href", href)
    }

    expect(screen.getAllByRole("button", { name: "Show more" }).length).toBeGreaterThanOrEqual(2)
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[0])
    const dialog = screen.getByRole("dialog", { name: "Proposed content" })
    expect(within(dialog).getByRole("heading", { name: "Proposed body" })).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(within(dialog).getByRole("link", { name: "https://example.test/details" })).toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: "Copy Proposed content to clipboard" })).toBeInTheDocument()
  })

  it("shows explicit empty states for blank optional and content fields", () => {
    renderCard(
      context({
        input: { ...input, markdown: " ", change_summary: "" },
        parsedResult: { ...parsedResult, design_doc: { ...parsedResult.design_doc, markdown: "" } }
      })
    )

    expect(screen.getByText("No change summary was provided.")).toBeInTheDocument()
    expect(screen.getByText("No proposed content was provided.")).toBeInTheDocument()
    expect(screen.getByText("The created design doc has no content.")).toBeInTheDocument()
  })

  it("renders pending and styled error states", () => {
    const pendingContext = context({ input })
    expect(proposeDesignDocToolCard.collapsedSummary?.(pendingContext)).toBe("Proposing design doc")
    const { rerender } = render(<MemoryRouter>{proposeDesignDocToolCard.renderExpanded(pendingContext)}</MemoryRouter>)
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("Proposal input title")).toBeInTheDocument()
    expect(screen.getByText("Proposed body")).toBeInTheDocument()
    expect(screen.getByText("public")).toBeInTheDocument()
    expect(screen.getByText("7, 8")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 41" })).toHaveAttribute("href", "/repositories/41")
    expect(screen.getByText("placement").tagName).toBe("STRONG")

    const errorContext = context({ input, resultBody: "Repository not attached to this chat context", resultError: true })
    expect(proposeDesignDocToolCard.collapsedSummary?.(errorContext)).toBe("Could not propose design doc")
    rerender(<MemoryRouter>{proposeDesignDocToolCard.renderExpanded(errorContext)}</MemoryRouter>)
    expect(screen.getByRole("alert")).toHaveTextContent("Repository not attached to this chat context")
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Proposal input title")).toBeInTheDocument()
    expect(screen.getByText("Proposed body")).toBeInTheDocument()
    expect(screen.getByText("public")).toBeInTheDocument()
    expect(screen.getByText("7, 8")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 42" })).toHaveAttribute("href", "/repositories/42")
    expect(screen.getByText("placement").tagName).toBe("STRONG")
  })

  it("accepts normalized structured-content and text MCP envelopes", () => {
    const structured = normalizedToolCardParsedResult({ structured_content: parsedResult })
    const textEnvelope = normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(parsedResult) }] })

    expect(proposeDesignDocToolCard.collapsedSummary?.(context({ parsedResult: structured }))).toBe("Created DOC-42 — Created result title")
    expect(proposeDesignDocToolCard.collapsedSummary?.(context({ parsedResult: textEnvelope }))).toBe("Created DOC-42 — Created result title")
  })

  it("falls back to the generic renderer for malformed payloads", () => {
    expect(proposeDesignDocToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(proposeDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
