import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import readMemoryToolCard, { examples } from "./read_memory"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_memory",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const memory = {
  id: 12,
  kind: "project_fact",
  scope: "repository",
  scope_id: 9,
  content: "Deploys SIGKILL in-flight Runs.",
  published: true,
  user_id: 27,
  source_type: "job",
  source_id: 314,
  author: "agent",
  confidence: 0.9,
  visibility: "repository",
  expires_at: "2027-08-31T10:15:00Z",
  last_verified_at: "2026-08-30T10:15:00Z",
  created_at: "2026-08-29T10:15:00Z",
  updated_at: "2026-08-31T10:15:00Z"
}

describe("read_memory tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readMemoryToolCard.toolName).toBe("read_memory")
  })

  it("summarizes the collapsed row with id and kind", () => {
    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult: { memory } }))).toBe("Memory #12 (project_fact)")
  })

  it("renders every returned field and links memory, repository, slugs, and URLs", () => {
    const richMemory = { ...memory, content: "See **runbook** JOB-42 and https://example.com/runbook." }
    render(<>{readMemoryToolCard.renderExpanded(context({ input: { id: 12 }, parsedResult: { memory: richMemory } }))}</>)

    expect(screen.getByText("project fact")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "repository #9" })).toHaveAttribute("href", "/repositories/9")
    expect(screen.getByRole("link", { name: "MEMORY-12" })).toHaveAttribute("href", "/memories")
    expect(screen.getByText("published")).toBeInTheDocument()
    expect(screen.getByText("User ID")).toBeInTheDocument()
    expect(screen.getByText("27")).toBeInTheDocument()
    expect(screen.getByText("Source type")).toBeInTheDocument()
    expect(screen.getByText("job")).toBeInTheDocument()
    expect(screen.getByText("Source ID")).toBeInTheDocument()
    expect(screen.getByText("314")).toBeInTheDocument()
    expect(screen.getByText("agent")).toBeInTheDocument()
    expect(screen.getByText("0.9")).toBeInTheDocument()
    expect(screen.getByText("Visibility")).toBeInTheDocument()
    expect(screen.getByText("repository", { selector: "div[title]" })).toBeInTheDocument()
    expect(screen.getByText("2027-08-31T10:15:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-30T10:15:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-29T10:15:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-08-31T10:15:00Z")).toBeInTheDocument()
    expect(screen.getByText("runbook").tagName).toBe("STRONG")
    expect(screen.getByText(/JOB-42/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "https://example.com/runbook" })).toHaveAttribute("href", "https://example.com/runbook")
  })

  it("shows a deleted pill and deletion timestamp for a soft-deleted memory", () => {
    render(
      <>{readMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, deleted_at: "2026-09-01T00:00:00Z", deleted_by_user_id: 81 } } }))}</>
    )

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("2026-09-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("Deleted by user ID")).toBeInTheDocument()
    expect(screen.getByText("81")).toBeInTheDocument()
  })

  it("shows the requested id and styled error for an inaccessible memory", () => {
    const toolContext = context({
      input: { id: 404 },
      resultBody: "Error: memory not found or not accessible: 404",
      resultError: true,
      parsedResult: "Error: memory not found or not accessible: 404"
    })

    expect(readMemoryToolCard.collapsedSummary?.(toolContext)).toBe("Could not read memory #404")
    render(<>{readMemoryToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByRole("link", { name: "MEMORY-404" })).toHaveAttribute("href", "/memories")
    const alert = screen.getByRole("alert")
    expect(within(alert).getByText("Memory could not be read")).toBeInTheDocument()
    expect(within(alert).getByText("memory not found or not accessible: 404")).toBeInTheDocument()
  })

  it("renders pending and empty states", () => {
    const pending = context({ input: { id: 12 } })
    expect(readMemoryToolCard.collapsedSummary?.(pending)).toBe("Reading memory #12...")
    const { rerender } = render(<>{readMemoryToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Reading memory #12...")).toBeInTheDocument()

    rerender(<>{readMemoryToolCard.renderExpanded(context({ input: { id: 12 }, resultBody: '{"memory":null}', parsedResult: { memory: null } }))}</>)
    expect(screen.getByText("No memory was returned.")).toBeInTheDocument()
  })

  it("uses MarkdownPreview's blank state and copyable Show more modal", () => {
    const longContent = Array.from({ length: 12 }, (_, index) => `Section ${index}: details`).join("\n\n")
    const { rerender } = render(<>{readMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, content: "  " } } }))}</>)
    expect(screen.getByText("No memory content returned.")).toBeInTheDocument()

    rerender(<>{readMemoryToolCard.renderExpanded(context({ parsedResult: { memory: { ...memory, content: longContent } } }))}</>)
    fireEvent.click(screen.getByText("Show more"))
    expect(screen.getByRole("dialog")).toHaveTextContent("Section 11: details")
    expect(screen.getByLabelText("Copy memory content")).toBeInTheDocument()
  })

  it("normalizes prefixed tool names and provider-specific result envelopes", () => {
    const envelopes = [{ content: [{ type: "text", text: JSON.stringify({ memory }) }] }, { structured_content: { memory } }]

    for (const [index, envelope] of envelopes.entries()) {
      const toolContext = context({
        toolName: normalizedToolName(index === 0 ? "mcp__syrus__read_memory" : "syrus-chat-sidecar.read_memory"),
        parsedResult: normalizedToolCardParsedResult(envelope)
      })
      expect(toolContext.toolName).toBe("read_memory")
      expect(readMemoryToolCard.collapsedSummary?.(toolContext)).toBe("Memory #12 (project_fact)")
    }
  })

  it("keeps sensitive values redacted at the shared card boundary", () => {
    const redacted = redactToolCardValue({ memory: { ...memory, author: "token=secret-value", content: "password=hunter2" } })
    render(<>{readMemoryToolCard.renderExpanded(context({ parsedResult: redacted }))}</>)

    expect(screen.getByText("token=[redacted]")).toBeInTheDocument()
    expect(screen.getByText("password=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/hunter2|secret-value/)).not.toBeInTheDocument()
  })

  it("exports reviewable success, deleted, error, and pending examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["repository_memory", "deleted_memory", "not_found", "pending"])
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(readMemoryToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(readMemoryToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
