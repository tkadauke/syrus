import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import * as diffRendering from "../../components/diff/diffRendering"
import type { DiffLine } from "../../components/diff/diffRendering"
import { RawDiffPreview } from "./toolCardDiff"

afterEach(() => {
  vi.restoreAllMocks()
})

describe("RawDiffPreview", () => {
  it("does not construct full-diff lines until the modal opens", () => {
    let offscreenCodeReads = 0
    const lines = Array.from({ length: 301 }, (_, index) => {
      const line: DiffLine = {
        kind: "context",
        oldLine: index + 1,
        newLine: index + 1,
        marker: "",
        code: "",
        hunkId: 0
      }
      Object.defineProperty(line, "code", {
        get: () => {
          if (index >= 300) offscreenCodeReads += 1
          return `line ${index + 1}`
        }
      })
      return line
    })
    vi.spyOn(diffRendering, "parseUnifiedDiff").mockReturnValue(lines)

    render(<RawDiffPreview diff="large diff" />)

    expect(screen.getByText("Showing first 300 of 301 lines.")).toBeInTheDocument()
    expect(offscreenCodeReads).toBe(0)

    fireEvent.click(screen.getByRole("button", { name: "Show full diff" }))

    expect(screen.getByRole("dialog", { name: "Full diff" })).toBeInTheDocument()
    expect(offscreenCodeReads).toBeGreaterThan(0)
  })
})
