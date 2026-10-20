import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import publishMemoryToolCard from "./publish_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "publish_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 20,
  kind: "decision",
  scope: "repository",
  scope_id: 3,
  content: `Ship **weekly**. See JOB-42 and https://example.test/release. ${"More release context. ".repeat(30)}`,
  published: true,
  author: "operator@example.test",
  confidence: 0.9,
  expires_at: "2027-01-01T00:00:00Z",
  last_verified_at: "2026-08-31T00:00:00Z",
  created_at: "2026-08-30T00:00:00Z",
  updated_at: "2026-09-01T00:00:00Z"
}

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("publish_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(publishMemoryToolCard.toolName).toBe("publish_memory")
    expect(normalizedToolName("mcp__syrus__publish_memory")).toBe(publishMemoryToolCard.toolName)
  })

  it("summarizes the collapsed row as a publish confirmation", () => {
    expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Published memory #20")
  })

  it("renders the requested ID, state change, returned fields, and linked visibility", () => {
    setSlugReferenceRegistryForTests([
      {
        prefix: "JOB",
        type: "job",
        displayLabel: "Job",
        copyable: false,
        linkable: true,
        previewAvailable: false,
        linkifiesGeneratedText: true,
        hrefTemplate: "/jobs/:id",
        mobileInteractionHints: {},
        pluginPreviewComponent: null
      }
    ])
    render(
      <MemoryRouter>
        {publishMemoryToolCard.renderExpanded(
          context({ input: { memory_id: "19" }, parsedResult: { memory: { ...memory, secret_token: "must-not-render" } } })
        )}
      </MemoryRouter>
    )

    expect(screen.getByText("private")).toBeInTheDocument()
    expect(screen.getAllByText("published")).toHaveLength(2)
    expect(screen.getByLabelText("State changed from private to published")).toHaveTextContent("→")
    expect(screen.getByText("Requested memory")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-19/ })).toHaveAttribute("href", "/memories")
    expect(screen.getByRole("link", { name: /MEMORY-20/ })).toHaveAttribute("href", "/memories")
    expect(screen.getAllByRole("link", { name: /repository #3/i })).toHaveLength(2)
    expect(screen.getByText("operator@example.test")).toBeInTheDocument()
    expect(screen.getByText("0.9")).toBeInTheDocument()
    expect(screen.getByText("2027-01-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-31T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-30T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "https://example.test/release" })).toHaveAttribute("href", "https://example.test/release")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.queryByText("secret_token")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Memory content" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy memory content" })).toBeInTheDocument()
  })

  it("renders invalid-tool errors and pending and empty states", () => {
    const invalid = context({
      input: { memory_id: "20" },
      resultError: true,
      resultBody: "Error: global memories cannot be published"
    })
    expect(publishMemoryToolCard.collapsedSummary?.(invalid)).toBe("Memory publish failed: global memories cannot be published")
    const { rerender } = render(<>{publishMemoryToolCard.renderExpanded(invalid)}</>)
    expect(screen.getByRole("alert")).toHaveTextContent("Memory publish failed")
    expect(screen.getByRole("alert")).toHaveTextContent("global memories cannot be published")
    expect(screen.getByRole("link", { name: /MEMORY-20/ })).toHaveAttribute("href", "/memories")

    const pending = context({ input: { memory_id: "20" } })
    expect(publishMemoryToolCard.collapsedSummary?.(pending)).toBe("Publishing memory...")
    rerender(<>{publishMemoryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Publishing memory...")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /MEMORY-20/ })).toHaveAttribute("href", "/memories")

    rerender(<>{publishMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, content: "" } } }))}</>)
    expect(screen.getByText("No memory content returned.")).toBeInTheDocument()
  })

  it("accepts normalized provider-independent result envelopes", () => {
    const payload = { memory }
    for (const parsedResult of [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]) {
      const normalized = normalizedToolCardParsedResult(parsedResult)
      expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult: normalized }))).toBe("Published memory #20")
    }
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(publishMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(publishMemoryToolCard.collapsedSummary?.(context({ parsedResult: "not json" }))).toBeNull()
    expect(publishMemoryToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
