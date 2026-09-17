"use strict"

const { relativePath, isExcluded, classNameCandidates } = require("./shared")

const RULE_KEY = "panel-shell-repeats"

// The hand-rolled "panel" look Surface/Card already provide: a rounded,
// bordered box with a white/near-white fill. Lookaheads so fragment order
// within the className string doesn't matter.
const PANEL_SHELL_PATTERN = /(?=.*\brounded(?:-\w+)?\b)(?=.*\bborder(?:-\w+)?\b)(?=.*\bbg-(?:white|gray-50|gray-100)\b)/

module.exports = {
  meta: {
    type: "suggestion",
    docs: {
      description: "Report-only: counts hand-rolled rounded/border/bg-white panel shells that duplicate the Surface/Card primitives."
    },
    schema: [],
    messages: {
      found: "Hand-rolled panel shell (rounded + border + bg-white/gray-50/gray-100) -- consider Surface or Card."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isExcluded(relative)) return {}

    return {
      JSXOpeningElement(node) {
        const matched = classNameCandidates(node).some((candidate) => PANEL_SHELL_PATTERN.test(candidate))
        if (matched) context.report({ node, messageId: "found" })
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
