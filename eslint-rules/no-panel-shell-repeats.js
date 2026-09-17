"use strict"

const { relativePath, allowedCount, isDesignSystemExcluded, classNameCandidates, reportBeyondBaseline } = require("./rule-utils")

const RULE_KEY = "no-panel-shell-repeats"

// The hand-rolled "panel" look Surface/Card already provide: a rounded,
// bordered box with a white/near-white fill. Lookaheads so fragment order
// within the className string doesn't matter.
const PANEL_SHELL_PATTERN = /(?=.*\brounded(?:-\w+)?\b)(?=.*\bborder(?:-\w+)?\b)(?=.*\bbg-(?:white|gray-50|gray-100)\b)/

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid new hand-rolled rounded/border/bg-white panel shells that duplicate the Surface/Card primitives."
    },
    schema: [],
    messages: {
      forbidden: "Hand-rolled panel shell (rounded + border + bg-white/gray-50/gray-100) -- use the Surface or Card primitive instead."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isDesignSystemExcluded(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        const matched = classNameCandidates(node).some(candidate => PANEL_SHELL_PATTERN.test(candidate))
        if (matched) matches.push({ node })
      },
      "Program:exit"() {
        reportBeyondBaseline(context, matches, allowed, "forbidden")
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
