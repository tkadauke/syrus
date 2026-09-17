import { describe, expect, it } from "vitest"
import rule, { SUBSTANTIAL_ELEMENT_THRESHOLD } from "./plugin-ui-imports.js"
import { lintWithRule } from "./test-helpers.js"

const PLUGIN_FILE = "plugins/example_plugin/app/frontend/routes/Example.tsx"
const CORE_FILE = "app/frontend/routes/Example.tsx"

// Wraps in a fragment (not a <div>) so the emitted JSXOpeningElement count
// is exactly `count` -- a fragment compiles to JSXOpeningFragment, a
// distinct node type the rule doesn't count.
function jsxWithElementCount(count) {
  const children = Array.from({ length: count }, (_, i) => `<span key={${i}}>${i}</span>`).join("")
  return `const x = () => <>${children}</>`
}

describe("style_debt/plugin-ui-imports", () => {
  it("flags a plugin file with substantial JSX and no @app/components import", () => {
    const code = jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD)
    const messages = lintWithRule(rule, code, PLUGIN_FILE)
    expect(messages).toHaveLength(1)
  })

  it("does not flag a plugin file that imports from the design system", () => {
    const code = `import { Button } from "@app/components/ui"\n${jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD)}`
    const messages = lintWithRule(rule, code, PLUGIN_FILE)
    expect(messages).toHaveLength(0)
  })

  it("does not flag a plugin file that imports a direct component path", () => {
    const code = `import { Button } from "@app/components/Button"\n${jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD)}`
    const messages = lintWithRule(rule, code, PLUGIN_FILE)
    expect(messages).toHaveLength(0)
  })

  it("does not flag a small plugin file below the substantial-UI threshold", () => {
    const code = jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD - 1)
    const messages = lintWithRule(rule, code, PLUGIN_FILE)
    expect(messages).toHaveLength(0)
  })

  it("never evaluates core (non-plugin) files", () => {
    const code = jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD)
    const messages = lintWithRule(rule, code, CORE_FILE)
    expect(messages).toHaveLength(0)
  })

  it("skips excluded plugin test files", () => {
    const code = jsxWithElementCount(SUBSTANTIAL_ELEMENT_THRESHOLD)
    const messages = lintWithRule(rule, code, "plugins/example_plugin/app/frontend/routes/Example.test.tsx")
    expect(messages).toHaveLength(0)
  })
})
