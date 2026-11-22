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
    const payloadBuilders = new Set(["buildBrowserErrorPayload"])
    const browserErrorNamespaces = new Set()

    return {
      ImportDeclaration(node) {
        if (!/(?:^|\/)api\/browserErrors$/.test(node.source.value)) return
        for (const specifier of node.specifiers) {
          if (specifier.type === "ImportSpecifier" && specifier.imported.name === "buildBrowserErrorPayload") {
            payloadBuilders.add(specifier.local.name)
          }
          if (specifier.type === "ImportNamespaceSpecifier") browserErrorNamespaces.add(specifier.local.name)
        }
      },
      CallExpression(node) {
        const directCall = node.callee.type === "Identifier" && payloadBuilders.has(node.callee.name)
        const namespaceCall =
          node.callee.type === "MemberExpression" &&
          !node.callee.computed &&
          node.callee.object.type === "Identifier" &&
          browserErrorNamespaces.has(node.callee.object.name) &&
          node.callee.property.type === "Identifier" &&
          node.callee.property.name === "buildBrowserErrorPayload"

        if (directCall || namespaceCall) {
          context.report({ node, messageId: "forbidden" })
        }
      }
    }
  }
}
