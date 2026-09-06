import { describe, expect, it } from "vitest"
import {
  contextGapsForHunks,
  countDiffRows,
  fullyRevealedGapStates,
  gapSize,
  hunksFromLines,
  mergeContextIntoLines,
  parseUnifiedDiff,
  remainingInGap,
  tokenizeCode
} from "./diffRendering"

const SAMPLE_PATCH = [
  "diff --git a/app/models/job.rb b/app/models/job.rb",
  "--- a/app/models/job.rb",
  "+++ b/app/models/job.rb",
  "@@ -10,3 +10,4 @@ class Job",
  " context",
  "-old",
  "+new",
  "+extra"
].join("\n")

describe("countDiffRows", () => {
  it("counts parsed rows, not source bytes", () => {
    expect(countDiffRows(SAMPLE_PATCH)).toBe(parseUnifiedDiff(SAMPLE_PATCH).length)
  })

  it("returns 0 for a null/empty patch", () => {
    expect(countDiffRows(null)).toBe(0)
    expect(countDiffRows("")).toBe(0)
  })
})

describe("tokenizeCode", () => {
  it("marks identifiers and numbers as highlightable", () => {
    const tokens = tokenizeCode("foo_bar(42)")
    expect(tokens).toEqual([
      { highlightable: true, text: "foo_bar" },
      { highlightable: false, text: "(" },
      { highlightable: true, text: "42" },
      { highlightable: false, text: ")" }
    ])
  })

  it("never treats punctuation-only or whitespace-run tokens as highlightable", () => {
    const tokens = tokenizeCode("  ...  ")
    expect(tokens.every((token) => !token.highlightable)).toBe(true)
    // whitespace collapses to single tokens, not one per character
    expect(tokens.filter((token) => /^\s+$/.test(token.text))).toHaveLength(2)
  })
})

describe("hunksFromLines / contextGapsForHunks", () => {
  it("computes the gap before the first hunk from hunk metadata alone", () => {
    const lines = parseUnifiedDiff(SAMPLE_PATCH)
    const hunks = hunksFromLines(lines)
    expect(hunks).toEqual([{ newLines: 4, newStart: 10, oldLines: 3, oldStart: 10 }])

    const gaps = contextGapsForHunks(hunks, null)
    expect(gaps).toHaveLength(2)
    expect(gaps[0]).toEqual({ endNew: 9, offset: 0, startNew: 1 })
  })

  it("leaves the trailing gap unbounded until the total file length is known", () => {
    const hunks = hunksFromLines(parseUnifiedDiff(SAMPLE_PATCH))
    const gapsUnknown = contextGapsForHunks(hunks, null)
    expect(gapsUnknown[1].endNew).toBe(Number.POSITIVE_INFINITY)

    const gapsKnown = contextGapsForHunks(hunks, 20)
    expect(gapsKnown[1]).toEqual({ endNew: 20, offset: 1, startNew: 14 })
  })

  it("computes a bounded interior gap directly from two hunks' metadata, no fetch required", () => {
    const twoHunkPatch = [
      "diff --git a/f b/f",
      "--- a/f",
      "+++ b/f",
      "@@ -1,2 +1,2 @@",
      "-a",
      "+b",
      " keep",
      "@@ -20,2 +20,2 @@",
      "-c",
      "+d"
    ].join("\n")
    const hunks = hunksFromLines(parseUnifiedDiff(twoHunkPatch))
    const gaps = contextGapsForHunks(hunks, null)
    // gap between hunk 0 (ends at new line 2) and hunk 1 (starts at new line 20)
    expect(gaps[1]).toEqual({ endNew: 19, offset: 0, startNew: 3 })
    expect(gapSize(gaps[1])).toBe(17)
  })
})

describe("remainingInGap", () => {
  it("is the full gap size when nothing has been revealed", () => {
    const gap = { endNew: 9, offset: 0, startNew: 1 }
    expect(remainingInGap(gap, undefined)).toBe(9)
  })

  it("subtracts lines already revealed from both edges", () => {
    const gap = { endNew: 9, offset: 0, startNew: 1 }
    expect(remainingInGap(gap, { fromBottom: 2, fromTop: 3 })).toBe(4)
  })

  it("never goes negative when a stale state over-claims the gap", () => {
    const gap = { endNew: 5, offset: 0, startNew: 1 }
    expect(remainingInGap(gap, { fromBottom: 10, fromTop: 10 })).toBe(0)
  })
})

describe("mergeContextIntoLines", () => {
  const fileLines = Array.from({ length: 20 }, (_, index) => `line ${index + 1}`)

  it("splices revealed context lines around hunks without touching existing hunk lines", () => {
    const lines = parseUnifiedDiff(SAMPLE_PATCH)
    const hunks = hunksFromLines(lines)
    const gaps = contextGapsForHunks(hunks, fileLines.length)
    const merged = mergeContextIntoLines(lines, gaps, [{ fromBottom: 0, fromTop: 2 }, undefined], fileLines)

    // the two revealed lines are new-file lines 1 and 2, spliced in before the file/meta/hunk header rows
    const revealed = merged.filter((line) => line.kind === "context" && line.code.startsWith("line "))
    expect(revealed.map((line) => [line.code, line.oldLine, line.newLine])).toEqual([
      ["line 1", 1, 1],
      ["line 2", 2, 2]
    ])

    // original hunk-body lines are untouched (same oldLine/newLine as before merging)
    const original = merged.find((line) => line.code === "new")
    expect(original).toMatchObject({ newLine: 11, oldLine: null })
  })

  it("returns the lines unchanged when no file content has been fetched yet", () => {
    const lines = parseUnifiedDiff(SAMPLE_PATCH)
    const hunks = hunksFromLines(lines)
    const gaps = contextGapsForHunks(hunks, null)
    expect(mergeContextIntoLines(lines, gaps, [], null)).toBe(lines)
  })

  it("computes old-file line numbers using the offset established by prior hunks", () => {
    const twoHunkPatch = [
      "diff --git a/f b/f",
      "--- a/f",
      "+++ b/f",
      "@@ -1,1 +1,2 @@",
      "-old",
      "+new1",
      "+new2",
      "@@ -10,1 +11,1 @@",
      " tail"
    ].join("\n")
    const bigFile = Array.from({ length: 15 }, (_, index) => `f${index + 1}`)
    const lines = parseUnifiedDiff(twoHunkPatch)
    const hunks = hunksFromLines(lines)
    const gaps = contextGapsForHunks(hunks, bigFile.length)
    // gap[1] sits between hunk 0 (ends new line 2) and hunk 1 (starts new line 11):
    // new lines 3..10 map back to old lines 2..9 (offset = +1 introduced by hunk 0)
    const merged = mergeContextIntoLines(lines, gaps, [undefined, { fromBottom: 0, fromTop: 3 }], bigFile)
    const revealed = merged.filter((line) => line.kind === "context" && line.code.startsWith("f"))
    expect(revealed.map((line) => [line.code, line.oldLine, line.newLine])).toEqual([
      ["f3", 2, 3],
      ["f4", 3, 4],
      ["f5", 4, 5]
    ])
  })
})

describe("fullyRevealedGapStates", () => {
  it("claims the entire gap from the top edge", () => {
    const hunks = hunksFromLines(parseUnifiedDiff(SAMPLE_PATCH))
    const gaps = contextGapsForHunks(hunks, 20)
    const states = fullyRevealedGapStates(gaps)
    states.forEach((state, index) => expect(state).toEqual({ fromBottom: 0, fromTop: gapSize(gaps[index]) }))
  })
})
