"use strict"

const { relativePath, allowedCount, isTestFile, endsWithAny, classNameCandidates } = require("./rule-utils")

const RULE_KEY = "no-legacy-color-tokens"

// The design-system primitives themselves still define the palette in terms
// of blue-*/terracotta-* utilities (and remap `blue` onto the terracotta
// scale in config/tailwind.config.js, outside app/frontend entirely) -- that
// is the source of truth the semantic tokens are built from, not debt.
const EXEMPT_BASENAMES = ["Button.tsx", "Card.tsx", "Input.tsx", "Select.tsx", "Modal.tsx", "Checkbox.tsx", "Toggle.tsx"]

// Documented exceptions called out in the epic scan: these render
// user-facing color *pickers*, where "blue" is a literal color choice being
// offered to the user, not a design-system styling decision.
const EXEMPT_FILES = ["app/frontend/components/ImageAnnotationModal.tsx", "app/frontend/routes/Tags.tsx"]

// Scoped to className/class only (never SVG presentation attributes like
// fill/stroke, and never plain-JS objects like the xterm theme config in
// Terminal.tsx) via classNameCandidates -- so those documented exceptions
// are excluded by construction rather than by file-listing them.
const LEGACY_TOKEN_PATTERN = /\b(?:blue|terracotta)-\d{2,3}\b/

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid new blue-*/terracotta-* Tailwind utility usage in frontend routes and components; use the semantic color tokens instead."
    },
    schema: [],
    messages: {
      forbidden: "Use a semantic color token (e.g. bg-brand, text-text-secondary, border-border) instead of the legacy \"{{token}}\" utility."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isTestFile(relative) || endsWithAny(relative, EXEMPT_BASENAMES) || EXEMPT_FILES.includes(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        for (const candidate of classNameCandidates(node)) {
          const match = candidate.match(LEGACY_TOKEN_PATTERN)
          if (match) {
            matches.push({ node, token: match[0] })
            return
          }
        }
      },
      "Program:exit"() {
        for (const { node, token } of matches.slice(allowed)) {
          context.report({ node, messageId: "forbidden", data: { token } })
        }
      }
    }
  }
}
