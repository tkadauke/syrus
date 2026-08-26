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
const DUPLICATED_BUTTON_PATTERN = /(?=.*\bbg-(?:blue|terracotta)-(?:500|600|700)\b)(?=.*\btext-white\b)/

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid the duplicated primary-button class pattern on raw <button>/<a> elements outside Button.tsx."
    },
    schema: [],
    messages: {
      forbidden: "Use the <Button> primitive from app/frontend/components/Button.tsx instead of hand-rolling this primary-button className on <{{tag}}>."
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
        if (candidates.some(candidate => DUPLICATED_BUTTON_PATTERN.test(candidate))) {
          matches.push({ node, tag })
        }
      },
      "Program:exit"() {
        for (const { node, tag } of matches.slice(allowed)) {
          context.report({ node, messageId: "forbidden", data: { tag } })
        }
      }
    }
  }
}
