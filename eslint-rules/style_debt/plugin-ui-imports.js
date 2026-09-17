"use strict"

const { relativePath, isExcluded } = require("./shared")

const RULE_KEY = "plugin-ui-imports"

// Plugin frontend files only -- core files aren't "adopting" anything, they
// *are* the design system (or its earliest, most central consumers).
const PLUGIN_FILE_PATTERN = /^plugins\/[^/]+\/app\/frontend\//

// Below this many JSX elements, a file is more likely a thin wrapper or a
// tiny helper than a UI surface worth flagging.
const SUBSTANTIAL_ELEMENT_THRESHOLD = 8

const DESIGN_SYSTEM_IMPORT_PATTERN = /^@app\/components(?:\/|$)/

module.exports = {
  meta: {
    type: "suggestion",
    docs: {
      description: "Report-only: flags plugin frontend files rendering substantial JSX with no import from @app/components (the shared design system)."
    },
    schema: [],
    messages: {
      found: "{{count}} JSX elements with no @app/components import -- this plugin surface may be hand-rolling UI the design system already covers."
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (!PLUGIN_FILE_PATTERN.test(relative) || isExcluded(relative)) return {}

    let elementCount = 0
    let usesDesignSystem = false
    let programNode = null

    return {
      Program(node) {
        programNode = node
      },
      JSXOpeningElement() {
        elementCount += 1
      },
      ImportDeclaration(node) {
        if (typeof node.source.value === "string" && DESIGN_SYSTEM_IMPORT_PATTERN.test(node.source.value)) {
          usesDesignSystem = true
        }
      },
      "Program:exit"() {
        if (!usesDesignSystem && elementCount >= SUBSTANTIAL_ELEMENT_THRESHOLD) {
          context.report({ node: programNode, messageId: "found", data: { count: elementCount } })
        }
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
module.exports.SUBSTANTIAL_ELEMENT_THRESHOLD = SUBSTANTIAL_ELEMENT_THRESHOLD
