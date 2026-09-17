import { describe, expect, it, vi } from "vitest"
import { allowedCount, isDesignSystemExcluded, isDesignSystemFile, isGeneratedFile, reportBeyondBaseline } from "./rule-utils.js"

describe("rule-utils isGeneratedFile", () => {
  it("flags .generated. files and __generated__ directories", () => {
    expect(isGeneratedFile("app/frontend/lib/brandTokens.generated.ts")).toBe(true)
    expect(isGeneratedFile("app/frontend/__generated__/api.ts")).toBe(true)
  })

  it("does not flag an ordinary file", () => {
    expect(isGeneratedFile("app/frontend/routes/JobDetail.tsx")).toBe(false)
  })
})

describe("rule-utils isDesignSystemFile", () => {
  it("matches the ui/ implementation directory", () => {
    expect(isDesignSystemFile("app/frontend/components/ui/Surface.tsx")).toBe(true)
  })

  it("matches a design-system leaf component by basename anywhere", () => {
    expect(isDesignSystemFile("app/frontend/components/Button.tsx")).toBe(true)
    expect(isDesignSystemFile("app/frontend/routes/chat/Button.tsx")).toBe(true)
  })

  it("does not match an ordinary product file", () => {
    expect(isDesignSystemFile("app/frontend/routes/JobDetail.tsx")).toBe(false)
  })
})

describe("rule-utils isDesignSystemExcluded", () => {
  it("excludes test files, generated files, design-system files, and documented exceptions", () => {
    expect(isDesignSystemExcluded("app/frontend/routes/JobDetail.test.tsx")).toBe(true)
    expect(isDesignSystemExcluded("app/frontend/lib/brandTokens.generated.ts")).toBe(true)
    expect(isDesignSystemExcluded("app/frontend/components/ui/Surface.tsx")).toBe(true)
    expect(isDesignSystemExcluded("app/frontend/routes/Tags.tsx")).toBe(true)
  })

  it("does not exclude an ordinary product or plugin file", () => {
    expect(isDesignSystemExcluded("app/frontend/routes/JobDetail.tsx")).toBe(false)
    expect(isDesignSystemExcluded("plugins/admin_mysql/app/frontend/routes/AdminMysql.tsx")).toBe(false)
  })
})

describe("rule-utils allowedCount", () => {
  it("returns zero for a rule/file pair with no baseline entry", () => {
    expect(allowedCount("no-raw-status-colors", "app/frontend/routes/RatchetTestFixtureDoesNotExist.tsx")).toBe(0)
  })

  it("reads a real, positive allowance from the checked-in baseline for a known entry", () => {
    // Whatever this file's current no-raw-button-classes baseline entry is,
    // it should be a positive number read straight from baseline.json --
    // not hardcoded here. If a future migration job shrinks this file's
    // count, regenerate the baseline (bin/generate-eslint-baseline) and this
    // assertion should be updated to match, same as any other baseline
    // consumer.
    const allowed = allowedCount("no-raw-button-classes", "plugins/mysql_db_browser/app/frontend/routes/MysqlConnections.tsx")
    expect(allowed).toBeGreaterThan(0)
  })

  it("forces zero regardless of baseline while ESLINT_BASELINE_GENERATE=1", () => {
    const original = process.env.ESLINT_BASELINE_GENERATE
    process.env.ESLINT_BASELINE_GENERATE = "1"
    try {
      expect(allowedCount("no-raw-button-classes", "plugins/mysql_db_browser/app/frontend/routes/MysqlConnections.tsx")).toBe(0)
    } finally {
      if (original === undefined) delete process.env.ESLINT_BASELINE_GENERATE
      else process.env.ESLINT_BASELINE_GENERATE = original
    }
  })
})

describe("rule-utils reportBeyondBaseline", () => {
  function fakeContext() {
    return { report: vi.fn() }
  }

  it("reports nothing when every match is within the allowance", () => {
    const context = fakeContext()
    const matches = [
      { node: "a", token: "x" },
      { node: "b", token: "y" }
    ]
    reportBeyondBaseline(context, matches, 2, "forbidden")
    expect(context.report).not.toHaveBeenCalled()
  })

  it("reports only matches beyond the allowance, preserving their data", () => {
    const context = fakeContext()
    const matches = [
      { node: "a", token: "x" },
      { node: "b", token: "y" },
      { node: "c", token: "z" }
    ]
    reportBeyondBaseline(context, matches, 1, "forbidden")
    expect(context.report).toHaveBeenCalledTimes(2)
    expect(context.report).toHaveBeenNthCalledWith(1, { node: "b", messageId: "forbidden", data: { token: "y" } })
    expect(context.report).toHaveBeenNthCalledWith(2, { node: "c", messageId: "forbidden", data: { token: "z" } })
  })

  it("reports every match when the allowance is zero", () => {
    const context = fakeContext()
    const matches = [{ node: "a" }]
    reportBeyondBaseline(context, matches, 0, "forbidden")
    expect(context.report).toHaveBeenCalledTimes(1)
    expect(context.report).toHaveBeenCalledWith({ node: "a", messageId: "forbidden", data: {} })
  })
})
