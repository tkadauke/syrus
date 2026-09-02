import { describe, expect, it } from "vitest"
import { diffGutterClass, diffLineClass, diffMarkerClass } from "./diffRendering"

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
