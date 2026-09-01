import { describe, expect, it } from "vitest"
import { inputClass } from "./formClasses"

describe("inputClass", () => {
  it("uses semantic theme tokens for border and focus state", () => {
    const className = inputClass()

    expect(className).toContain("border-border")
    expect(className).toContain("focus:border-brand")
    expect(className).toContain("focus:ring-brand")
    expect(className).not.toMatch(/\b(?:focus:)?outline-terracotta-\d/)
    expect(className).not.toMatch(/\b(?:focus:)?ring-terracotta-\d/)
    expect(className).not.toMatch(/\b(?:focus:)?border-terracotta-\d/)
  })

  it("keeps the fullWidth toggle behavior", () => {
    expect(inputClass()).toContain("w-full")
    expect(inputClass({ fullWidth: false })).toContain("w-auto")
  })
})
