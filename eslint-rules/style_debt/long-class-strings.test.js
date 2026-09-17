import { describe, expect, it } from "vitest"
import rule, { LENGTH_THRESHOLD } from "./long-class-strings.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/Example.tsx"

function classNameOfLength(length) {
  // "a " repeated is a harmless run of distinct-looking utility-shaped
  // tokens; length is what the rule checks, not real Tailwind validity.
  return Array.from({ length: Math.ceil(length / 2) }, (_, i) => `a${i % 10}`)
    .join(" ")
    .slice(0, length)
}

describe("style_debt/long-class-strings", () => {
  it("does not flag a className at or under the threshold", () => {
    const className = classNameOfLength(LENGTH_THRESHOLD)
    expect(className).toHaveLength(LENGTH_THRESHOLD)
    const messages = lintWithRule(rule, `const x = () => <div className="${className}">hi</div>`, FILE)
    expect(messages).toHaveLength(0)
  })

  it("flags a className over the threshold", () => {
    const className = classNameOfLength(LENGTH_THRESHOLD + 1)
    const messages = lintWithRule(rule, `const x = () => <div className="${className}">hi</div>`, FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain(String(LENGTH_THRESHOLD + 1))
  })

  it("reports only once per element even with multiple long ternary branches", () => {
    const className = classNameOfLength(LENGTH_THRESHOLD + 10)
    const messages = lintWithRule(rule, `const x = (on) => <div className={on ? "${className}" : "${className}"}>hi</div>`, FILE)
    expect(messages).toHaveLength(1)
  })

  it("skips excluded files entirely", () => {
    const className = classNameOfLength(LENGTH_THRESHOLD + 1)
    const messages = lintWithRule(rule, `const x = () => <div className="${className}">hi</div>`, "app/frontend/routes/Example.test.tsx")
    expect(messages).toHaveLength(0)
  })
})
