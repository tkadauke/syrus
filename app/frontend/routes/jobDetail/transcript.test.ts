import { describe, expect, it } from "vitest"
import { coalesceTranscriptLogs } from "./transcript"

describe("coalesceTranscriptLogs", () => {
  it("joins adjacent compatible stream chunks but preserves command boundaries", () => {
    const logs = coalesceTranscriptLogs([
      { id: 1, sequence: 1, kind: "stdout", chunk: "[grader:lint] $ npm run lint", created_at: null },
      { id: 2, sequence: 2, kind: "stdout", chunk: "checking files", created_at: null },
      { id: 3, sequence: 3, kind: "stdout", chunk: "[grader:test] $ npm test", created_at: null },
      { id: 4, sequence: 4, kind: "stdout", chunk: "all green", created_at: null }
    ])

    expect(logs).toHaveLength(2)
    expect(logs[0].chunk).toBe("[grader:lint] $ npm run lint\nchecking files")
    expect(logs[1].chunk).toBe("[grader:test] $ npm test\nall green")
  })
})
