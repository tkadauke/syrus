import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "@app/toolCardSecurity"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import deChat from "@app/i18n/locales/de/chat.json"
import enChat from "@app/i18n/locales/en/chat.json"
import laChat from "@app/i18n/locales/la/chat.json"
import daemonInvocationContextToolCard from "./daemon_invocation_context"

function context(parsedResult: unknown, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "daemon_invocation_context",
    resultBody: "",
    resultError: false,
    parsedResult,
    ...overrides
  }
}

const SUCCESS = {
  ok: true,
  surface: "chat",
  role: "assistant",
  run_id: 221762,
  job_id: 7696,
  chat_session_id: 605,
  current_message_id: 991,
  tier: "admin",
  provider: "codex"
}

describe("daemon_invocation_context tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(daemonInvocationContextToolCard.toolName).toBe("daemon_invocation_context")
  })

  it.each(["mcp__syrus-chat-sidecar__daemon_invocation_context", "syrus-chat-deferred-sidecar.daemon_invocation_context"])(
    "normalizes %s for the same renderer",
    (rawName) => {
      expect(normalizedToolName(rawName)).toBe(daemonInvocationContextToolCard.toolName)
    }
  )

  it("summarizes and renders every success field with links and copy controls", () => {
    expect(daemonInvocationContextToolCard.collapsedSummary?.(context(SUCCESS))).toBe("invocation context: chat 605")
    render(<>{daemonInvocationContextToolCard.renderExpanded(context(SUCCESS))}</>)

    expect(screen.getByText("OK")).toBeInTheDocument()
    for (const value of ["chat", "assistant", "admin", "codex"]) expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7696" })).toHaveAttribute("href", "/jobs/7696")
    expect(screen.getByRole("link", { name: "CHAT-605" })).toHaveAttribute("href", "/chats/605")
    expect(screen.getByRole("button", { name: "Copy 221762 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy 991 to clipboard" })).toBeInTheDocument()
  })

  it.each([
    ["structured_content", { structured_content: SUCCESS }],
    ["content text", { content: [{ type: "text", text: JSON.stringify(SUCCESS) }] }]
  ])("renders the normalized %s MCP result", (_label, envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{daemonInvocationContextToolCard.renderExpanded(context(parsedResult))}</>)
    expect(screen.getByRole("link", { name: "CHAT-605" })).toBeInTheDocument()
  })

  it("renders structured denials even when the MCP result is marked as an error", () => {
    const denied = { ok: false, error: "forbidden", message: "Invocation context is unavailable for this role." }
    expect(daemonInvocationContextToolCard.collapsedSummary?.(context(denied, { resultError: true }))).toBe("invocation context denied: forbidden")
    render(<>{daemonInvocationContextToolCard.renderExpanded(context(denied, { resultError: true }))}</>)
    expect(screen.getByText("Denied")).toBeInTheDocument()
    expect(screen.getByText("forbidden")).toBeInTheDocument()
    expect(screen.getByText("Invocation context is unavailable for this role.")).toBeInTheDocument()
  })

  it("only receives redacted values from the shared tool-card boundary", () => {
    const payload = { ...SUCCESS, provider: "password=super-secret-value" }
    const redacted = redactToolCardValue(payload)
    render(<>{daemonInvocationContextToolCard.renderExpanded(context(redacted))}</>)
    expect(screen.getByText("password=[redacted]")).toBeInTheDocument()
    expect(screen.queryByText(/super-secret-value/)).not.toBeInTheDocument()
  })

  it("falls back for malformed payloads", () => {
    expect(daemonInvocationContextToolCard.collapsedSummary?.(context({ ok: true }))).toBeNull()
    expect(daemonInvocationContextToolCard.renderExpanded(context("not json"))).toBeNull()
  })

  it("defines every card label in each supported locale", () => {
    const keys = Object.keys(enChat.daemon_invocation_context).sort()
    expect(Object.keys(deChat.daemon_invocation_context).sort()).toEqual(keys)
    expect(Object.keys(laChat.daemon_invocation_context).sort()).toEqual(keys)
  })
})
