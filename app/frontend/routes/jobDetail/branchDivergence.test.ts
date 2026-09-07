import { describe, expect, it } from "vitest"
import { workflowBranchDivergence } from "./branchDivergence"
import type { JobWorkflow } from "../../api/jobs"

function workflowWith(artifacts: Record<string, unknown>): JobWorkflow {
  return { artifacts } as unknown as JobWorkflow
}

const divergence = {
  branch: "syrus/direct-4485",
  remote_sha: "6c4ddd6",
  local_sha: "28a75d2"
}

describe("workflowBranchDivergence", () => {
  it("reads the comparison that says what replacing the branch would destroy", () => {
    const parsed = workflowBranchDivergence(workflowWith({
      branch_divergence: {
        ...divergence,
        comparison: {
          discarded: {
            commits: [{ sha: "abc1234", author: "Reviewer", date: "2026-09-07T10:00:00Z", subject: "Hand-edit" }],
            truncated: true
          },
          published: { commits: [{ sha: "def5678", subject: "Implement" }], truncated: false },
          discarded_files: { files: ["app/models/widget.rb"], truncated: false }
        }
      }
    }))

    expect(parsed?.comparison?.discarded?.commits).toEqual([
      { sha: "abc1234", author: "Reviewer", date: "2026-09-07T10:00:00Z", subject: "Hand-edit" }
    ])
    expect(parsed?.comparison?.discarded?.truncated).toBe(true)
    expect(parsed?.comparison?.published?.commits[0]?.sha).toBe("def5678")
    expect(parsed?.comparison?.published?.commits[0]?.author).toBeNull()
    expect(parsed?.comparison?.discardedFiles?.files).toEqual(["app/models/widget.rb"])
  })

  // Divergences recorded before the comparison existed still have to render.
  it("returns a null comparison when the artifact predates it", () => {
    const parsed = workflowBranchDivergence(workflowWith({ branch_divergence: divergence }))

    expect(parsed?.branch).toBe("syrus/direct-4485")
    expect(parsed?.comparison).toBeNull()
  })

  it("ignores malformed comparison payloads rather than rendering junk", () => {
    for (const comparison of [null, "nope", [], { discarded: { commits: "no" } }, { discarded: { commits: [{}] } }]) {
      const parsed = workflowBranchDivergence(workflowWith({
        branch_divergence: { ...divergence, comparison }
      }))
      expect(parsed?.comparison).toBeNull()
    }
  })
})
