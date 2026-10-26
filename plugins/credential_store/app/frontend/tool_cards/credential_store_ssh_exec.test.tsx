import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "@app/routes/chat/toolRendering"
import { redactToolCardText, redactToolCardValue } from "@app/toolCardSecurity"
import credentialStoreSshExecToolCard from "./credential_store_ssh_exec"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "credential_store_ssh_exec",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const success = {
  ok: true,
  status: 0,
  stdout: { text: Array.from({ length: 8 }, (_, index) => `line ${index + 1}`).join("\n"), truncated: true, bytes: 65_536, omitted_bytes: 4_096 },
  stderr: { text: "", truncated: false, bytes: 0 },
  target: { host: "app.example.test", user: "deploy", port: 2222 },
  credential: { credential_id: 17, credential_name: "production deploy", credential_type: "ssh_private_key" },
  known_hosts_enforced: true,
  fingerprint: "SHA256:trusted-host"
}

describe("credential_store_ssh_exec tool card", () => {
  it("registers for both sidecar raw-name variants", () => {
    for (const rawName of ["mcp__syrus-chat-sidecar__credential_store_ssh_exec", "mcp__syrus-chat-deferred-sidecar__credential_store_ssh_exec"]) {
      expect(normalizedToolName(rawName)).toBe("credential_store_ssh_exec")
      expect(pluginToolCardRendererFor(normalizedToolName(rawName))).toBe(credentialStoreSshExecToolCard)
    }
  })

  it("renders every input and result field with tail-aware output", () => {
    const cardContext = context({
      input: {
        credential: "production deploy",
        host: "app.example.test",
        user: "deploy",
        command: "tail -n 100 /var/log/app.log",
        port: 2222,
        connect_timeout: 15,
        allow_unconstrained_host: true,
        allow_risky_command: true
      },
      parsedResult: success
    })

    expect(credentialStoreSshExecToolCard.argumentSummary?.(cardContext.input)).toBe("")
    expect(credentialStoreSshExecToolCard.collapsedSummary?.(cardContext)).toBe("ssh deploy@app.example.test:2222: exit 0")
    render(<>{credentialStoreSshExecToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("deploy@app.example.test:2222")).toBeInTheDocument()
    expect(screen.getByText("production deploy")).toBeInTheDocument()
    expect(screen.getByText("17")).toBeInTheDocument()
    expect(screen.getByText("ssh_private_key")).toBeInTheDocument()
    expect(screen.getByText("tail -n 100 /var/log/app.log")).toBeInTheDocument()
    expect(screen.getByText("15 seconds")).toBeInTheDocument()
    expect(screen.getByText("Unconstrained host allowed")).toBeInTheDocument()
    expect(screen.getByText("Risky command allowed")).toBeInTheDocument()
    expect(screen.getByText("Yes")).toBeInTheDocument()
    expect(screen.getByText("SHA256:trusted-host")).toBeInTheDocument()
    expect(screen.getByText("Truncated · 64 KB total · 4.0 KB omitted")).toBeInTheDocument()
    const stdout = screen.getAllByTestId("text-preview-content")[0]
    expect(stdout).toHaveTextContent("… 2 earlier lines\nline 3", { normalizeWhitespace: false })
    expect(stdout).toHaveTextContent("line 8")
    expect(screen.getByText("No output.")).toBeInTheDocument()
  })

  it("auto-opens stderr for a nonzero result and keeps stdout collapsed when empty", () => {
    const failed = {
      ...success,
      ok: false,
      status: 23,
      stdout: { text: "", truncated: false, bytes: 0 },
      stderr: { text: "permission denied", truncated: false, bytes: 17 }
    }
    const cardContext = context({ input: { command: "cat /root/file" }, parsedResult: failed, resultError: true })

    expect(credentialStoreSshExecToolCard.collapsedSummary?.(cardContext)).toBe("ssh deploy@app.example.test:2222: exit 23")
    render(<>{credentialStoreSshExecToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("exit 23")).toBeInTheDocument()
    const stderr = screen.getByText("stderr").closest("details")
    const stdout = screen.getByText("stdout").closest("details")
    expect(stderr).toHaveAttribute("open")
    expect(stdout).not.toHaveAttribute("open")
    expect(within(stderr!).getByText("permission denied")).toBeInTheDocument()
  })

  it("normalizes structured_content and text-content result envelopes", () => {
    for (const envelope of [{ structured_content: success }, { content: [{ type: "text", text: JSON.stringify(success) }] }]) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(credentialStoreSshExecToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("ssh deploy@app.example.test:2222: exit 0")
      expect(credentialStoreSshExecToolCard.renderExpanded(context({ parsedResult }))).not.toBeNull()
    }
  })

  it("renders Error text and an empty error state", () => {
    const failed = context({ resultBody: "Error: SSH host-key enrollment is required", resultError: true })
    expect(credentialStoreSshExecToolCard.collapsedSummary?.(failed)).toBe("SSH command failed")
    const { rerender } = render(<>{credentialStoreSshExecToolCard.renderExpanded(failed)}</>)
    expect(screen.getByText("Error: SSH host-key enrollment is required")).toBeInTheDocument()

    rerender(<>{credentialStoreSshExecToolCard.renderExpanded(context({ resultError: true }))}</>)
    expect(screen.getByText("SSH execution failed without an error message.")).toBeInTheDocument()
  })

  it("redacts secrets from every rendered input and result surface", () => {
    const secret = "password=hunter2-secret"
    const raw = {
      ...success,
      stdout: { text: `output ${secret}`, truncated: false, bytes: 30 },
      stderr: { text: `stderr token=abcdefghijklmnop`, truncated: false, bytes: 30 },
      fingerprint: `SHA256:trusted ${secret}`
    }
    const cardContext = context({
      input: redactToolCardValue({ credential: "hunter2-secret", command: `echo ${secret}`, host: "app.example.test", user: "deploy" }) as Record<
        string,
        unknown
      >,
      parsedResult: redactToolCardValue(raw),
      resultBody: redactToolCardText(JSON.stringify(raw))
    })
    const { container } = render(<>{credentialStoreSshExecToolCard.renderExpanded(cardContext)}</>)

    expect(container).toHaveTextContent("[redacted]")
    expect(container).not.toHaveTextContent("hunter2-secret")
    expect(container).not.toHaveTextContent("abcdefghijklmnop")
  })

  it("falls back for malformed successful payloads", () => {
    expect(credentialStoreSshExecToolCard.renderExpanded(context({ parsedResult: { ok: true } }))).toBeNull()
    expect(credentialStoreSshExecToolCard.collapsedSummary?.(context({ parsedResult: { ok: true } }))).toBeNull()
  })
})
