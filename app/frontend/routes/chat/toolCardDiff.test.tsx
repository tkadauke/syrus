import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { changedFilePaths, RawDiffPreview } from "./toolCardDiff"

describe("tool card diff helpers", () => {
  it("decodes Git-quoted destination paths and uses rename destinations", () => {
    const diff = [
      'diff --git "a/lib/caf\\303\\251.rb" "b/lib/caf\\303\\251.rb"',
      'diff --git "a/old name.rb" "b/new name.rb"',
      "similarity index 100%",
      "rename from old name.rb",
      "rename to new name.rb"
    ].join("\n")

    expect(changedFilePaths(diff)).toEqual(["lib/café.rb", "new name.rb"])
  })

  it("announces when the shared raw diff preview caps its lines", () => {
    const diff = Array.from({ length: 301 }, (_, index) => `+line ${index}`).join("\n")
    render(<RawDiffPreview diff={diff} />)

    expect(screen.getByText("Showing first 300 of 301 lines")).toBeInTheDocument()
  })
})
