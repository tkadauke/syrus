import { describe, expect, it } from "vitest"
import { stepArtifactAdversarialReview } from "./stepArtifacts"

describe("stepArtifactAdversarialReview", () => {
  it("collapses panel member entries into their aggregate review round", () => {
    expect(
      stepArtifactAdversarialReview([
        { iteration: 1, panel_id: "panel-1", provider: "claude", model: "sonnet", verdict: "approved", critique: "Clean." },
        { iteration: 1, panel_id: "panel-1", provider: "codex", model: "gpt-5", verdict: "needs_work", critique: "Minor concern." },
        {
          iteration: 1,
          panel_id: "panel-1",
          aggregate: true,
          verdict: "approved",
          consensus: "majority",
          dropped_members: [{ provider: "gemini", model: "pro" }],
          non_blocking_findings: [{ provider: "codex", model: "gpt-5", critique: "Minor concern." }]
        }
      ])
    ).toEqual([
      expect.objectContaining({
        iteration: 1,
        verdict: "approved",
        aggregate: true,
        consensus: "majority",
        members: [
          expect.objectContaining({ provider: "claude", verdict: "approved", critique: "Clean." }),
          expect.objectContaining({ provider: "codex", verdict: "needs_work", critique: "Minor concern." })
        ],
        dropped_members: [expect.objectContaining({ provider: "gemini", model: "pro" })],
        non_blocking_findings: [expect.objectContaining({ provider: "codex", critique: "Minor concern." })]
      })
    ])
  })

  it("keeps legacy single-reviewer iterations unchanged", () => {
    expect(stepArtifactAdversarialReview([{ iteration: 2, verdict: "approved", critique: "Looks good." }])).toEqual([
      { iteration: 2, verdict: "approved", critique: "Looks good." }
    ])
  })
})
