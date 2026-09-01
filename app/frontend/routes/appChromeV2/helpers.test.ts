import { describe, expect, it } from "vitest"
import { sidebarLinkClass } from "./helpers"

describe("sidebarLinkClass", () => {
  it("uses semantic brand tokens for active sidebar links", () => {
    const className = sidebarLinkClass(true)

    expect(className).toContain("bg-brand/10")
    expect(className).toContain("text-brand")
    expect(className).toContain("dark:text-brand-emphasis")
    expect(className).not.toMatch(/\b(?:bg|text)-blue-\d/)
  })
})
