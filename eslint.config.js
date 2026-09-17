"use strict"

// Design-system lint ratchet. This config intentionally does not pull in
// eslint:recommended or any framework preset -- it exists solely to run the
// local design-system rules under eslint-rules/. Broader linting is a
// separate concern for a future job.
const tsParser = require("@typescript-eslint/parser")
const tsPlugin = require("@typescript-eslint/eslint-plugin")
const reactHooksPlugin = require("eslint-plugin-react-hooks")
const designSystem = require("./eslint-rules")

const jsxLanguageOptions = {
  parser: tsParser,
  parserOptions: {
    ecmaFeatures: { jsx: true },
    sourceType: "module"
  }
}

// A handful of files already carry `// eslint-disable-next-line
// @typescript-eslint/...` / `react-hooks/exhaustive-deps` comments from
// before this repo had any ESLint config. ESLint errors on a disable
// comment referencing a rule ID it can't resolve ("Definition for rule
// '...' was not found"), so these two plugins are registered here purely to
// make those rule names resolvable -- none of their rules are enabled.
const basePlugins = {
  "design-system": designSystem,
  "@typescript-eslint": tsPlugin,
  "react-hooks": reactHooksPlugin
}

module.exports = [
  {
    // Broadly-scoped rules apply across all first-party and plugin frontend
    // code: raw form elements, duplicated button classes (original ratchet
    // scope), plus raw gray/status colors, repeated panel shells, raw table
    // cell/header markup, and excessive class strings (graduated from the
    // report-only style_debt/ rules by the DOC-27 ratchet-extension job --
    // see config/syrus_docs/style_debt_report.md).
    files: ["app/frontend/**/*.{ts,tsx}", "plugins/*/app/frontend/**/*.{ts,tsx}"],
    languageOptions: jsxLanguageOptions,
    plugins: basePlugins,
    rules: {
      "design-system/no-raw-form-elements": "error",
      "design-system/no-raw-button-classes": "error",
      "design-system/no-raw-status-colors": "error",
      "design-system/no-panel-shell-repeats": "error",
      "design-system/no-raw-table-classes": "error",
      "design-system/no-long-class-strings": "error"
    }
  },
  {
    // Rule 3 (legacy blue-*/terracotta-* tokens) is scoped to user-facing JSX
    // surfaces and helpers that render JSX. Plain class-string helpers remain
    // outside the AST coverage of the rule itself.
    files: [
      "app/frontend/lib/**/*.{ts,tsx}",
      "app/frontend/routes/**/*.{ts,tsx}",
      "app/frontend/components/**/*.{ts,tsx}",
      "plugins/*/app/frontend/lib/**/*.{ts,tsx}",
      "plugins/*/app/frontend/routes/**/*.{ts,tsx}",
      "plugins/*/app/frontend/components/**/*.{ts,tsx}"
    ],
    languageOptions: jsxLanguageOptions,
    plugins: basePlugins,
    rules: {
      "design-system/no-legacy-color-tokens": "error"
    }
  }
]
