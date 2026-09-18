import { describe, expect, it } from "vitest"
import rule, { LENGTH_THRESHOLD } from "./no-long-class-strings.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/RatchetTestFixture.tsx"

describe("no-long-class-strings", () => {
  it("flags a className longer than the threshold", () => {
    const long = "a".repeat(LENGTH_THRESHOLD + 1)
    const messages = lintWithRule(rule, `const x = () => <div className="${long}">hi</div>`, FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain(String(long.length))
  })

  it("does not flag a className at or under the threshold", () => {
    const atThreshold = "a".repeat(LENGTH_THRESHOLD)
    const messages = lintWithRule(rule, `const x = () => <div className="${atThreshold}">hi</div>`, FILE)
    expect(messages).toHaveLength(0)
  })

  it("skips the design system's own implementation", () => {
    const long = "a".repeat(LENGTH_THRESHOLD + 1)
    const messages = lintWithRule(rule, `const x = () => <div className="${long}">hi</div>`, "app/frontend/components/Button.tsx")
    expect(messages).toHaveLength(0)
  })
})
