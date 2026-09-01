"use strict"

const { relativePath, allowedCount, isTestFile, endsWithAny, collectStringLiterals, classNameCandidates } = require("./rule-utils")

const RULE_KEY = "no-legacy-color-tokens"

// The design-system primitives themselves still define the palette in terms
// of blue-*/terracotta-* utilities (and remap `blue` onto the terracotta
// scale in config/tailwind.config.js, outside app/frontend entirely) -- that
// is the source of truth the semantic tokens are built from, not debt.
const EXEMPT_BASENAMES = ["Button.tsx", "Card.tsx", "Input.tsx", "Select.tsx", "Modal.tsx", "Checkbox.tsx", "Toggle.tsx"]

// Documented exceptions called out in the epic scan: these render
// user-facing color *pickers*, where "blue" is a literal color choice being
// offered to the user, not a design-system styling decision.
const EXEMPT_FILES = ["app/frontend/components/ImageAnnotationModal.tsx", "app/frontend/routes/Tags.tsx", "app/frontend/lib/syntaxHighlight.tsx"]

// Scoped to className/class only (never SVG presentation attributes like
// fill/stroke, and never plain-JS objects like the xterm theme config in
// Terminal.tsx) via classNameCandidates -- so those documented exceptions
// are excluded by construction rather than by file-listing them.
const LEGACY_TOKEN_PATTERN = /\b(?:blue|terracotta)-\d{2,3}\b/
const CLASS_HELPER_NAME_PATTERN = /(?:Class|ClassName)$/

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid new blue-*/terracotta-* Tailwind utility usage in frontend routes and components; use the semantic color tokens instead."
    },
    schema: [],
    messages: {
      forbidden: "Use a semantic color token (e.g. bg-brand, text-text-secondary, border-border) instead of the legacy \"{{token}}\" utility."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isTestFile(relative) || endsWithAny(relative, EXEMPT_BASENAMES) || EXEMPT_FILES.includes(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []
    const inspectClassHelpers = isRouteHelpersFile(relative) || isFrontendLibFile(relative)

    function recordCandidate(node, value) {
      const match = value.match(LEGACY_TOKEN_PATTERN)
      if (match) matches.push({ node, token: match[0] })
    }

    function recordStringLiterals(node) {
      for (const value of collectStringLiterals(node)) recordCandidate(node, value)
    }

    function exportedFunctionName(node) {
      if (node.type === "FunctionDeclaration") return node.id?.name || null
      if (node.type !== "VariableDeclaration") return null

      const declarator = node.declarations[0]
      return declarator?.id?.type === "Identifier" ? declarator.id.name : null
    }

    function inspectExportedClassHelper(node) {
      if (!inspectClassHelpers || node.type !== "ExportNamedDeclaration" || !node.declaration) return

      const name = exportedFunctionName(node.declaration)
      if (!name || !CLASS_HELPER_NAME_PATTERN.test(name)) return

      if (node.declaration.type === "FunctionDeclaration") {
        inspectFunctionReturns(node.declaration)
        return
      }

      for (const declarator of node.declaration.declarations) {
        if (declarator.init?.type === "ArrowFunctionExpression" || declarator.init?.type === "FunctionExpression") {
          inspectFunctionReturns(declarator.init)
        } else {
          recordStringLiterals(declarator.init)
        }
      }
    }

    function inspectFunctionReturns(functionNode) {
      const body = functionNode.body
      if (!body) return
      if (body.type !== "BlockStatement") {
        recordStringLiterals(body)
        return
      }

      inspectReturnStatements(body)
    }

    function inspectReturnStatements(node) {
      if (!node || typeof node.type !== "string") return
      if (node.type === "ReturnStatement") {
        recordStringLiterals(node.argument)
        return
      }

      for (const key of Object.keys(node)) {
        if (key === "parent" || key === "loc" || key === "range" || key === "tokens" || key === "comments") continue

        const value = node[key]
        if (Array.isArray(value)) {
          value.forEach(inspectReturnStatements)
        } else if (value && typeof value.type === "string") {
          inspectReturnStatements(value)
        }
      }
    }

    return {
      ExportNamedDeclaration: inspectExportedClassHelper,
      JSXOpeningElement(node) {
        for (const candidate of classNameCandidates(node)) {
          if (candidate.match(LEGACY_TOKEN_PATTERN)) {
            recordCandidate(node, candidate)
            return
          }
        }
      },
      "Program:exit"() {
        for (const { node, token } of matches.slice(allowed)) {
          context.report({ node, messageId: "forbidden", data: { token } })
        }
      }
    }
  }
}

function isRouteHelpersFile(relative) {
  return /^app\/frontend\/routes\/.*\/helpers\.tsx?$/.test(relative)
}

function isFrontendLibFile(relative) {
  return /^app\/frontend\/lib\/.*\.tsx?$/.test(relative)
}
