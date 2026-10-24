import { afterEach, describe, expect, it } from "vitest"
import i18n from "../../i18n"
import { buttonClasses } from "../../components/Button"
import { diffLineClass, formatTokenCount, primaryButton } from "./utils"

afterEach(async () => {
  await i18n.changeLanguage("en")
})

describe("formatTokenCount", () => {
  it("uses the active locale for exact and abbreviated counts", async () => {
    await i18n.changeLanguage("de")

    expect(formatTokenCount(999)).toBe("999")
    expect(formatTokenCount(1500)).toBe("1,5k")
  })
})

describe("primaryButton", () => {
  it("uses semantic brand tokens with the shared primary disabled treatment", () => {
    const className = primaryButton()

    expect(className).toContain("bg-brand")
    expect(className).toContain("text-on-brand")
    expect(className).toContain("hover:opacity-90")
    expect(className).toContain("disabled:cursor-not-allowed")
    expect(className).toContain("disabled:opacity-60")
    expect(className).toBe(buttonClasses("primary", "md", "h-11"))
    expect(className).not.toContain("bg-blue-600")
    expect(className).not.toContain("bg-blue-500")
  })
})

describe("diffLineClass", () => {
  it("uses semantic info tokens for hunk headers", () => {
    const className = diffLineClass("@@ -1,3 +1,3 @@")

    expect(className).toContain("bg-info/10")
    expect(className).toContain("text-info")
    expect(className).not.toMatch(/\b(?:bg|text)-blue-/)
  })
})
