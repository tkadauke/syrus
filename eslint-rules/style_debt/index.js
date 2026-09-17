"use strict"

// The DOC-27 style-debt *reporting* rule set. These are deliberately not
// wired into eslint.config.js -- they always report every match with no
// baseline suppression, so running them through the enforced config would
// fail every PR immediately. bin/style-debt-report loads this module
// directly, lints with every rule set to "warn" (so ESLint never exits
// nonzero on their account), and aggregates the resulting messages into
// counts. See config/syrus_docs/style_debt_report.md.

const rawStatusColors = require("./raw-status-colors")
const panelShellRepeats = require("./panel-shell-repeats")
const rawTableClasses = require("./raw-table-classes")
const longClassStrings = require("./long-class-strings")
const pluginUiImports = require("./plugin-ui-imports")

// Order here is the order categories print in the report.
const RULES = [
  { key: rawStatusColors.RULE_KEY, rule: rawStatusColors, label: "Raw gray/status color classes" },
  { key: panelShellRepeats.RULE_KEY, rule: panelShellRepeats, label: "Repeated panel shells" },
  { key: rawTableClasses.RULE_KEY, rule: rawTableClasses, label: "Raw table cell/header classes" },
  { key: longClassStrings.RULE_KEY, rule: longClassStrings, label: "Long class strings" },
  { key: pluginUiImports.RULE_KEY, rule: pluginUiImports, label: "Plugin UI without @app/components imports" }
]

module.exports = { RULES }
