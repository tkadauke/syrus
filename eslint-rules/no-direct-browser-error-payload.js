"use strict"

const { relativePath, isTestFile } = require("./rule-utils")

const APPROVED_INFRASTRUCTURE = new Set([
  "app/frontend/api/browserErrors.ts",
  "app/frontend/components/AppErrorBoundary.tsx",
  "app/frontend/components/PluginErrorBoundary.tsx",
  "app/frontend/components/RouteErrorBoundary.tsx",
  "app/frontend/lib/handledErrorReporting.ts",
  "app/frontend/lib/recoverableErrorDiagnostics.ts"
])

module.exports = {
  meta: {
    type: "problem",
    docs: { description: "Keep browser-error payload construction inside the shared reporting infrastructure." },
    schema: [],
    messages: { forbidden: "Use reportHandledError instead of constructing a browser-error payload in a product surface." }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isTestFile(relative) || APPROVED_INFRASTRUCTURE.has(relative)) return {}
    return {
      CallExpression(node) {
        if (node.callee.type === "Identifier" && node.callee.name === "buildBrowserErrorPayload") {
          context.report({ node, messageId: "forbidden" })
        }
      }
    }
  }
}
