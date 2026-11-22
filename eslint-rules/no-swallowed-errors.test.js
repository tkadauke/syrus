import { describe, expect, it } from "vitest"
import rule from "./no-swallowed-errors.js"
import { lintWithRule } from "./test-helpers.js"

const FILE = "app/frontend/routes/HandledErrorRatchetFixture.tsx"

describe("no-swallowed-errors", () => {
  it("flags silent catch clauses and promise rejection handlers", () => {
    const messages = lintWithRule(
      rule,
      `
      async function save() { try { await work() } catch { setError("failed") } }
      work().catch(() => setError("failed"))
      work().catch((error) => console.warn(error))
    `,
      FILE
    )
    expect(messages).toHaveLength(3)
  })

  it("accepts shared reporting, rethrows, and the documented control-flow escape hatch", () => {
    const messages = lintWithRule(
      rule,
      `
      async function reported() { try { await work() } catch (error) { reportHandledError(error, context) } }
      async function rethrown() { try { await work() } catch (error) { throw error } }
      work().catch(() => { /* handled-error-expected: optional cleanup */ })
    `,
      FILE
    )
    expect(messages).toHaveLength(0)
  })

  it("does not treat unexecuted nested handlers as handling the failure", () => {
    const messages = lintWithRule(
      rule,
      `
      async function deferredReport() {
        try { await work() } catch (error) {
          const later = () => reportHandledError(error, context)
          setError("failed")
        }
      }
      async function deferredThrow() {
        try { await work() } catch (error) {
          function later() { throw error }
          setError("failed")
        }
      }
    `,
      FILE
    )
    expect(messages).toHaveLength(2)
  })
})
