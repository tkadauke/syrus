import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { hasDetailValue, PermissionDecisionSummary, permissionActionPhrase } from "./PermissionDecisionSummary"

describe("PermissionDecisionSummary", () => {
  it("leads with the question, then the decision-critical facts", () => {
    render(
      <PermissionDecisionSummary
        fallbackStatement="fallback"
        presentation={{
          statement: "Allow Syrus to capture a screenshot?",
          agent: "Syrus",
          origin: "Chat",
          scope: "The browser tab",
          consequences: ["read what is on screen"],
          requested_durations: ["This one time"]
        }}
      />
    )
    const summary = screen.getByTestId("permission-decision-summary")
    expect(within(summary).getByRole("heading", { name: "Allow Syrus to capture a screenshot?" })).toBeInTheDocument()
    for (const text of ["What will happen", "read what is on screen", "Affects", "The browser tab", "Requested by", "Syrus · Chat", "This one time"]) {
      expect(summary).toHaveTextContent(text)
    }
    // Nothing to disclose, so no empty disclosure.
    expect(screen.queryByText("Technical details")).not.toBeInTheDocument()
  })

  it("folds implementation metadata behind a collapsed disclosure and drops empty values", () => {
    render(
      <PermissionDecisionSummary
        fallbackStatement="Draft an email"
        presentation={{ why_approval_required: "Your settings require approval." }}
        technical={[
          ["Capability", "mail.send · mail.send/draft"],
          ["Arguments", {}],
          ["Resource scope", "{}"],
          ["Effects", []],
          ["Session", "chat-123"]
        ]}
      />
    )
    expect(screen.getByRole("heading", { name: "Allow: Draft an email?" })).toBeInTheDocument()
    const details = screen.getByTestId("permission-technical-details") as HTMLDetailsElement
    expect(details.open).toBe(false)
    expect(details).toHaveTextContent("mail.send · mail.send/draft")
    expect(details).toHaveTextContent("chat-123")
    expect(details).toHaveTextContent("Your settings require approval.")
    expect(details).not.toHaveTextContent("Arguments")
    expect(details).not.toHaveTextContent("Resource scope")
    expect(details).not.toHaveTextContent("Effects")
    expect(screen.queryByText("{}")).not.toBeInTheDocument()
  })

  it("derives the action phrase used to word remembered scopes", () => {
    expect(permissionActionPhrase("Allow Syrus to capture a screenshot?")).toBe("capture a screenshot")
    expect(permissionActionPhrase("Run a database query")).toBe("Run a database query")
    expect(permissionActionPhrase(undefined)).toBeNull()
    expect([hasDetailValue({}), hasDetailValue("  "), hasDetailValue([]), hasDetailValue(null), hasDetailValue({ a: 1 })]).toEqual([
      false,
      false,
      false,
      false,
      true
    ])
  })
})
