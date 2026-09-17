import { describe, expect, it } from "vitest"
import rule from "./no-raw-status-colors.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/RatchetTestFixture.tsx"

describe("no-raw-status-colors", () => {
  it("flags a raw gray class on a JSX element", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="text-gray-500">hi</div>', FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain("text-gray-500")
  })

  it("flags multiple raw status colors on the same element", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="bg-red-100 text-red-700 border-amber-300">hi</div>', FILE)
    expect(messages).toHaveLength(3)
  })

  it("does not flag blue/terracotta -- already tracked by no-legacy-color-tokens", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="bg-blue-600 text-terracotta-700">hi</div>', FILE)
    expect(messages).toHaveLength(0)
  })

  it("does not flag a plain utility class with no color hue", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="flex items-center gap-2">hi</div>', FILE)
    expect(messages).toHaveLength(0)
  })

  it("follows ternary branches for conditional classNames", () => {
    const messages = lintWithRule(rule, 'const x = (active) => <div className={active ? "text-gray-900" : "text-gray-400"}>hi</div>', FILE)
    expect(messages).toHaveLength(2)
  })

  it("skips test files entirely", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="text-gray-500">hi</div>', "app/frontend/routes/RatchetTestFixture.test.tsx")
    expect(messages).toHaveLength(0)
  })

  it("skips the design system's own implementation", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="text-gray-500">hi</div>', "app/frontend/components/ui/Surface.tsx")
    expect(messages).toHaveLength(0)
  })

  it("skips the documented color-picker exception list", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="text-gray-500">hi</div>', "app/frontend/routes/Tags.tsx")
    expect(messages).toHaveLength(0)
  })

  it("suppresses a matched occurrence with a disable-next-line comment", () => {
    const code = [
      "const x = () => (",
      '  // eslint-disable-next-line design-system-test/r -- intentional one-off',
      '  <div className="text-gray-500">hi</div>',
      ")"
    ].join("\n")
    const messages = lintWithRule(rule, code, FILE)
    expect(messages).toHaveLength(0)
  })
})
