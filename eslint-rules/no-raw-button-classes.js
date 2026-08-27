"use strict"

const { relativePath, allowedCount, isTestFile, endsWithAny, classNameCandidates } = require("./rule-utils")

const RULE_KEY = "no-raw-button-classes"
const EXEMPT_BASENAMES = ["Button.tsx"]
const FORBIDDEN_TAGS = new Set(["button", "a"])

// The duplicated "primary button" class pattern this epic's scan found
// repeated across 51+ files: a bg-(blue|terracotta)-(500|600|700) fill
// combined with text-white, hand-rolled instead of <Button>. Lookaheads so
// order/position of the two fragments within the className string doesn't
// matter.
const PRIMARY_BUTTON_PATTERN = /(?=.*\bbg-(?:blue|terracotta)-(?:500|600|700)\b)(?=.*\btext-white\b)/

// Danger-button look (Button's variant="danger"): a red/rose fill combined
// with text-white, same shape as the primary pattern above but on the
// destructive palette.
const DANGER_BUTTON_PATTERN = /(?=.*\bbg-(?:red|rose)-\d{2,3}\b)(?=.*\btext-white\b)/

// Secondary-button look (Button's variant="secondary"): a bordered,
// white/light-gray fill with gray-700 text -- the hand-rolled shape found
// repeated across the codebase (e.g. the pre-migration ImageAnnotationModal.tsx
// zoom controls) that the original bg-*/text-white-only pattern couldn't see
// because it has no colored fill.
const SECONDARY_BUTTON_PATTERN = /(?=.*\bborder\b)(?=.*\bbg-(?:white|gray-50|gray-100)\b)(?=.*\btext-gray-700\b)/

const BUTTON_PATTERNS = [
  { variant: "primary", pattern: PRIMARY_BUTTON_PATTERN },
  { variant: "danger", pattern: DANGER_BUTTON_PATTERN },
  { variant: "secondary", pattern: SECONDARY_BUTTON_PATTERN }
]

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid the duplicated primary/secondary/danger-button class patterns on raw <button>/<a> elements outside Button.tsx."
    },
    schema: [],
    messages: {
      forbidden: "Use the <Button variant=\"{{variant}}\"> primitive from app/frontend/components/Button.tsx instead of hand-rolling this {{variant}}-button className on <{{tag}}>."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isTestFile(relative) || endsWithAny(relative, EXEMPT_BASENAMES)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        const tag = node.name.type === "JSXIdentifier" ? node.name.name : null
        if (!tag || !FORBIDDEN_TAGS.has(tag)) return
        const candidates = classNameCandidates(node)
        const matched = BUTTON_PATTERNS.find(({ pattern }) => candidates.some(candidate => pattern.test(candidate)))
        if (matched) {
          matches.push({ node, tag, variant: matched.variant })
        }
      },
      "Program:exit"() {
        for (const { node, tag, variant } of matches.slice(allowed)) {
          context.report({ node, messageId: "forbidden", data: { tag, variant } })
        }
      }
    }
  }
}
