import { describe, expect, it } from "vitest"
import { parseUnifiedDiff, type DiffLine } from "../../components/diff/diffRendering"
import { hunkForLine } from "./DiffReviewFeedback"

const PATCH_WITH_REPEATED_LINES = [
  "diff --git a/app/models/example.rb b/app/models/example.rb",
  "--- a/app/models/example.rb",
  "+++ b/app/models/example.rb",
  "@@ -1,6 +1,7 @@",
  " class Example",
  "   def first",
  "+    end",
  "   end",
  "   def untouched",
  "   end",
  "@@ -20,6 +21,7 @@",
  "   def second",
  "     shared",
  "-    end",
  "+    end",
  "     tail",
  "   end",
  " end"
].join("\n")

function diffLineMatching(predicate: (line: DiffLine) => boolean): DiffLine {
  const line = parseUnifiedDiff(PATCH_WITH_REPEATED_LINES).find(predicate)
  if (!line) throw new Error("Expected fixture diff line to exist")
  return line
}

describe("hunkForLine", () => {
  it("returns a context window for commentable context lines", () => {
    const line = diffLineMatching((candidate) => candidate.kind === "context" && candidate.oldLine === 21 && candidate.newLine === 22)

    const hunk = hunkForLine(PATCH_WITH_REPEATED_LINES, line)

    expect(hunk).toContain("@@ -20,6 +21,7 @@")
    expect(hunk).toContain("     shared")
    expect(hunk).not.toBe("@@ -1,6 +1,7 @@")
  })

  it("uses line numbers instead of the first repeated added text match", () => {
    const line = diffLineMatching((candidate) => candidate.kind === "add" && candidate.newLine === 23)

    const hunk = hunkForLine(PATCH_WITH_REPEATED_LINES, line)

    expect(hunk).toContain("@@ -20,6 +21,7 @@")
    expect(hunk).toContain("+    end")
    expect(hunk).not.toContain("@@ -1,6 +1,7 @@")
  })

  it("anchors deleted lines by their old line number", () => {
    const line = diffLineMatching((candidate) => candidate.kind === "delete" && candidate.oldLine === 22)

    const hunk = hunkForLine(PATCH_WITH_REPEATED_LINES, line)

    expect(hunk).toContain("@@ -20,6 +21,7 @@")
    expect(hunk).toContain("-    end")
    expect(hunk).not.toContain("@@ -1,6 +1,7 @@")
  })
})
