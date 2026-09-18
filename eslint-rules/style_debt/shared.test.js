import { describe, expect, it } from "vitest"
import shared from "./shared.js"

describe("style_debt/shared isExcluded", () => {
  it("excludes test files", () => {
    expect(shared.isExcluded("app/frontend/routes/JobDetail.test.tsx")).toBe(true)
  })

  it("excludes generated files", () => {
    expect(shared.isExcluded("app/frontend/lib/brandTokens.generated.ts")).toBe(true)
    expect(shared.isExcluded("app/frontend/__generated__/api.ts")).toBe(true)
  })

  it("excludes the design system's own ui/ implementation directory", () => {
    expect(shared.isExcluded("app/frontend/components/ui/Surface.tsx")).toBe(true)
  })

  it("excludes design system leaf components living outside ui/", () => {
    expect(shared.isExcluded("app/frontend/components/Button.tsx")).toBe(true)
    expect(shared.isExcluded("app/frontend/components/StatusPill.tsx")).toBe(true)
  })

  it("excludes any file ending in a design-system leaf basename, same as the enforced ratchet's own EXEMPT_BASENAMES convention", () => {
    // endsWithAny (shared with eslint-rules/rule-utils.js) matches by
    // basename, not full path -- deliberately consistent with how the
    // enforced no-legacy-color-tokens rule already exempts these files.
    expect(shared.isExcluded("app/frontend/routes/chat/Button.tsx")).toBe(true)
  })

  it("excludes the documented domain-specific color-picker exceptions", () => {
    expect(shared.isExcluded("app/frontend/routes/Tags.tsx")).toBe(true)
  })

  it("does not exclude an ordinary product file", () => {
    expect(shared.isExcluded("app/frontend/routes/JobDetail.tsx")).toBe(false)
    expect(shared.isExcluded("plugins/admin_mysql/app/frontend/routes/AdminMysql.tsx")).toBe(false)
  })
})
