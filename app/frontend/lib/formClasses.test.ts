import { describe, expect, it } from "vitest"
import { inputClass } from "./formClasses"

describe("inputClass", () => {
  it("uses semantic border and brand focus tokens", () => {
    const className = inputClass()

    expect(className).toContain("border-border")
    expect(className).toContain("focus:border-brand")
    expect(className).toContain("focus:ring-brand")
    expect(className).not.toMatch(/\bterracotta-\d+\b/)
  })

  it("renders w-auto instead of w-full when fullWidth is false", () => {
    const className = inputClass({ fullWidth: false })

    expect(className).toContain("w-auto")
    expect(className).not.toMatch(/\bw-full\b/)
  })
})
