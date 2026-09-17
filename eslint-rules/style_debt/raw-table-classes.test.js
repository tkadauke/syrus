import { describe, expect, it } from "vitest"
import rule from "./raw-table-classes.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/Example.tsx"

describe("style_debt/raw-table-classes", () => {
  it("flags a raw <td>", () => {
    const messages = lintWithRule(rule, 'const x = () => <table><tbody><tr><td className="px-2 py-1">hi</td></tr></tbody></table>', FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain("<td>")
  })

  it("flags a raw <th>", () => {
    const messages = lintWithRule(rule, "const x = () => <table><thead><tr><th>hi</th></tr></thead></table>", FILE)
    expect(messages).toHaveLength(1)
    expect(messages[0].message).toContain("<th>")
  })

  it("does not flag <tr> or <table> -- only cell/header elements", () => {
    const messages = lintWithRule(rule, "const x = () => <table><tbody><tr /></tbody></table>", FILE)
    expect(messages).toHaveLength(0)
  })

  it("skips the DataTable primitive implementation itself", () => {
    const messages = lintWithRule(rule, "const x = () => <td>hi</td>", "app/frontend/components/ui/DataTable.tsx")
    expect(messages).toHaveLength(0)
  })
})
