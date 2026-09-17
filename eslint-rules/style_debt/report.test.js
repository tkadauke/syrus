import path from "node:path"
import { describe, expect, it } from "vitest"
import { ROOT, RULE_NAMESPACE, aggregateResults, baselineContent, formatHumanReport, parseArgs, sortedFileCounts } from "./report.js"

const RULES = [
  { key: "raw-status-colors", label: "Raw gray/status color classes" },
  { key: "panel-shell-repeats", label: "Repeated panel shells" }
]

function fakeResult(relativeFile, ruleIds) {
  return {
    filePath: path.join(ROOT, relativeFile),
    messages: ruleIds.map((ruleId) => ({ ruleId, message: "example" }))
  }
}

describe("style_debt/report parseArgs", () => {
  it("defaults to a human report with the default --top", () => {
    expect(parseArgs([])).toEqual({ json: false, writeBaseline: false, top: 15 })
  })

  it("recognizes --json and --write-baseline", () => {
    expect(parseArgs(["--json"])).toMatchObject({ json: true })
    expect(parseArgs(["--write-baseline"])).toMatchObject({ writeBaseline: true })
  })

  it("parses an explicit --top value", () => {
    expect(parseArgs(["--top", "30"])).toMatchObject({ top: 30 })
  })

  it("falls back to the default --top on a non-positive or missing value", () => {
    expect(parseArgs(["--top", "0"])).toMatchObject({ top: 15 })
    expect(parseArgs(["--top", "nope"])).toMatchObject({ top: 15 })
  })

  it("rejects an unrecognized flag", () => {
    expect(() => parseArgs(["--bogus"])).toThrow("Unrecognized argument: --bogus")
  })
})

describe("style_debt/report sortedFileCounts", () => {
  it("sorts by count descending, then file name ascending as a tiebreak", () => {
    const sorted = sortedFileCounts({ "b.tsx": 3, "a.tsx": 3, "c.tsx": 5 })
    expect(sorted).toEqual([
      ["c.tsx", 5],
      ["a.tsx", 3],
      ["b.tsx", 3]
    ])
  })
})

describe("style_debt/report aggregateResults", () => {
  it("counts only style-debt/* messages, grouped by rule key and relative file path", () => {
    const results = [
      fakeResult("app/frontend/routes/A.tsx", [`${RULE_NAMESPACE}/raw-status-colors`, `${RULE_NAMESPACE}/raw-status-colors`]),
      fakeResult("app/frontend/routes/B.tsx", [`${RULE_NAMESPACE}/panel-shell-repeats`, "some-other-plugin/unrelated-rule"])
    ]

    const { counts, totals } = aggregateResults(results, RULES)

    expect(totals).toEqual({ "raw-status-colors": 2, "panel-shell-repeats": 1 })
    expect(counts["raw-status-colors"]).toEqual({ "app/frontend/routes/A.tsx": 2 })
    expect(counts["panel-shell-repeats"]).toEqual({ "app/frontend/routes/B.tsx": 1 })
  })

  it("ignores messages from rules outside the configured rule set", () => {
    const results = [fakeResult("app/frontend/routes/A.tsx", [`${RULE_NAMESPACE}/not-a-known-key`])]
    const { totals } = aggregateResults(results, RULES)
    expect(totals).toEqual({ "raw-status-colors": 0, "panel-shell-repeats": 0 })
  })

  it("returns zeroed totals for a clean result set", () => {
    const { counts, totals } = aggregateResults([fakeResult("app/frontend/routes/Clean.tsx", [])], RULES)
    expect(totals).toEqual({ "raw-status-colors": 0, "panel-shell-repeats": 0 })
    expect(counts).toEqual({ "raw-status-colors": {}, "panel-shell-repeats": {} })
  })
})

describe("style_debt/report baselineContent", () => {
  it("wraps counts/totals with a generated_at timestamp", () => {
    const baseline = baselineContent({ counts: { a: {} }, totals: { a: 0 } })
    expect(baseline.totals).toEqual({ a: 0 })
    expect(baseline.counts).toEqual({ a: {} })
    expect(() => new Date(baseline.generated_at).toISOString()).not.toThrow()
  })
})

describe("style_debt/report formatHumanReport", () => {
  const report = {
    rules: RULES,
    totals: { "raw-status-colors": 2, "panel-shell-repeats": 0 },
    counts: {
      "raw-status-colors": { "app/frontend/routes/A.tsx": 2 },
      "panel-shell-repeats": {}
    }
  }

  it("includes the grand total, per-category totals, and per-file breakdown", () => {
    const text = formatHumanReport(report, null, 15)
    expect(text).toContain("2 flagged occurrence(s) across 2 categories.")
    expect(text).toContain("Raw gray/status color classes (raw-status-colors): 2 in 1 file(s)")
    expect(text).toContain("app/frontend/routes/A.tsx")
    expect(text).toContain("(none)")
    expect(text).toContain("No baseline recorded yet")
  })

  it("shows a vs-baseline delta once a baseline is supplied", () => {
    const baseline = { generated_at: "2026-01-01T00:00:00.000Z", totals: { "raw-status-colors": 5, "panel-shell-repeats": 0 } }
    const text = formatHumanReport(report, baseline, 15)
    expect(text).toContain("[-3 vs baseline]")
    expect(text).toContain("Baseline recorded 2026-01-01T00:00:00.000Z")
  })

  it("truncates the file list to --top and mentions the remainder", () => {
    const manyFiles = { rules: [RULES[0]], totals: { "raw-status-colors": 3 }, counts: { "raw-status-colors": { "a.tsx": 1, "b.tsx": 1, "c.tsx": 1 } } }
    const text = formatHumanReport(manyFiles, null, 2)
    expect(text).toContain("... and 1 more file(s)")
  })
})
