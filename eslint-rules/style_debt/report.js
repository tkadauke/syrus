"use strict"

// Library behind bin/style-debt-report, split out so its formatting/aggregation
// logic is unit-testable without shelling out or touching the real
// app/frontend tree. See that script's header comment for usage, and
// config/syrus_docs/style_debt_report.md for the feature writeup.

const fs = require("node:fs")
const path = require("node:path")

const ROOT = path.resolve(__dirname, "..", "..")
const BASELINE_PATH = path.join(ROOT, "eslint-rules", "style_debt", "baseline.json")
const LINT_GLOBS = ["app/frontend/**/*.{ts,tsx}", "plugins/*/app/frontend/**/*.{ts,tsx}"]
const RULE_NAMESPACE = "style-debt"
const DEFAULT_TOP = 15

function parseArgs(argv) {
  const options = { json: false, writeBaseline: false, top: DEFAULT_TOP }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === "--json") options.json = true
    else if (arg === "--write-baseline") options.writeBaseline = true
    else if (arg === "--top") {
      options.top = Number.parseInt(argv[i + 1], 10)
      i += 1
    } else {
      throw new Error(`Unrecognized argument: ${arg}`)
    }
  }
  if (!Number.isInteger(options.top) || options.top <= 0) options.top = DEFAULT_TOP
  return options
}

async function computeReport() {
  const { ESLint } = require("eslint")
  const tsParser = require("@typescript-eslint/parser")
  const { RULES } = require("./index")

  const plugins = { [RULE_NAMESPACE]: { rules: {} } }
  const rules = {}
  for (const { key, rule } of RULES) {
    plugins[RULE_NAMESPACE].rules[key] = rule
    rules[`${RULE_NAMESPACE}/${key}`] = "warn"
  }

  const eslint = new ESLint({
    cwd: ROOT,
    overrideConfigFile: true,
    overrideConfig: [
      {
        files: ["**/*.{ts,tsx}"],
        languageOptions: {
          parser: tsParser,
          parserOptions: { ecmaFeatures: { jsx: true }, sourceType: "module" }
        },
        plugins,
        rules
      }
    ]
  })

  const results = await eslint.lintFiles(LINT_GLOBS)
  return aggregateResults(results, RULES)
}

// Split out from computeReport so the aggregation logic (the part with
// actual branching to test) can be exercised with synthetic ESLint results
// instead of a real lintFiles() pass over the checkout.
function aggregateResults(results, rules) {
  const counts = {}
  const totals = {}
  for (const { key } of rules) {
    counts[key] = {}
    totals[key] = 0
  }

  for (const result of results) {
    const relative = path.relative(ROOT, result.filePath).split(path.sep).join("/")
    for (const message of result.messages) {
      if (!message.ruleId || !message.ruleId.startsWith(`${RULE_NAMESPACE}/`)) continue
      const key = message.ruleId.slice(RULE_NAMESPACE.length + 1)
      if (!(key in counts)) continue
      counts[key][relative] = (counts[key][relative] ?? 0) + 1
      totals[key] += 1
    }
  }

  return { counts, totals, rules }
}

function sortedFileCounts(fileCounts) {
  return Object.entries(fileCounts).sort(([fileA, countA], [fileB, countB]) => countB - countA || fileA.localeCompare(fileB))
}

function loadBaseline() {
  if (!fs.existsSync(BASELINE_PATH)) return null
  return JSON.parse(fs.readFileSync(BASELINE_PATH, "utf8"))
}

function baselineContent({ counts, totals }) {
  return { generated_at: new Date().toISOString(), totals, counts }
}

function writeBaseline(report) {
  const baseline = baselineContent(report)
  fs.writeFileSync(BASELINE_PATH, `${JSON.stringify(baseline, null, 2)}\n`)
  return baseline
}

function formatHumanReport({ counts, totals, rules }, baseline, top) {
  const lines = []
  const grandTotal = Object.values(totals).reduce((sum, n) => sum + n, 0)
  lines.push("DOC-27 style-debt report")
  lines.push(`${grandTotal} flagged occurrence(s) across ${rules.length} categor${rules.length === 1 ? "y" : "ies"}.`)
  lines.push("")

  for (const { key, label } of rules) {
    const fileCounts = sortedFileCounts(counts[key])
    const total = totals[key]
    const baselineTotal = baseline?.totals?.[key]
    const delta = typeof baselineTotal === "number" ? total - baselineTotal : null

    let headline = `${label} (${key}): ${total} in ${fileCounts.length} file(s)`
    if (delta !== null) {
      const sign = delta > 0 ? "+" : ""
      headline += ` [${sign}${delta} vs baseline]`
    }
    lines.push(headline)

    if (fileCounts.length === 0) {
      lines.push("  (none)")
    } else {
      for (const [file, count] of fileCounts.slice(0, top)) {
        lines.push(`  ${count.toString().padStart(4)}  ${file}`)
      }
      if (fileCounts.length > top) {
        lines.push(`  ... and ${fileCounts.length - top} more file(s). Run with --top ${fileCounts.length} to see all, or --json for full output.`)
      }
    }
    lines.push("")
  }

  if (!baseline) {
    lines.push("No baseline recorded yet -- run `bin/style-debt-report --write-baseline` to establish one for future comparisons.")
  } else {
    lines.push(
      `Baseline recorded ${baseline.generated_at}. Run \`bin/style-debt-report --write-baseline\` after this report changes on purpose (e.g. a migration job shrinks a category).`
    )
  }

  return lines.join("\n")
}

async function main(argv) {
  const options = parseArgs(argv)
  const report = await computeReport()

  if (options.writeBaseline) {
    const baseline = writeBaseline(report)
    console.log(`[style-debt-report] wrote ${BASELINE_PATH}`)
    if (options.json) console.log(JSON.stringify(baseline, null, 2))
    return
  }

  if (options.json) {
    console.log(JSON.stringify(baselineContent(report), null, 2))
    return
  }

  console.log(formatHumanReport(report, loadBaseline(), options.top))
}

module.exports = {
  ROOT,
  BASELINE_PATH,
  LINT_GLOBS,
  RULE_NAMESPACE,
  parseArgs,
  computeReport,
  aggregateResults,
  sortedFileCounts,
  loadBaseline,
  writeBaseline,
  baselineContent,
  formatHumanReport,
  main
}
