"use strict"

// The DOC-27 style-debt *reporting* rule set. These are deliberately not
// wired into eslint.config.js -- they always report every match with no
// baseline suppression, so running them through the enforced config would
// fail every PR immediately. bin/style-debt-report loads this module
// directly, lints with every rule set to "warn" (so ESLint never exits
// nonzero on their account), and aggregates the resulting messages into
// counts. See config/syrus_docs/style_debt_report.md.
//
// raw-status-colors, panel-shell-repeats, raw-table-classes, and
// long-class-strings previously lived here and have graduated into the
// enforced ratchet as no-raw-status-colors, no-panel-shell-repeats,
// no-raw-table-classes, and no-long-class-strings under eslint-rules/ --
// removed from here so the same debt isn't counted twice. plugin-ui-imports
// remains report-only: it is a heuristic (JSX element count with no
// @app/components import) rather than a specific forbidden pattern, so it
// isn't yet a good candidate for a hard block.

const pluginUiImports = require("./plugin-ui-imports")

// Order here is the order categories print in the report.
const RULES = [{ key: pluginUiImports.RULE_KEY, rule: pluginUiImports, label: "Plugin UI without @app/components imports" }]

module.exports = { RULES }
