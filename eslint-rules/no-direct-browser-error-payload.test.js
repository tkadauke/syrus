import { describe, expect, it } from "vitest"
import rule from "./no-direct-browser-error-payload.js"
import { lintWithRule } from "./test-helpers.js"

describe("no-direct-browser-error-payload", () => {
  it("rejects bespoke payload construction in a product surface", () => {
    const messages = lintWithRule(
      rule,
      "const payload = buildBrowserErrorPayload(error, { boundary: 'feature' })",
      "app/frontend/routes/BrowserErrorPayloadFixture.tsx"
    )
    expect(messages).toHaveLength(1)
  })

  it("rejects aliased and namespace payload builders", () => {
    const aliased = lintWithRule(
      rule,
      `import { buildBrowserErrorPayload as buildPayload } from "../../api/browserErrors"\nbuildPayload(error, options)`,
      "app/frontend/routes/AliasedBrowserErrorPayloadFixture.tsx"
    )
    const namespaced = lintWithRule(
      rule,
      `import * as browserErrors from "../../api/browserErrors"\nbrowserErrors.buildBrowserErrorPayload(error, options)`,
      "app/frontend/routes/NamespacedBrowserErrorPayloadFixture.tsx"
    )

    expect(aliased).toHaveLength(1)
    expect(namespaced).toHaveLength(1)
  })

  it("allows the shared infrastructure to construct payloads", () => {
    const messages = lintWithRule(rule, "const payload = buildBrowserErrorPayload(error, options)", "app/frontend/lib/handledErrorReporting.ts")
    expect(messages).toHaveLength(0)
  })
})
