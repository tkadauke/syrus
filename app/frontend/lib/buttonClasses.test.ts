import { describe, expect, it } from "vitest"
import { buttonClass } from "./buttonClasses"

describe("buttonClass", () => {
  it("uses semantic brand tokens for primary actions", () => {
    const className = buttonClass("primary")

    expect(className).toContain("bg-brand")
    expect(className).toContain("text-on-brand")
    expect(className).toContain("hover:opacity-90")
    expect(className).toContain("focus-visible:ring-brand")
    expect(className).not.toContain("bg-blue-600")
    expect(className).not.toContain("bg-blue-500")
    expect(className).not.toContain("text-white")
  })
})
