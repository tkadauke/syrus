"use strict"

const { relativePath, allowedCount, isTestFile, endsWithAny } = require("./rule-utils")

const RULE_KEY = "no-raw-form-elements"
const EXEMPT_BASENAMES = ["Input.tsx", "Select.tsx", "Checkbox.tsx", "Toggle.tsx"]
const FORBIDDEN_TAGS = new Set(["input", "select"])

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid raw <input>/<select> JSX elements outside the Input/Select/Checkbox/Toggle primitives."
    },
    schema: [],
    messages: {
      forbidden: "Use the <{{primitive}}> primitive from app/frontend/components instead of a raw <{{tag}}> element."
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
        if (tag && FORBIDDEN_TAGS.has(tag)) matches.push({ node, tag })
      },
      "Program:exit"() {
        for (const { node, tag } of matches.slice(allowed)) {
          context.report({
            node,
            messageId: "forbidden",
            data: { tag, primitive: tag === "input" ? "Input" : "Select" }
          })
        }
      }
    }
  }
}
