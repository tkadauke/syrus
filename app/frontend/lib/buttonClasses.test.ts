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

  it("matches the shared Button md control height for every tone", () => {
    for (const tone of ["primary", "secondary", "success", "danger", "danger-outline"] as const) {
      const className = buttonClass(tone)
      expect(className).toContain("h-[var(--control-height-md)]")
      expect(className).not.toContain("py-1.5")
    }
  })
})
