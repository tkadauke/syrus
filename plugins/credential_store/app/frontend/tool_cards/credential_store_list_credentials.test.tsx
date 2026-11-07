import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { redactToolCardValue } from "@app/toolCardSecurity"
import toolCard, { examples } from "./credential_store_list_credentials"

describe("credential_store_list_credentials tool card", () => {
  it("registers a read-only, single-value collapsed summary", () => {
    expect(toolCard.toolName).toBe("credential_store_list_credentials")
    expect(toolCard.readOnly).toBe(true)
    expect(
      toolCard.collapsedSummary?.({
        toolName: toolCard.toolName,
        resultBody: "",
        resultError: false,
        parsedResult: { credentials: [{ id: 1 }, { id: 2 }] }
      })
    ).toBe("2")
  })

  it("provides a catalog fixture with multiple scopes and long metadata", () => {
    expect(examples).toHaveLength(1)
    expect(examples[0]).toMatchObject({
      id: "multiple_scopes_with_long_metadata",
      parsedResult: {
        count: 3,
        credentials: [
          { scope: "repository", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) },
          { scope: "team", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) },
          { scope: "instance", safe_metadata: expect.any(Object), target_constraints: expect.any(Object) }
        ]
      }
    })
  })

  it("renders safe credential and tool identifiers without exposing secret assignments", () => {
    const parsedResult = redactToolCardValue({
      credentials: [
        {
          credential_type: "credential_store.url_token",
          allowed_tools: ["credential_store_ssh_exec"],
          safe_metadata: { host: "example.test", note: "password=hunter2-secret" }
        }
      ]
    })

    render(
      <>
        {toolCard.renderExpanded({
          toolName: toolCard.toolName,
          resultBody: "",
          resultError: false,
          parsedResult
        })}
      </>
    )

    expect(screen.getByText(/credential_store\.url_token/)).toBeInTheDocument()
    expect(screen.getByText(/credential_store_ssh_exec/)).toBeInTheDocument()
    expect(screen.queryByText(/hunter2-secret/)).not.toBeInTheDocument()
    expect(screen.getByText(/password=\[redacted\]/)).toBeInTheDocument()
  })
})
