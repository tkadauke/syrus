import { describe, expect, it } from "vitest"
import type { JobStep } from "../../api/jobs"
import {
  effectiveStepStatus,
  gradeDisplayStatus,
  gradeSummaries,
  gradeSummaryCounts,
  loopDisplayStatus,
  type GradeStepItem,
  type LoopStepItem
} from "./stepModel"

function step(id: number, kind: string, state: string, displayStatus: string | null = state): JobStep {
  return {
    id,
    kind,
    display_name: kind,
    display_status: displayStatus,
    position: id,
    iteration: 1,
    loop_id: "grade-loop",
    state,
    started_at: null,
    finished_at: null,
    created_at: null,
    updated_at: null,
    details: kind === "grader" ? { name: "tests", required: true, exit_code: 1 } : null,
    warnings: [],
    latest: false,
    runs: []
  }
}

describe("accepted grader failure presentation", () => {
  it("shows the grader batch and enclosing loop as warnings, not failures", () => {
    const setup = step(1, "grader_fanout", "succeeded")
    const grader = step(2, "grader", "failed", "warning")
    const result = step(3, "grader_collect", "succeeded")
    const grade: GradeStepItem = { type: "grade", key: "grade", steps: [setup, grader, result], graders: [grader], preflight: false }
    const loop: LoopStepItem = { type: "loop", loopId: "grade-loop", iterations: [{ iteration: 1, steps: grade.steps, items: [grade] }] }

    expect(gradeDisplayStatus(grade)).toBe("warning")
    expect(loopDisplayStatus(loop)).toBe("warning")
    expect(gradeSummaryCounts(gradeSummaries(grade))).toEqual({ passed: 0, warning: 1, failed: 0, error: 0 })
  })
})

describe("effectiveStepStatus", () => {
  it("projects terminal live state for materialized work without labeling a future queued step", () => {
    const completed = step(1, "push", "succeeded", null)
    completed.runs = [{ id: 10, state: "succeeded" } as JobStep["runs"][number]]
    const future = step(2, "summarize", "queued", null)

    expect(effectiveStepStatus(completed)).toBe("succeeded")
    expect(effectiveStepStatus(future)).toBeNull()
  })

  it.each(["succeeded", "failed", "cancelled", "skipped", "blocked"])("projects live terminal %s over a stale running projection", (state) => {
    const completed = step(1, "push", state, "running")
    completed.runs = [{ id: 10, state } as JobStep["runs"][number]]

    expect(effectiveStepStatus(completed)).toBe(state)
  })

  it("keeps server projections and active retries ahead of terminal step state", () => {
    const warning = step(1, "grader", "failed", "warning")
    warning.runs = [{ id: 10, state: "failed" } as JobStep["runs"][number]]
    const retrying = step(2, "push", "failed", "failed")
    retrying.runs = [{ id: 20, state: "queued" } as JobStep["runs"][number]]

    expect(effectiveStepStatus(warning)).toBe("warning")
    expect(effectiveStepStatus(retrying)).toBe("queued")
  })
})
