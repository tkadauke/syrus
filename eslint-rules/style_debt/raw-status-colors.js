"use strict"

const { relativePath, isExcluded, classNameCandidates } = require("./shared")

const RULE_KEY = "raw-status-colors"

// blue-*/terracotta-* are already tracked by the enforced no-legacy-color-tokens
// ratchet rule and its own baseline -- counting them again here would double
// report the same debt under a different name.
const STATUS_COLOR_PATTERN =
  /\b(?:bg|text|border|ring|divide|from|via|to|fill|stroke|placeholder|decoration|outline|accent|caret)-(?:gray|slate|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/g

module.exports = {
  meta: {
    type: "suggestion",
    docs: {
      description: "Report-only: counts raw gray/status Tailwind color utilities on JSX class attributes outside the design system."
    },
    schema: [],
    messages: {
      found: 'Raw color utility "{{token}}" outside the design system -- consider a semantic token or a design-system primitive.'
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isExcluded(relative)) return {}

    return {
      JSXOpeningElement(node) {
        for (const candidate of classNameCandidates(node)) {
          for (const match of candidate.matchAll(STATUS_COLOR_PATTERN)) {
            context.report({ node, messageId: "found", data: { token: match[0] } })
          }
        }
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
