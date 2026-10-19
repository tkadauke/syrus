import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { setSlugReferenceRegistryForTests } from "../../../lib/slugReferenceRegistry"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import listWakeupsToolCard from "./list_wakeups"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "list_wakeups", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const wakeup = {
  id: 7,
  chat_id: 42,
  fire_at: "2026-09-07T12:00:00Z",
  delay_remaining_minutes: 42,
  state: "pending",
  prompt: `Check JOB-322 **deployment status** at https://example.test/details. ${"More context. ".repeat(35)}`,
  prompt_preview: "Check JOB-322"
}

describe("list_wakeups tool card", () => {
  beforeEach(() => {
    vi.setSystemTime(new Date("2026-09-07T11:18:00Z"))
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
  })
  afterEach(() => setSlugReferenceRegistryForTests(null))

  it("registers under the normalized MCP tool name", () => {
    expect(listWakeupsToolCard.toolName).toBe(normalizedToolName("mcp__syrus-chat-sidecar__list_wakeups"))
    expect(normalizedToolName("syrus-chat-sidecar.list_wakeups")).toBe("list_wakeups")
  })

  it.each([
    ["plain", { wakeups: [wakeup] }],
    ["Claude MCP envelope", { content: [{ type: "text", text: JSON.stringify({ wakeups: [wakeup] }) }] }],
    ["Codex structured envelope", { structured_content: { wakeups: [wakeup] } }]
  ])("normalizes and summarizes the %s result shape", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(listWakeupsToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("1 wakeup")
  })

  it("renders a friendly empty state", () => {
    render(<>{listWakeupsToolCard.renderExpanded(context({ parsedResult: { wakeups: [] } }))}</>)
    expect(screen.getByText("No pending wakeups in this chat.")).toBeInTheDocument()
  })

  it("renders an error result instead of falling back to raw output", () => {
    const parsedResult = { error: "Wakeups are temporarily unavailable." }
    render(<>{listWakeupsToolCard.renderExpanded(context({ parsedResult, resultError: true }))}</>)
    expect(screen.getByText("Wakeups are temporarily unavailable.")).toBeInTheDocument()
  })

  it("renders linked references, status, local and relative time, and expandable markdown", () => {
    render(<MemoryRouter>{listWakeupsToolCard.renderExpanded(context({ parsedResult: { wakeups: [wakeup] } }))}</MemoryRouter>)

    expect(screen.getByRole("table")).toHaveClass("block", "md:table", "table-fixed")
    expect(screen.getByRole("link", { name: "WAKEUP-7" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByRole("link", { name: "CHAT-42" })).toHaveAttribute("href", "/chats/42")
    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("42 min")).toBeInTheDocument()
    const time = document.querySelector('time[datetime="2026-09-07T12:00:00Z"]')
    expect(time).toHaveTextContent("in 42 minutes")
    expect(time).not.toHaveTextContent("2026-09-07T12:00:00Z")
    expect(screen.getByRole("link", { name: "JOB-322" })).toHaveAttribute("href", "/jobs/322")
    expect(screen.getByRole("link", { name: /https:\/\/example.test/ })).toHaveAttribute("href", "https://example.test/details")

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(within(screen.getByRole("dialog", { name: "Wakeup 7 prompt" })).getByText(/More context/)).toBeInTheDocument()
  })

  it("uses the legacy prompt preview when a full prompt is absent", () => {
    render(
      <>{listWakeupsToolCard.renderExpanded(context({ parsedResult: { wakeups: [{ ...wakeup, prompt: undefined, prompt_preview: "Legacy **prompt**" }] } }))}</>
    )
    expect(screen.getByText("prompt").tagName).toBe("STRONG")
  })

  it("falls back to null for malformed payloads", () => {
    expect(listWakeupsToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listWakeupsToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
