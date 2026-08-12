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

  it("formats workflow admission delays without leaking the raw action", () => {
    render(
      <StartBlockedReasonPill
        details={{
          action: "delay_until",
          reason: "predicted_budget_pressure_high",
          delay_until: "2026-08-11T14:30:00Z",
          pressure: {
            candidate: {
              predicted_command_cost: {
                duration_seconds: 1500
              }
            },
            projected: {
              cpu_pressure: 132.4,
              io_pressure: 78.2,
              memory_used_percent: 84
            }
          }
        }}
        reason="workflow_admission_budget"
      />
    )

    const title = screen.getByText("Workflow admission delayed").closest("[data-status-pill]")?.getAttribute("title")
    expect(title).toContain("Syrus predicted that starting this workflow now would put too much pressure on the worker pool.")
    expect(title).toContain("Delayed until")
    expect(title).toContain("Predicted workflow cost would exceed the worker budget.")
    expect(title).toContain("Pressure: estimated 25m, projected CPU 132.4%, IO 78.2%")
    expect(title).not.toContain("delay_until")
  })

  it("uses next check timing and readable fallback details for admission delays", () => {
    render(
      <StartBlockedReasonPill
        details={{
          action: "delay_until",
          reason: "worker_host_pressure_high",
          details: {
            decision_basis: "conservative_defaults"
          }
        }}
        nextCheckAt="2026-08-11T14:35:00Z"
        reason="workflow_admission_budget"
      />
    )

    const title = screen.getByText("Workflow admission delayed").closest("[data-status-pill]")?.getAttribute("title")
    expect(title).toContain("Will check again at")
    expect(title).toContain("Worker host pressure is high.")
    expect(title).toContain("Syrus is using a conservative default estimate.")
    expect(title).not.toContain("delay_until")
  })

  it("notes when an admission delay was decided without worker telemetry", () => {
    render(
      <StartBlockedReasonPill
        details={{
          action: "delay_until",
          reason: "predicted_budget_pressure_high",
          pressure: {
            host: {
              telemetry_state: "absent"
            }
          }
        }}
        reason="workflow_admission_budget"
      />
    )

    const title = screen.getByText("Workflow admission delayed").closest("[data-status-pill]")?.getAttribute("title")
    expect(title).toContain("No worker telemetry has been recorded; this decision used step-profile pressure only.")
  })

  it("does not leak unknown machine action keys into generic tooltips", () => {
    render(
      <StartBlockedReasonPill
        details={{
          action: "retry_after_budget_recheck"
        }}
        reason="urgent_job_active"
      />
    )

    const title = screen.getByText("Urgent job in progress").closest("[data-status-pill]")?.getAttribute("title")
    expect(title).toBe("A non-urgent job is waiting while an urgent job in this repository remains active.")
    expect(title).not.toContain("retry_after_budget_recheck")
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
