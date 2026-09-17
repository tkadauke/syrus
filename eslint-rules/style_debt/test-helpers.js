"use strict"

const { Linter } = require("eslint")
const tsParser = require("@typescript-eslint/parser")

const NAMESPACE = "style-debt-test"

// Verifies `code` against a single report-only style-debt rule, the same
// way bin/style-debt-report's ESLint instance does (tsParser, JSX on,
// severity doesn't matter for message collection). Returns the raw
// ESLint message list.
function lintWithRule(rule, code, filename) {
  const linter = new Linter()
  return linter.verify(
    code,
    {
      files: ["**/*.{ts,tsx}"],
      languageOptions: {
        parser: tsParser,
        parserOptions: { ecmaFeatures: { jsx: true }, sourceType: "module" }
      },
      plugins: { [NAMESPACE]: { rules: { r: rule } } },
      rules: { [`${NAMESPACE}/r`]: "warn" }
    },
    { filename }
  )
}

module.exports = { lintWithRule }
