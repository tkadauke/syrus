import { describe, expect, it } from "vitest"
import { menuButtonClass } from "./formatting"

describe("menuButtonClass", () => {
  it("uses semantic brand tokens for primary menu actions", () => {
    const className = menuButtonClass("primary")

    expect(className).toContain("text-brand")
    expect(className).toContain("hover:bg-brand/10")
    expect(className).toContain("hover:text-brand")
    expect(className).toContain("dark:text-brand-emphasis")
    expect(className).not.toContain("text-blue-700")
    expect(className).not.toContain("hover:bg-blue-50")
    expect(className).not.toContain("dark:text-blue-200")
  })
})
