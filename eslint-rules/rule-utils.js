"use strict"

// Shared plumbing for the design-system ratchet rules (no-raw-form-elements,
// no-raw-button-classes, no-legacy-color-tokens). Each rule enforces a
// *count* baseline per file: `baseline.json` records how many violations
// already existed when the ratchet was introduced, and a rule only reports
// occurrences beyond that count. A brand-new file starts at an allowance of
// zero, so any violation in it fails lint immediately. Regenerate the
// baseline with `bin/generate-eslint-baseline` after a follow-up job removes
// violations from a file (shrinking its entry, or dropping it once it hits
// zero) -- see that script for how counts are produced.

const fs = require("node:fs")
const path = require("node:path")

const ROOT = path.resolve(__dirname, "..")
const BASELINE_PATH = path.join(__dirname, "baseline.json")

let cachedBaseline = null

function loadBaseline() {
  if (!cachedBaseline) {
    cachedBaseline = JSON.parse(fs.readFileSync(BASELINE_PATH, "utf8"))
  }
  return cachedBaseline
}

function relativePath(filename) {
  return path.relative(ROOT, filename).split(path.sep).join("/")
}

// bin/generate-eslint-baseline sets this so every rule reports every
// occurrence (ignoring the on-disk baseline) while it recomputes counts.
function allowedCount(ruleKey, relative) {
  if (process.env.ESLINT_BASELINE_GENERATE === "1") return 0
  return loadBaseline()[ruleKey]?.[relative] ?? 0
}

function isTestFile(relative) {
  return /\.test\.tsx?$/.test(relative)
}

function endsWithAny(relative, basenames) {
  return basenames.some(basename => relative.endsWith(`/${basename}`) || relative === basename)
}

// Collects every string a JSX className/class attribute could resolve to at
// runtime, walking template literals and the branches of ternaries/logical
// expressions. Not exhaustive (arbitrary function calls aren't followed) but
// covers the patterns these rules care about, matching the low-false-positive
// intent of a plain AST/string check.
function collectStringLiterals(node, out = []) {
  if (!node) return out
  switch (node.type) {
    case "Literal":
      if (typeof node.value === "string") out.push(node.value)
      break
    case "TemplateLiteral":
      for (const quasi of node.quasis) out.push(quasi.value.cooked ?? quasi.value.raw)
      for (const expression of node.expressions) collectStringLiterals(expression, out)
      break
    case "ConditionalExpression":
      collectStringLiterals(node.consequent, out)
      collectStringLiterals(node.alternate, out)
      break
    case "LogicalExpression":
      collectStringLiterals(node.left, out)
      collectStringLiterals(node.right, out)
      break
    case "JSXExpressionContainer":
      collectStringLiterals(node.expression, out)
      break
    default:
      break
  }
  return out
}

function classNameCandidates(jsxOpeningElement) {
  const attribute = jsxOpeningElement.attributes.find(
    attr => attr.type === "JSXAttribute" && attr.name && (attr.name.name === "className" || attr.name.name === "class")
  )
  if (!attribute || !attribute.value) return []
  if (attribute.value.type === "Literal" && typeof attribute.value.value === "string") return [attribute.value.value]
  if (attribute.value.type === "JSXExpressionContainer") return collectStringLiterals(attribute.value.expression)
  return []
}

module.exports = {
  ROOT,
  BASELINE_PATH,
  relativePath,
  allowedCount,
  isTestFile,
  endsWithAny,
  collectStringLiterals,
  classNameCandidates
}
