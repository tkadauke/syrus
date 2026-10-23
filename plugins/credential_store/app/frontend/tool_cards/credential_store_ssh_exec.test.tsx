import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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

describe("credential_store_ssh_exec tool card", () => {
  it("summarizes and renders SSH output with its tail visible", () => {
    const stdout = Array.from({ length: 8 }, (_, index) => `line ${index + 1}`).join("\n")
    const cardContext = context({
      input: { command: "tail app.log" },
      parsedResult: {
        ok: true,
        status: 0,
        stdout: { text: stdout, truncated: false },
        stderr: { text: "", truncated: false },
        target: { host: "app.example.test", user: "deploy", port: 2222 }
      }
    })

    expect(credentialStoreSshExecToolCard.collapsedSummary?.(cardContext)).toBe("SSH command succeeded (exit 0)")
    render(<>{credentialStoreSshExecToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("deploy@app.example.test:2222")).toBeInTheDocument()
    expect(screen.getByText("tail app.log")).toBeInTheDocument()
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("… 2 earlier lines\nline 3", { normalizeWhitespace: false })
    expect(screen.getByTestId("text-preview-content")).toHaveTextContent("line 8")
  })

  it("falls back for malformed and tool-error payloads", () => {
    expect(credentialStoreSshExecToolCard.renderExpanded(context({ parsedResult: { ok: true } }))).toBeNull()
    expect(credentialStoreSshExecToolCard.collapsedSummary?.(context({ resultError: true, parsedResult: { ok: false, status: 1 } }))).toBeNull()
  })
})
