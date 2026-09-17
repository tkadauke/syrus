"use strict"

const { relativePath, allowedCount, isDesignSystemExcluded, reportBeyondBaseline } = require("./rule-utils")

const RULE_KEY = "no-raw-table-classes"
const FORBIDDEN_TAGS = new Set(["td", "th"])

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid new raw <td>/<th> JSX elements outside the DataTable primitive."
    },
    schema: [],
    messages: {
      forbidden: "Use the DataTable primitive from app/frontend/components/ui instead of a raw <{{tag}}> element."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isDesignSystemExcluded(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        const tag = node.name.type === "JSXIdentifier" ? node.name.name : null
        if (tag && FORBIDDEN_TAGS.has(tag)) matches.push({ node, tag })
      },
      "Program:exit"() {
        reportBeyondBaseline(context, matches, allowed, "forbidden")
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
