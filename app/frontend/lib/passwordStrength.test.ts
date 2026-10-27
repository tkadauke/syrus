import { describe, expect, it } from "vitest"
import { passwordStrength } from "./passwordStrength"

describe("passwordStrength", () => {
  it("is empty for an empty password", () => {
    expect(passwordStrength("")).toEqual({ bits: 0, score: 0 })
  })

  it("rates short or single-class passwords weak", () => {
    expect(passwordStrength("cat").score).toBe(1)
    expect(passwordStrength("1234567").score).toBe(1)
  })

  it("does not reward repeated characters", () => {
    // 16 chars of one letter must not read as strong.
    expect(passwordStrength("aaaaaaaaaaaaaaaa").score).toBe(1)
  })

  it("climbs through fair and good as length and classes grow", () => {
    expect(passwordStrength("otter12").score).toBe(2)
    expect(passwordStrength("blueotter123").score).toBe(3)
  })

  it("rates long multi-class passphrases strong", () => {
    expect(passwordStrength("Blue-Otter!Yodels@Dawn7").score).toBe(4)
    expect(passwordStrength("correct horse battery staple").score).toBe(4)
  })
})
