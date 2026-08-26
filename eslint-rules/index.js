"use strict"

// Local ESLint plugin for the design-system lint ratchet (EPIC-267). Each
// rule enforces a per-file count baseline against eslint-rules/baseline.json
// so today's ~1,210 existing violations stay green while any *new*
// occurrence -- in a new file, or beyond a file's baselined count -- fails
// lint. See rule-utils.js for the baseline mechanics and
// bin/generate-eslint-baseline for how to regenerate it.

module.exports = {
  rules: {
    "no-raw-form-elements": require("./no-raw-form-elements"),
    "no-raw-button-classes": require("./no-raw-button-classes"),
    "no-legacy-color-tokens": require("./no-legacy-color-tokens")
  }
}
