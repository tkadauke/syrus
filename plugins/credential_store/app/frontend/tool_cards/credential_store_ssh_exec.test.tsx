import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import card from "./credential_store_ssh_exec"

const result = {
  ok: true,
  status: 0,
  stdout: { text: "first\nlast", truncated: true, bytes: 65536, omitted_bytes: 2048 },
  stderr: { text: "", truncated: false, bytes: 0 },
  target: { host: "app.example.com", user: "deploy", port: 2222 },
  credential: { credential_id: 42, credential_name: "production-deploy", credential_type: "ssh_private_key", lease_id: "lease-1" },
  known_hosts_enforced: true,
  fingerprint: "SHA256:public-fingerprint"
}

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "credential_store_ssh_exec",
    input: { credential: "production-deploy", host: "app.example.com", user: "deploy", command: "systemctl status syrus", port: 2222, connect_timeout: 12 },
    resultBody: JSON.stringify(result),
    resultError: false,
    parsedResult: result,
    ...overrides
  }
}

describe("credential_store_ssh_exec tool card", () => {
  it("is discovered and normalizes both sidecar raw names", () => {
    expect(pluginToolCardRendererFor("credential_store_ssh_exec")).not.toBeNull()
    expect(normalizedToolName("mcp__syrus-chat-sidecar__credential_store_ssh_exec")).toBe("credential_store_ssh_exec")
    expect(normalizedToolName("mcp__syrus-chat-deferred-sidecar__credential_store_ssh_exec")).toBe("credential_store_ssh_exec")
  })

  it("renders success, metadata, risks, copy controls, and truncation", () => {
    expect(card.collapsedSummary?.(context())).toBe("ssh deploy@app.example.com:2222: exit 0")
    render(<>{card.renderExpanded(context({ input: { ...context().input, allow_unconstrained_host: true, allow_risky_command: true } }))}</>)
    for (const text of [
      "deploy@app.example.com:2222",
      "production-deploy",
      "42",
      "ssh_private_key",
      "systemctl status syrus",
      "unconstrained host",
      "risky command",
      "Enforced",
      "65536 bytes · 2048 omitted"
    ])
      expect(screen.getByText(text)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy command" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy fingerprint" })).toBeInTheDocument()
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("first\nlast", { normalizeWhitespace: false })
    expect(screen.getByText("Credential name").parentElement?.parentElement).toHaveClass("sm:grid-cols-3")
  })

  it("auto-opens stderr for a nonzero exit and renders empty stdout", () => {
    const failed = {
      ...result,
      ok: false,
      status: 17,
      stdout: { text: "", truncated: false, bytes: 0 },
      stderr: { text: "permission denied", truncated: false, bytes: 17 }
    }
    render(<>{card.renderExpanded(context({ parsedResult: failed }))}</>)
    expect(card.collapsedSummary?.(context({ parsedResult: failed }))).toBe("ssh deploy@app.example.com:2222: exit 17")
    expect(screen.getByText("No stdout output.")).toBeInTheDocument()
    expect(screen.getByText("permission denied")).toBeInTheDocument()
    expect(screen.getByText("stderr").closest("details")).toHaveProperty("open", true)
  })

  it("accepts structured_content and JSON text content envelopes", () => {
    const structured = { structured_content: result, content: [] }
    const text = { structured_content: null, content: [{ type: "text", text: JSON.stringify(result) }] }
    expect(card.collapsedSummary?.(context({ parsedResult: structured }))).toBe("ssh deploy@app.example.com:2222: exit 0")
    expect(card.collapsedSummary?.(context({ parsedResult: text }))).toBe("ssh deploy@app.example.com:2222: exit 0")
    expect(normalizedToolCardParsedResult(text)).toEqual(result)
  })

  it("renders plain Error text and empty result states", () => {
    const error = context({ resultBody: "Error: host key enrollment required", resultError: true, parsedResult: null })
    expect(card.collapsedSummary?.(error)).toBe("ssh deploy@app.example.com:2222: error")
    render(<>{card.renderExpanded(error)}</>)
    expect(screen.getByText("Error: host key enrollment required")).toBeInTheDocument()
    expect(screen.getByText("No stdout output.")).toBeInTheDocument()
    expect(screen.getByText("No stderr output.")).toBeInTheDocument()
  })

  it("redacts secrets from every visible field", () => {
    const secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
    const secretResult = {
      ...result,
      stdout: { text: `token=${secret}` },
      stderr: { text: `Bearer ${secret}` },
      fingerprint: `password=${secret}`,
      target: { host: `host-${secret}.example.com`, user: "deploy", port: 22 },
      credential: { credential_id: 42, credential_name: `name-${secret}`, credential_type: "ssh_private_key" }
    }
    const { container } = render(<>{card.renderExpanded(context({ input: { ...context().input, command: `echo ${secret}` }, parsedResult: secretResult }))}</>)
    expect(container).not.toHaveTextContent(secret)
    expect(container).toHaveTextContent("[redacted]")
  })
})
