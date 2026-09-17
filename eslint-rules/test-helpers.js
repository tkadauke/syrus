"use strict"

const { Linter } = require("eslint")
const tsParser = require("@typescript-eslint/parser")

const NAMESPACE = "design-system-test"

// Verifies `code` against a single enforced ratchet rule, the same way
// eslint.config.js's ESLint instance does (tsParser, JSX on). `filename`
// should be a path with no entry in the checked-in eslint-rules/baseline.json
// (any file under app/frontend/routes/ that doesn't really exist works) so
// `allowedCount` resolves to zero and every match is reported -- keeps these
// tests independent of the baseline's real, evolving contents. Returns the
// raw ESLint message list.
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
      rules: { [`${NAMESPACE}/r`]: "error" }
    },
    { filename }
  )
}

module.exports = { lintWithRule }
