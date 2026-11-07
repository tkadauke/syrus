import { describe, expect, it } from "vitest"
import { stepArtifactAdversarialReview, stepArtifactCoworkerReview } from "./stepArtifacts"

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
          vote_breakdown: { approved: 1, needs_work: 1, skipped: 0, counted: 2, total: 2, required_approvals: 2, min_members: 2 },
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
        vote_breakdown: { approved: 1, needs_work: 1, skipped: 0, counted: 2, total: 2, required_approvals: 2, min_members: 2 },
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

describe("stepArtifactCoworkerReview", () => {
  it("preserves named identity, immutable evidence, safe context, and memory receipts", () => {
    const entry = {
      iteration: 1,
      verdict: "approved",
      critique: "Looks good.",
      reviewer: { label: "Maya · Codex", provider: "codex", model: "gpt-5" },
      review_context_manifest: { protected_prompt: { sha256: "safe" } },
      memory_persistence: { state: "persisted", persisted_commit_sha: "a".repeat(40) },
      review_evidence: { state: "submitted", reviewed_head_sha: "b".repeat(40), canonical_diff_sha256: "c".repeat(64) }
    }

    expect(stepArtifactCoworkerReview([entry])).toEqual([entry])
  })

  it("keeps stale and typed-failure evidence visible", () => {
    expect(stepArtifactCoworkerReview([{ iteration: 2, verdict: "stale", critique: "The reviewed diff changed." }])).toEqual([
      { iteration: 2, verdict: "stale", critique: "The reviewed diff changed." }
    ])
  })
})
