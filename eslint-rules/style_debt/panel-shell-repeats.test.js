import { describe, expect, it } from "vitest"
import rule from "./panel-shell-repeats.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/Example.tsx"

describe("style_debt/panel-shell-repeats", () => {
  it("flags a rounded/border/bg-white panel shell", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded-lg border bg-white p-4">hi</div>', FILE)
    expect(messages).toHaveLength(1)
  })

  it("flags the bg-gray-50 and bg-gray-100 variants too", () => {
    expect(lintWithRule(rule, 'const x = () => <div className="rounded border bg-gray-50">hi</div>', FILE)).toHaveLength(1)
    expect(lintWithRule(rule, 'const x = () => <div className="rounded border bg-gray-100">hi</div>', FILE)).toHaveLength(1)
  })

  it("does not flag when only two of the three ingredients are present", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded border">hi</div>', FILE)
    expect(messages).toHaveLength(0)
  })

  it("only reports once per element even if the pattern is visually redundant", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded-xl border-2 bg-white shadow">hi</div>', FILE)
    expect(messages).toHaveLength(1)
  })

  it("skips excluded files entirely", () => {
    const messages = lintWithRule(rule, 'const x = () => <div className="rounded border bg-white">hi</div>', "app/frontend/components/ui/Surface.tsx")
    expect(messages).toHaveLength(0)
  })
})
