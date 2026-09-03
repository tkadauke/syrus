import { describe, expect, it } from "vitest"
import { diffGutterClass, diffLineClass, diffMarkerClass, parseUnifiedDiff } from "./diffRendering"

describe("parseUnifiedDiff", () => {
  it("tracks old and new line numbers across context, additions, and deletions", () => {
    const lines = parseUnifiedDiff([
      "diff --git a/app/models/job.rb b/app/models/job.rb",
      "--- a/app/models/job.rb",
      "+++ b/app/models/job.rb",
      "@@ -10,3 +10,4 @@ class Job",
      " context",
      "-old",
      "+new",
      "+extra"
    ].join("\n"))

    expect(lines.map((line) => [line.kind, line.oldLine, line.newLine, line.marker, line.code])).toEqual([
      ["file", null, null, "", "diff --git a/app/models/job.rb b/app/models/job.rb"],
      ["meta", null, null, "", "--- a/app/models/job.rb"],
      ["meta", null, null, "", "+++ b/app/models/job.rb"],
      ["hunk", null, null, "", "@@ -10,3 +10,4 @@ class Job"],
      ["context", 10, 10, "", "context"],
      ["delete", 11, null, "-", "old"],
      ["add", null, 11, "+", "new"],
      ["add", null, 12, "+", "extra"]
    ])
  })
})

describe("diff rendering classes", () => {
  it("uses semantic info tokens for hunk headers", () => {
    const lineClass = diffLineClass("hunk")
    const gutterClass = diffGutterClass("hunk")
    const markerClass = diffMarkerClass("hunk")

    expect(lineClass).toContain("bg-info/10")
    expect(lineClass).toContain("text-info")
    expect(gutterClass).toContain("border-info/30")
    expect(gutterClass).toContain("bg-info/10")
    expect(gutterClass).toContain("text-info")
    expect(markerClass).toContain("text-info")
    expect(`${lineClass} ${gutterClass} ${markerClass}`).not.toMatch(/\b(?:bg|text|border)-blue-/)
  })
})
