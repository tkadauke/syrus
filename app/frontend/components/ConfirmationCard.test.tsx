import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ConfirmationCard } from "./ConfirmationCard"

describe("ConfirmationCard", () => {
  it("renders header, body, and footer slots", () => {
    render(
      <ConfirmationCard
        header={<h2>Confirm JOB-12</h2>}
        body={<p>Review this action before it runs.</p>}
        footer={<button type="button">Confirm</button>}
      />
    )

    expect(screen.getByRole("article")).toHaveClass("border-blue-200")
    expect(screen.getByRole("heading", { name: "Confirm JOB-12" })).toBeInTheDocument()
    expect(screen.getByText("Review this action before it runs.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Confirm" })).toBeInTheDocument()
  })
})
