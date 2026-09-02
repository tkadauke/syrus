import { describe, expect, it } from "vitest"
import { diffGutterClass, diffLineClass, diffMarkerClass } from "./diffRendering"

describe("diff rendering classes", () => {
  it("uses semantic info tokens for hunk headers", () => {
    expect(diffLineClass("hunk")).toContain("bg-info/10")
    expect(diffLineClass("hunk")).toContain("text-info")
    expect(diffGutterClass("hunk")).toContain("border-info/30")
    expect(diffGutterClass("hunk")).toContain("bg-info/10")
    expect(diffGutterClass("hunk")).toContain("text-info")
    expect(diffMarkerClass("hunk")).toContain("text-info")

    expect(diffLineClass("hunk")).not.toMatch(/\b(?:bg|text|border)-blue-/)
    expect(diffGutterClass("hunk")).not.toMatch(/\b(?:bg|text|border)-blue-/)
    expect(diffMarkerClass("hunk")).not.toMatch(/\b(?:bg|text|border)-blue-/)
  })
})
