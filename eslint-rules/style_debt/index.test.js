import { describe, expect, it } from "vitest"
import { RULES } from "./index.js"

describe("style_debt/index", () => {
  it("exposes one entry per report rule with a unique key and a working create()", () => {
    expect(RULES.length).toBe(5)
    const keys = RULES.map(({ key }) => key)
    expect(new Set(keys).size).toBe(keys.length)
    for (const { key, rule, label } of RULES) {
      expect(typeof key).toBe("string")
      expect(typeof label).toBe("string")
      expect(typeof rule.create).toBe("function")
      expect(rule.meta?.messages).toBeTruthy()
    }
  })
})
