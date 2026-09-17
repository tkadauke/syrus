import { describe, expect, it } from "vitest"
import rule from "./no-raw-table-classes.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/RatchetTestFixture.tsx"

describe("no-raw-table-classes", () => {
  it("flags a raw <td>", () => {
    const messages = lintWithRule(rule, 'const x = () => <table><tbody><tr><td className="px-2">hi</td></tr></tbody></table>', FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain("<td>")
  })

  it("flags a raw <th>", () => {
    const messages = lintWithRule(rule, "const x = () => <table><thead><tr><th>hi</th></tr></thead></table>", FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain("<th>")
  })

  it("does not flag <table>/<tr>/<tbody> themselves", () => {
    const messages = lintWithRule(rule, "const x = () => <table><tbody><tr></tr></tbody></table>", FILE)
    expect(messages).toHaveLength(0)
  })

  it("skips the design system's own implementation", () => {
    const messages = lintWithRule(rule, "const x = () => <td>hi</td>", "app/frontend/components/ui/DataTable.tsx")
    expect(messages).toHaveLength(0)
  })
})
