import { render, screen, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolName } from "../toolRendering"
import clearProviderCircuitToolCard from "./clear_provider_circuit"

const INPUT = {
  provider: "codex",
  mode: "shorten",
  user_id: 7,
  user_ids: [7, 12],
  positive_evidence: "A **successful probe** completed for JOB-42.",
  retry_after: "2026-10-21T15:30:00Z",
  reason: "Restore access after reviewing [provider status](https://status.openai.com/)."
}

const RESULT = {
  pending_action_group_id: 91,
  pending_action_id: 507,
  pending_confirmation_id: 507,
  state: "pending",
  member_count: 2,
  message: "Shorten the circuit for user #7 and user #12?",
  reason: "Recovery is supported by **new positive evidence**."
}

function context(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "clear_provider_circuit",
    input: INPUT,
    resultBody: "",
    resultError: false,
    parsedResult,
    ...overrides
  }
}

describe("clear_provider_circuit tool card", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-10-22T15:30:00Z"))
  })
  afterEach(() => vi.useRealTimers())

  it("uses the normalized sidecar tool name", () => {
    expect(normalizedToolName("mcp__syrus-chat-sidecar__clear_provider_circuit")).toBe(clearProviderCircuitToolCard.toolName)
  })

  it("renders every input and result field with semantic links, Markdown, and readable timing", () => {
    render(<>{clearProviderCircuitToolCard.renderExpanded(context(RESULT))}</>)

    expect(screen.getByText("Pending action group #91")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByText("shorten")).toBeInTheDocument()
    screen.getAllByRole("link", { name: "7" }).forEach((link) => expect(link).toHaveAttribute("href", "/admin/users/7"))
    expect(screen.getByRole("link", { name: "12" })).toHaveAttribute("href", "/admin/users/12")
    expect(screen.getByText("2026-10-21T15:30:00Z (yesterday)")).toBeInTheDocument()
    expect(screen.getByText("successful probe", { exact: false })).toBeInTheDocument()
    expect(screen.getByText("JOB-42", { exact: false })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "provider status" })).toHaveAttribute("href", "https://status.openai.com/")
    expect(screen.getByText("Recovery is supported by", { exact: false })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "user #12" })).toHaveAttribute("href", "/admin/users/12")
  })

  it.each([
    ["direct", RESULT],
    ["structured_content", { structured_content: RESULT }],
    ["content text", { content: [{ type: "text", text: JSON.stringify(RESULT) }] }]
  ])("renders the normalized %s result envelope", (_label, parsedResult) => {
    render(<>{clearProviderCircuitToolCard.renderExpanded(context(parsedResult))}</>)
    expect(screen.getByText("Pending action group #91")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
  })

  it.each(["pending", "confirmed", "rejected"])("renders the %s action state", (state) => {
    render(<>{clearProviderCircuitToolCard.renderExpanded(context({ ...RESULT, state }))}</>)
    expect(screen.getByText(state)).toBeInTheDocument()
  })

  it("renders the structured quota-evidence refusal as a readable error", () => {
    const refusal = "Cannot clear this provider circuit: structured quota evidence remains unrepaired. Repair the evidence before retrying."
    const parsedResult = { content: [{ type: "text", text: JSON.stringify({ error: refusal }) }] }

    render(<>{clearProviderCircuitToolCard.renderExpanded(context(parsedResult, { resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText(refusal)).toBeInTheDocument()
  })

  it("renders only values preserved by the shared redaction boundary", () => {
    const redacted = redactToolCardValue({
      ...RESULT,
      message: "Shorten after token=super-secret-value is removed.",
      reason: "Verified with api_key=another-secret-value."
    })

    render(<>{clearProviderCircuitToolCard.renderExpanded(context(redacted))}</>)
    const card = screen.getByText("Pending action group #91").closest("div")?.parentElement
    expect(card).not.toBeNull()
    expect(within(card as HTMLElement).getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(within(card as HTMLElement).queryByText(/super-secret-value|another-secret-value/)).not.toBeInTheDocument()
  })
})
