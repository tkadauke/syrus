import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { parseRefMovementCore, refMovementCollapsedSummary, RefMovementCoreFields } from "./refMovementToolCard"

describe("parseRefMovementCore", () => {
  it("parses a dispatched action", () => {
    const core = parseRefMovementCore({
      ref_movement_action_id: 7,
      action_name: "send_job_upstream",
      state: "dispatched",
      blocked_reason: null,
      source_kind: "job",
      source_ref: "syrus/direct-4225",
      target_kind: "branch",
      target_ref: "main",
      target_repository: "upstream/syrus",
      target_inferred: true,
      mode: "auto",
      grade_phases: [ "review", "landing" ]
    })

    expect(core).toEqual({
      actionId: "7",
      actionName: "send_job_upstream",
      state: "dispatched",
      blockedReason: null,
      sourceKind: "job",
      sourceRef: "syrus/direct-4225",
      targetKind: "branch",
      targetRef: "main",
      targetRepository: "upstream/syrus",
      targetInferred: true,
      mode: "auto",
      gradePhases: [ "review", "landing" ]
    })
  })

  it("returns null when required fields are missing", () => {
    expect(parseRefMovementCore({ action_name: "send_job_upstream", state: "dispatched" })).toBeNull()
    expect(parseRefMovementCore("not json")).toBeNull()
  })
})

describe("refMovementCollapsedSummary", () => {
  it("summarizes a dispatched action", () => {
    const core = parseRefMovementCore({ ref_movement_action_id: 7, action_name: "send_job_upstream", state: "dispatched" })!
    expect(refMovementCollapsedSummary(core)).toBe("send job upstream (dispatched)")
  })

  it("summarizes a blocked action with its reason", () => {
    const core = parseRefMovementCore({ ref_movement_action_id: 7, action_name: "send_job_upstream", state: "blocked", blocked_reason: "job_id is required" })!
    expect(refMovementCollapsedSummary(core)).toBe("send job upstream blocked: job_id is required")
  })
})

describe("RefMovementCoreFields", () => {
  it("renders source/target refs and grade phases", () => {
    const core = parseRefMovementCore({
      ref_movement_action_id: 7,
      action_name: "send_job_upstream",
      state: "dispatched",
      source_kind: "job",
      source_ref: "syrus/direct-4225",
      target_kind: "branch",
      target_ref: "main",
      mode: "auto",
      grade_phases: [ "review" ]
    })!

    render(<RefMovementCoreFields core={core} />)

    expect(screen.getByText("send_job_upstream")).toBeInTheDocument()
    expect(screen.getByText("dispatched")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-4225")).toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("review")).toBeInTheDocument()
  })
})
