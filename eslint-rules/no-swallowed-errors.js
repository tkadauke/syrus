"use strict"

const { relativePath, allowedCount, isTestFile, reportBeyondBaseline } = require("./rule-utils")

const RULE_KEY = "no-swallowed-errors"
const ESCAPE = "handled-error-expected"

function walk(node, visit) {
  if (!node || typeof node !== "object") return
  visit(node)
  for (const [key, value] of Object.entries(node)) {
    if (key === "parent" || key === "loc" || key === "range" || key === "tokens" || key === "comments") continue
    if (Array.isArray(value)) value.forEach((child) => walk(child, visit))
    else if (value?.type) walk(value, visit)
  }
}

function handlesFailure(node, sourceCode) {
  if (sourceCode.getCommentsInside(node).some((comment) => comment.value.includes(ESCAPE))) return true
  let handled = false
  walk(node, (child) => {
    if (child.type === "ThrowStatement") handled = true
    if (child.type !== "CallExpression") return
    const callee = child.callee
    if (callee.type === "Identifier" && callee.name === "reportHandledError") handled = true
  })
  return handled
}

module.exports = {
  meta: {
    type: "problem",
    docs: { description: "Ratchet catches that silently consume unexpected frontend failures." },
    schema: [],
    messages: {
      swallowed: `Report unexpected failures with reportHandledError, rethrow them, or document expected control flow with a ${ESCAPE} comment.`
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isTestFile(relative)) return {}
    const matches = []
    const sourceCode = context.sourceCode

    return {
      CatchClause(node) {
        if (!handlesFailure(node.body, sourceCode)) matches.push({ node })
      },
      CallExpression(node) {
        if (node.callee.type !== "MemberExpression" || node.callee.property?.name !== "catch") return
        const callback = node.arguments[0]
        if (!callback || !["ArrowFunctionExpression", "FunctionExpression"].includes(callback.type)) return
        if (!handlesFailure(callback.body, sourceCode)) matches.push({ node: callback })
      },
      "Program:exit"() {
        reportBeyondBaseline(context, matches, allowedCount(RULE_KEY, relative), "swallowed")
      }
    }
  }
}
