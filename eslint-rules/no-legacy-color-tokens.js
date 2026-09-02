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
const EXEMPT_FILES = [
  "app/frontend/components/ImageAnnotationModal.tsx",
  "app/frontend/lib/syntaxHighlight.tsx",
  "app/frontend/routes/Tags.tsx"
]

// JSX checks are scoped to className/class only (never SVG presentation
// attributes like fill/stroke, and never plain-JS objects like the xterm
// theme config in Terminal.tsx). Exported *Class/*Classes helper returns get
// an additional narrow check below so class-string helpers cannot hide legacy
// tokens from the JSX visitor.
const LEGACY_TOKEN_PATTERN = /\b(?:blue|terracotta)-\d{2,3}\b/
const CLASS_HELPER_PATTERN = /(?:Class|Classes)$/

function reportsClassHelperStrings(relative) {
  return /^app\/frontend\/routes\//.test(relative) ||
    /^app\/frontend\/lib\//.test(relative)
}

function exportedFunctionName(node) {
  if (node.type === "FunctionDeclaration") return node.id?.name
  if (node.type !== "VariableDeclaration") return null

  const declaration = node.declarations[0]
  if (!declaration || declaration.id.type !== "Identifier") return null
  return declaration.id.name
}

function exportedVariableInit(node) {
  if (node.type !== "VariableDeclaration") return null

  return node.declarations[0]?.init ?? null
}

function classHelperCandidates(node) {
  if (!node) return []
  if ((node.type === "ArrowFunctionExpression" || node.type === "FunctionExpression") && node.body.type !== "BlockStatement") {
    return collectStringLiterals(node.body)
  }
  return collectStringLiterals(node)
}

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
    const classHelperStack = []

    return {
      ExportNamedDeclaration(node) {
        const name = node.declaration ? exportedFunctionName(node.declaration) : null
        const tracksClassHelper = Boolean(name && CLASS_HELPER_PATTERN.test(name) && reportsClassHelperStrings(relative))
        classHelperStack.push(tracksClassHelper)

        const init = tracksClassHelper && node.declaration ? exportedVariableInit(node.declaration) : null
        if (!init) return

        for (const candidate of classHelperCandidates(init)) {
          const match = candidate.match(LEGACY_TOKEN_PATTERN)
          if (match) {
            matches.push({ node, token: match[0] })
            return
          }
        }
      },
      "ExportNamedDeclaration:exit"() {
        classHelperStack.pop()
      },
      JSXOpeningElement(node) {
        for (const candidate of classNameCandidates(node)) {
          const match = candidate.match(LEGACY_TOKEN_PATTERN)
          if (match) {
            matches.push({ node, token: match[0] })
            return
          }
        }
      },
      ReturnStatement(node) {
        if (!classHelperStack[classHelperStack.length - 1]) return

        for (const candidate of collectStringLiterals(node.argument)) {
          const match = candidate.match(LEGACY_TOKEN_PATTERN)
          if (match) {
            matches.push({ node, token: match[0] })
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
