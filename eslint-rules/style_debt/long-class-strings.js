"use strict"

const { relativePath, isExcluded, classNameCandidates } = require("./shared")

const RULE_KEY = "long-class-strings"

// A className string this long is almost always restating several design
// decisions (spacing, color, shape, state variants) directly on a DOM node
// instead of composing a primitive -- a good proxy for "needs a look."
const LENGTH_THRESHOLD = 120

module.exports = {
  meta: {
    type: "suggestion",
    docs: {
      description: `Report-only: counts JSX class attributes longer than ${LENGTH_THRESHOLD} characters.`
    },
    schema: [],
    messages: {
      found: "className is {{length}} characters long ({{threshold}}+ usually means several design decisions are being restated on one DOM node)."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isExcluded(relative)) return {}

    return {
      JSXOpeningElement(node) {
        const longest = classNameCandidates(node).reduce((max, candidate) => Math.max(max, candidate.length), 0)
        if (longest > LENGTH_THRESHOLD) {
          context.report({ node, messageId: "found", data: { length: longest, threshold: LENGTH_THRESHOLD } })
        }
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
module.exports.LENGTH_THRESHOLD = LENGTH_THRESHOLD
