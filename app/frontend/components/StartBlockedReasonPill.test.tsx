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

  it("includes structured start-block details in the tooltip", () => {
    render(
      <StartBlockedReasonPill
        details={{
          message: "multiple dependency branches are ready",
          dependencies: [{ slug: "JOB-1574" }, { job_id: 1575 }],
          action: "Land the sibling dependencies."
        }}
        reason="stack_fan_in_base_unavailable"
      />
    )

    expect(screen.getByText("Fan-in base unavailable").closest("[data-status-pill]")).toHaveAttribute(
      "title",
      [
        "Multiple dependency PR branches are ready, but Syrus could not prepare a combined execution base.",
        "multiple dependency branches are ready",
        "Dependencies: JOB-1574, JOB-1575",
        "Land the sibling dependencies."
      ].join("\n")
    )
  })

  it("escalates gray tone to amber when start_blocked_at is more than 30 minutes ago", () => {
    const blockedAt = new Date(Date.now() - 31 * 60 * 1000).toISOString()
    render(<StartBlockedReasonPill reason="urgent_job_active" startBlockedAt={blockedAt} />)

    const pill = screen.getByText("Urgent job in progress").closest("[data-status-pill]")
    expect(pill).toHaveClass("bg-amber-50")
    expect(pill).not.toHaveClass("bg-gray-100")
  })

  it("keeps gray tone when start_blocked_at is less than 30 minutes ago", () => {
    const blockedAt = new Date(Date.now() - 10 * 60 * 1000).toISOString()
    render(<StartBlockedReasonPill reason="urgent_job_active" startBlockedAt={blockedAt} />)

    expect(screen.getByText("Urgent job in progress").closest("[data-status-pill]")).toHaveClass("bg-gray-100")
  })

  it("does not escalate non-gray tones even when blocked for a long time", () => {
    const blockedAt = new Date(Date.now() - 60 * 60 * 1000).toISOString()
    render(<StartBlockedReasonPill reason="main_branch_broken" startBlockedAt={blockedAt} />)

    expect(screen.getByText("Main branch broken").closest("[data-status-pill]")).toHaveClass("bg-red-50")
  })

  it("includes next retry timing in the tooltip when nextCheckAt is in the future", () => {
    const nextCheckAt = new Date(Date.now() + 3 * 60 * 1000).toISOString()
    render(<StartBlockedReasonPill nextCheckAt={nextCheckAt} reason="urgent_job_active" />)

    const pill = screen.getByText("Urgent job in progress").closest("[data-status-pill]")
    expect(pill?.getAttribute("title")).toContain("Next retry in 3 minutes")
  })

  it("includes refusal count in the tooltip when count is greater than 1", () => {
    render(<StartBlockedReasonPill count={5} reason="urgent_job_active" />)

    const pill = screen.getByText("Urgent job in progress").closest("[data-status-pill]")
    expect(pill?.getAttribute("title")).toContain("Refused 5 times")
  })

  it("does not include refusal count when count is 1", () => {
    render(<StartBlockedReasonPill count={1} reason="urgent_job_active" />)

    const pill = screen.getByText("Urgent job in progress").closest("[data-status-pill]")
    expect(pill?.getAttribute("title")).not.toContain("Refused")
  })
})
