import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ToolApprovalDetails } from "./ToolApprovalDetails"

describe("ToolApprovalDetails", () => {
  it("shows the coworker, real tool, and readable message arguments", () => {
    render(
      <ToolApprovalDetails
        actor={{ name: "Dinesh", handle: "dinesh", avatar_key: "comet" }}
        args={{ recipient: "gilfoyle", message: "Please inspect the trace." }}
        toolName="message_coworker"
      />
    )

    expect(screen.getByText("Dinesh")).toBeInTheDocument()
    expect(screen.getByText("@dinesh")).toBeInTheDocument()
    expect(screen.getByText("Message coworker")).toBeInTheDocument()
    expect(screen.getByText("Please inspect the trace.")).toBeInTheDocument()
  })

  it("truncates a long SQL statement and expands it on request", () => {
    const sql = `SELECT * FROM audit_events WHERE detail = '${"diagnostic ".repeat(40)}'`
    render(<ToolApprovalDetails args={{ sql }} toolName="execute_query" />)

    expect(screen.queryByText(sql)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByText(sql)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show less" })).toBeInTheDocument()
  })

  it("handles missing arguments", () => {
    render(<ToolApprovalDetails toolName="ask_user_question" />)

    expect(screen.getByText("Ask user question")).toBeInTheDocument()
    expect(screen.getByText("No arguments provided.")).toBeInTheDocument()
  })

  it("redacts secrets recursively before rendering", () => {
    render(
      <ToolApprovalDetails
        args={{ question: "Proceed?", api_token: "secret-token-value", nested: { password: "hunter2-secret" } }}
        toolName="ask_user_question"
      />
    )

    expect(screen.getAllByText(/\[redacted\]/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/secret-token-value|hunter2-secret/)).not.toBeInTheDocument()
  })
})
