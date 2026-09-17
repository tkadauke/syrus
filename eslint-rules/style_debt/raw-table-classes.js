"use strict"

const { relativePath, isExcluded } = require("./shared")

const RULE_KEY = "raw-table-classes"
const FORBIDDEN_TAGS = new Set(["td", "th"])

module.exports = {
  meta: {
    type: "suggestion",
    docs: {
      description: "Report-only: counts raw <td>/<th> elements outside the DataTable primitive."
    },
    schema: [],
    messages: {
      found: "Raw <{{tag}}> element -- consider the DataTable primitive from app/frontend/components/ui instead of hand-rolled table markup."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isExcluded(relative)) return {}

    return {
      JSXOpeningElement(node) {
        const tag = node.name.type === "JSXIdentifier" ? node.name.name : null
        if (tag && FORBIDDEN_TAGS.has(tag)) {
          context.report({ node, messageId: "found", data: { tag } })
        }
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
