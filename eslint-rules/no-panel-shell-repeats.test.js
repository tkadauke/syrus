import { describe, expect, it } from "vitest"
import rule from "./no-panel-shell-repeats.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/RatchetTestFixture.tsx"

describe("no-panel-shell-repeats", () => {
  it("flags rounded + border + bg-white combined on one element", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded border bg-white p-4">hi</div>', FILE)
    expect(messages).toHaveLength(1)
  })

  it("flags the bg-gray-50/bg-gray-100 shell variants too", () => {
    expect(lintWithRule(rule, 'const x = () => <div className="rounded-lg border bg-gray-50">hi</div>', FILE)).toHaveLength(1)
    expect(lintWithRule(rule, 'const x = () => <div className="rounded border-2 bg-gray-100">hi</div>', FILE)).toHaveLength(1)
  })

  it("does not flag a fill without rounded/border", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="bg-white p-4">hi</div>', FILE)
    expect(messages).toHaveLength(0)
  })

  it("does not flag a rounded+border shape with a non-panel fill", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded border bg-brand">hi</div>', FILE)
    expect(messages).toHaveLength(0)
  })

  it("matches regardless of fragment order in the className string", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="bg-white p-4 border rounded">hi</div>', FILE)
    expect(messages).toHaveLength(1)
  })

  it("skips the design system's own implementation", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded border bg-white">hi</div>', "app/frontend/components/Card.tsx")
    expect(messages).toHaveLength(0)
  })
})
