"use strict"

const { relativePath, allowedCount, isDesignSystemExcluded, classNameCandidates, reportBeyondBaseline } = require("./rule-utils")

const RULE_KEY = "no-long-class-strings"

// A className string this long is almost always restating several design
// decisions (spacing, color, shape, state variants) directly on a DOM node
// instead of composing a primitive -- a good proxy for "needs a look."
const LENGTH_THRESHOLD = 120

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: `Forbid new JSX class attributes longer than ${LENGTH_THRESHOLD} characters.`
    },
    schema: [],
    messages: {
      forbidden:
        "className is {{length}} characters long ({{threshold}}+ usually means several design decisions are being restated on one DOM node) -- consider composing a primitive instead."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isDesignSystemExcluded(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        const longest = classNameCandidates(node).reduce((max, candidate) => Math.max(max, candidate.length), 0)
        if (longest > LENGTH_THRESHOLD) matches.push({ node, length: longest, threshold: LENGTH_THRESHOLD })
      },
      "Program:exit"() {
        reportBeyondBaseline(context, matches, allowed, "forbidden")
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
module.exports.LENGTH_THRESHOLD = LENGTH_THRESHOLD
