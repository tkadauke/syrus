"use strict"

// Shared plumbing for the enforced design-system ratchet rules under this
// directory. Each rule enforces a *count* baseline per file: `baseline.json`
// records how many violations already existed when the ratchet was
// introduced (or when a rule graduated into it -- see
// config/syrus_docs/style_debt_report.md), and a rule only reports
// occurrences beyond that count. A brand-new file starts at an allowance of
// zero, so any violation in it fails lint immediately. Regenerate the
// baseline with `bin/generate-eslint-baseline` after a follow-up job removes
// violations from a file (shrinking its entry, or dropping it once it hits
// zero) -- see that script for how counts are produced.
//
// The design-system exclusion set (DESIGN_SYSTEM_*, DOCUMENTED_EXCEPTIONS,
// isDesignSystemExcluded) is also reused, unmodified, by the report-only
// style_debt/ rules via style_debt/shared.js, so it only needs to be
// maintained in one place.

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

function isGeneratedFile(relative) {
  return /\.generated\.[jt]sx?$/.test(relative) || /(?:^|\/)__generated__\//.test(relative)
}

// The design system's own implementation defines these low-level class
// strings on purpose -- that's the source of truth the rest of the app
// consumes through semantic primitives, not debt. Shared across every ratchet
// rule (both the enforced ones here and the report-only ones under
// style_debt/) so the exemption list only needs to be maintained once.
const DESIGN_SYSTEM_DIR_PREFIX = "app/frontend/components/ui/"
const DESIGN_SYSTEM_BASENAMES = [
  "Button.tsx",
  "Card.tsx",
  "Checkbox.tsx",
  "Heading.tsx",
  "Input.tsx",
  "Modal.tsx",
  "PanelMessage.tsx",
  "Select.tsx",
  "StatusPill.tsx",
  "Textarea.tsx",
  "Toggle.tsx"
]

// Documented exceptions called out in the epic scan: these render
// user-facing color *pickers*, where a raw color utility is a literal color
// choice being offered to the user, not a design-system styling decision.
const DOCUMENTED_EXCEPTIONS = [
  "app/frontend/components/ImageAnnotationModal.tsx",
  "app/frontend/lib/syntaxHighlight.tsx",
  "app/frontend/routes/Tags.tsx"
]

function isDesignSystemFile(relative) {
  return relative.startsWith(DESIGN_SYSTEM_DIR_PREFIX) || endsWithAny(relative, DESIGN_SYSTEM_BASENAMES)
}

// The standard "not debt" exclusion set a design-system ratchet rule applies
// before looking at a file: test files, generated files, the design system's
// own implementation, and the small documented exception list.
function isDesignSystemExcluded(relative) {
  return isTestFile(relative) || isGeneratedFile(relative) || isDesignSystemFile(relative) || DOCUMENTED_EXCEPTIONS.includes(relative)
}

// Shared by every enforced ratchet rule's `Program:exit`: matches accumulate
// in file order during traversal, and only occurrences beyond the file's
// baselined allowance are reported. `matches` entries are `{ node, ...data }`;
// `data` is passed through to the message as-is.
function reportBeyondBaseline(context, matches, allowed, messageId) {
  for (const { node, ...data } of matches.slice(allowed)) {
    context.report({ node, messageId, data })
  }
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
  isGeneratedFile,
  isDesignSystemFile,
  isDesignSystemExcluded,
  reportBeyondBaseline,
  DESIGN_SYSTEM_DIR_PREFIX,
  DESIGN_SYSTEM_BASENAMES,
  DOCUMENTED_EXCEPTIONS,
  collectStringLiterals,
  classNameCandidates
}
