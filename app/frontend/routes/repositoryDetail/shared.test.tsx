import { describe, expect, it } from "vitest"
import { buttonClass, stateFilterClass } from "./shared"

describe("repository detail shared styles", () => {
  it("uses semantic brand tokens for the active state filter", () => {
    const className = stateFilterClass(true)

    expect(className).toContain("border-brand")
    expect(className).toContain("bg-brand")
    expect(className).toContain("text-on-brand")
    expect(className).not.toContain("border-blue-600")
    expect(className).not.toContain("bg-blue-600")
    expect(className).not.toContain("text-white")
  })

  it("uses semantic brand tokens for blue-tone repository actions", () => {
    const className = buttonClass("blue")

    expect(className).toContain("bg-brand")
    expect(className).toContain("text-on-brand")
    expect(className).toContain("hover:opacity-90")
    expect(className).toContain("disabled:opacity-60")
    expect(className).not.toContain("bg-blue-600")
    expect(className).not.toContain("bg-blue-500")
    expect(className).not.toContain("text-white")
  })
})
