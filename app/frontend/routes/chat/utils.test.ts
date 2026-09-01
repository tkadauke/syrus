import { describe, expect, it } from "vitest"
import { buttonClasses } from "../../components/Button"
import { primaryButton } from "./utils"

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
