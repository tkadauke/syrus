"use strict"

// Local ESLint plugin for the design-system lint ratchet. Each rule enforces
// a per-file count baseline against eslint-rules/baseline.json so
// already-known violations stay green while any *new* occurrence -- in a new
// file, or beyond a file's baselined count -- fails lint. See rule-utils.js
// for the baseline mechanics and bin/generate-eslint-baseline for how to
// regenerate it.
//
// no-raw-status-colors, no-panel-shell-repeats, no-raw-table-classes, and
// no-long-class-strings graduated from the report-only rules under
// style_debt/ (see config/syrus_docs/style_debt_report.md) once the DOC-27
// ratchet-extension job decided they were ready to block new debt instead of
// merely counting it.

module.exports = {
  rules: {
    "no-raw-form-elements": require("./no-raw-form-elements"),
    "no-raw-button-classes": require("./no-raw-button-classes"),
    "no-legacy-color-tokens": require("./no-legacy-color-tokens"),
    "no-raw-status-colors": require("./no-raw-status-colors"),
    "no-panel-shell-repeats": require("./no-panel-shell-repeats"),
    "no-raw-table-classes": require("./no-raw-table-classes"),
    "no-long-class-strings": require("./no-long-class-strings")
  }
}
