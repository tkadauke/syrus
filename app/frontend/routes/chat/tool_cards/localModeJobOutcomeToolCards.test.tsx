import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import openInLocalModeCard from "./open_in_local_mode"
import cancelLocalModeCard from "./cancel_local_mode"
import createCodingJobCard from "./create_coding_job"

// Parity guard for the Local Mode job-outcome tool card family (EPIC-293 /
// JOB-4225). Each card is a thin re-export of ../localModeJobOutcomeCard,
// so the shared parsing/rendering is covered once in
// localModeJobOutcomeCard.test.tsx; this just guards the tool-name binding.
const CARDS: Array<[string, ToolCardRenderer]> = [
  ["open_in_local_mode", openInLocalModeCard],
  ["cancel_local_mode", cancelLocalModeCard],
  ["create_coding_job", createCodingJobCard]
]

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("Local Mode job-outcome tool card family", () => {
  it("registers each card under a unique, exact tool name", () => {
    const names = CARDS.map(([name]) => name)
    expect(new Set(names).size).toBe(names.length)
    for (const [name, card] of CARDS) expect(card.toolName).toBe(name)
  })

  it.each(CARDS)("%s falls back to null for a malformed payload", (_name, card) => {
    expect(card.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(card.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it.each(CARDS)("%s summarizes and wires through a well-formed payload", (_name, card) => {
    const parsedResult = { job_id: 42, job_state: "coding", message: "done" }
    expect(card.collapsedSummary?.(context({ parsedResult }))).toBe("done")
    expect(card.renderExpanded(context({ parsedResult }))).not.toBeNull()
  })
})
