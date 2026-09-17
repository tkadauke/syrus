"use strict"

const { relativePath, allowedCount, isDesignSystemExcluded, classNameCandidates, reportBeyondBaseline } = require("./rule-utils")

const RULE_KEY = "no-raw-status-colors"

// Covers two related debt shapes called out in the DOC-27 ratchet-extension
// issue in one pass: raw neutral/gray text-and-panel colors (text-gray-*,
// bg-gray-*, border-gray-*, and their slate/zinc/neutral/stone cousins) and
// raw semantic-status colors (red/amber/green/etc, typically standing in for
// error/warning/success) used directly instead of a semantic token or the
// StatusPill primitive. blue-*/terracotta-* are excluded -- those are already
// tracked by the enforced no-legacy-color-tokens rule and its own baseline,
// so counting them here too would double-report the same debt.
const STATUS_COLOR_PATTERN =
  /\b(?:bg|text|border|ring|divide|from|via|to|fill|stroke|placeholder|decoration|outline|accent|caret)-(?:gray|slate|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b/g

module.exports = {
  meta: {
    type: "problem",
    docs: {
      description: "Forbid new raw gray/neutral and semantic-status Tailwind color utilities on JSX class attributes outside the design system."
    },
    schema: [],
    messages: {
      forbidden: 'Raw color utility "{{token}}" outside the design system -- use a semantic token (e.g. text-text-secondary, border-border) or the StatusPill primitive for status colors.'
    }
  },
  create(context) {
    const relative = relativePath(context.filename)
    if (isDesignSystemExcluded(relative)) return {}

    const allowed = allowedCount(RULE_KEY, relative)
    const matches = []

    return {
      JSXOpeningElement(node) {
        for (const candidate of classNameCandidates(node)) {
          for (const match of candidate.matchAll(STATUS_COLOR_PATTERN)) {
            matches.push({ node, token: match[0] })
          }
        }
      },
      "Program:exit"() {
        reportBeyondBaseline(context, matches, allowed, "forbidden")
      }
    }
  }
}

module.exports.RULE_KEY = RULE_KEY
