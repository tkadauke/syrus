import "@testing-library/jest-dom/vitest"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import ReviewDashboardNotice from "./ReviewDashboardNotice"

describe("ReviewDashboardNotice", () => {
  it("links an actionable count to the independently owned Review route", () => {
    render(
      <MemoryRouter>
        <ReviewDashboardNotice count={5} />
      </MemoryRouter>
    )

    expect(screen.getByText("5 Jobs are ready for your review.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Start review" })).toHaveAttribute("href", "/review")
  })

  it("renders nothing without actionable Jobs", () => {
    const { container } = render(
      <MemoryRouter>
        <ReviewDashboardNotice count={0} />
      </MemoryRouter>
    )

    expect(container).toBeEmptyDOMElement()
  })
})
