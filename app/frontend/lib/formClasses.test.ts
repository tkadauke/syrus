import { describe, expect, it } from "vitest"
import { inputClass } from "./formClasses"

describe("inputClass", () => {
  it("uses semantic border and brand focus tokens instead of raw terracotta utilities", () => {
    const className = inputClass()

    expect(className).toContain("border-border")
    expect(className).toContain("focus:border-brand")
    expect(className).toContain("focus:ring-brand")
    expect(className).not.toMatch(/\bterracotta-\d/)
  })

  it("renders w-auto instead of w-full when fullWidth is false", () => {
    const className = inputClass({ fullWidth: false })

    expect(className).toMatch(/\bw-auto\b/)
    expect(className).not.toMatch(/\bw-full\b/)
  })
})
