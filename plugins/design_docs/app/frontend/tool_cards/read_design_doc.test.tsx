import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests, type SlugReferenceRegistryEntry } from "@app/lib/slugReferenceRegistry"
import readDesignDocToolCard from "./read_design_doc"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "read_design_doc", resultBody: "result", resultError: false, parsedResult: null, ...overrides }
}

const designDoc = {
  doc_ref: "DOC-20",
  title: "Target Graphs for Project-Aware Workflows",
  visibility: "public",
  state: "draft",
  current_version_number: 4,
  pending_suggestions_count: 1,
  open_threads_count: 1,
  updated_at: "2026-10-19T10:00:00Z",
  repository_ids: [7],
  collaborators: [{ id: 2, name: "Ada Lovelace" }],
  permissions: { can_suggest: true, can_archive: false },
  markdown: `# Direction\nSee JOB-42, EPIC-7, and https://example.test. ${"Details ".repeat(400)}`,
  threads: [
    {
      id: 9,
      state: "open",
      opened_by: { name: "Grace" },
      anchor: { selected_markdown: "## JOB-55 anchor" },
      comments: [{ id: 10, author: { name: "Lin" }, body: "Consider **EPIC-8**." }]
    }
  ],
  suggestions: [
    { id: 11, state: "pending", suggested_by: { name: "Ken" }, anchor: { selected_text: "Direction" }, proposed_markdown: "Use **JOB-99** instead." }
  ]
}

function renderCard(value: React.ReactNode) {
  return render(<MemoryRouter>{value}</MemoryRouter>)
}

describe("read_design_doc tool card", () => {
  beforeEach(() => {
    const entry = (prefix: string, type: "job" | "epic"): SlugReferenceRegistryEntry => ({
      prefix,
      type,
      displayLabel: type,
      copyable: true,
      linkable: true,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: `/${type}s/:id`,
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    })
    setSlugReferenceRegistryForTests([entry("JOB", "job"), entry("EPIC", "epic")])
  })

  it("renders all full-detail metadata, linked entities, markdown, threads, and suggestions", () => {
    renderCard(readDesignDocToolCard.renderExpanded(context({ input: { detail: "full" }, parsedResult: { design_doc: designDoc, read_only: true } })))

    expect(screen.getByRole("link", { name: "DOC-20" })).toHaveAttribute("href", "/design_docs/20")
    expect(screen.getByRole("link", { name: "Repository 7" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByText("v4")).toBeInTheDocument()
    expect(screen.getByText("Read only")).toBeInTheDocument()
    expect(screen.getByText("Ada Lovelace")).toBeInTheDocument()
    expect(screen.getByText("suggest: yes")).toBeInTheDocument()
    expect(screen.getByText("archive: no")).toBeInTheDocument()
    expect(screen.getByText("Thread 9")).toBeInTheDocument()
    expect(screen.getByText("Grace")).toBeInTheDocument()
    expect(screen.getByText("Suggestion 11")).toBeInTheDocument()
    expect(screen.getByText("Ken")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "JOB-42" })[0]).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.test" })).toHaveAttribute("href", "https://example.test")
    fireEvent.click(screen.getAllByRole("button", { name: "Show more" })[0])
    expect(within(screen.getByRole("dialog", { name: "Content" })).getByRole("heading", { name: "Direction" })).toBeInTheDocument()
  })

  it("identifies summary mode without claiming content is missing", () => {
    renderCard(
      readDesignDocToolCard.renderExpanded(
        context({
          input: { detail: "summary" },
          parsedResult: { result: { design_doc: { ...designDoc, markdown: undefined, threads: undefined, suggestions: undefined } } }
        })
      )
    )
    expect(screen.getByText("summary detail")).toBeInTheDocument()
    expect(screen.getByText(/metadata only/)).toBeInTheDocument()
    expect(screen.queryByText("This design doc is blank.")).not.toBeInTheDocument()
    expect(screen.queryByText("Threads")).not.toBeInTheDocument()
  })

  it("renders an explicit blank-content state in full mode", () => {
    renderCard(
      readDesignDocToolCard.renderExpanded(context({ parsedResult: { data: { design_doc: { ...designDoc, markdown: "", threads: [], suggestions: [] } } } }))
    )
    expect(screen.getByText("This design doc is blank.")).toBeInTheDocument()
    expect(screen.getByText("No threads.")).toBeInTheDocument()
    expect(screen.getByText("No suggestions.")).toBeInTheDocument()
  })

  it("renders errors and pending calls", () => {
    renderCard(readDesignDocToolCard.renderExpanded(context({ resultBody: "not found", resultError: true })))
    expect(screen.getByRole("alert")).toHaveTextContent("not found")
    expect(readDesignDocToolCard.collapsedSummary?.(context({ resultBody: "not found", resultError: true }))).toBe("Could not read design doc")
    expect(readDesignDocToolCard.collapsedSummary?.(context({ resultBody: "", parsedResult: null }))).toBe("Reading design doc")
  })

  it("returns null for malformed provider envelopes", () => {
    expect(readDesignDocToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readDesignDocToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
