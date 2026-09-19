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

    expect(screen.getByRole("article")).toHaveClass("border-brand/30")
    expect(screen.getByRole("heading", { name: "Confirm JOB-12" })).toBeInTheDocument()
    expect(screen.getByText("Review this action before it runs.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Confirm" })).toBeInTheDocument()
  })

  it("stretches the header wrapper to the full card width so trailing controls align to the right edge", () => {
    render(<ConfirmationCard header={<h2>Confirm JOB-12</h2>} />)

    expect(screen.getByRole("heading", { name: "Confirm JOB-12" }).parentElement).toHaveClass("w-full")
  })
})
