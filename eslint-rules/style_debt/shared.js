"use strict"

// Shared plumbing for the DOC-27 style-debt *reporting* rules under this
// directory. Unlike the enforced ratchet rules in eslint-rules/ (which fail
// lint beyond a per-file baseline), these rules always report every match --
// bin/style-debt-report aggregates their output into counts instead of
// gating CI. See config/syrus_docs/style_debt_report.md.

const { relativePath, isTestFile, endsWithAny, collectStringLiterals, classNameCandidates } = require("../rule-utils")

// The design system's own implementation defines these low-level class
// strings on purpose -- that's the source of truth the rest of the app
// consumes through semantic primitives, not debt.
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

// Same documented exceptions the no-legacy-color-tokens ratchet rule
// exempts: these render user-facing color *pickers*, where a raw color
// utility is a literal choice offered to the user, not a styling decision.
const DOCUMENTED_EXCEPTIONS = ["app/frontend/components/ImageAnnotationModal.tsx", "app/frontend/lib/syntaxHighlight.tsx", "app/frontend/routes/Tags.tsx"]

function isDesignSystemFile(relative) {
  return relative.startsWith(DESIGN_SYSTEM_DIR_PREFIX) || endsWithAny(relative, DESIGN_SYSTEM_BASENAMES)
}

function isGeneratedFile(relative) {
  return /\.generated\.[jt]sx?$/.test(relative) || /(?:^|\/)__generated__\//.test(relative)
}

// Applied by every style-debt rule before it looks at a file. Test files,
// generated files, the design system's own implementation, and the small
// documented exception list are all "not debt" for the purposes of this
// report, same categories the issue that introduced this reporter calls out.
function isExcluded(relative) {
  return isTestFile(relative) || isGeneratedFile(relative) || isDesignSystemFile(relative) || DOCUMENTED_EXCEPTIONS.includes(relative)
}

module.exports = {
  DESIGN_SYSTEM_DIR_PREFIX,
  DESIGN_SYSTEM_BASENAMES,
  DOCUMENTED_EXCEPTIONS,
  isExcluded,
  relativePath,
  collectStringLiterals,
  classNameCandidates
}
