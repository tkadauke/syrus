import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { StartBlockedReasonPill } from "./StartBlockedReasonPill"

describe("StartBlockedReasonPill", () => {
  it("renders main branch health blocks as red with an explanatory tooltip", () => {
    render(<StartBlockedReasonPill reason="main_branch_broken" />)

    const pill = screen.getByText("Main branch broken").closest("[data-status-pill]")
    expect(pill).toHaveClass("bg-red-50")
    expect(pill).toHaveAttribute("title", "Repository landing is paused because the main branch is unhealthy.")
  })

  it("renders urgent job blocks as slate", () => {
    render(<StartBlockedReasonPill reason="urgent_job_active" />)

    expect(screen.getByText("Urgent job in progress").closest("[data-status-pill]")).toHaveClass("bg-gray-100")
  })
})
