"use strict"

// Design-system lint ratchet (EPIC-267). This config intentionally does not
// pull in eslint:recommended or any framework preset -- it exists solely to
// run the three local design-system rules under eslint-rules/. Broader
// linting is a separate concern for a future job.
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
    // Rules 1 & 2 (raw form elements, duplicated button classes) apply
    // across all first-party and plugin frontend code, per the issue scope.
    files: ["app/frontend/**/*.{ts,tsx}", "plugins/*/app/frontend/**/*.{ts,tsx}"],
    languageOptions: jsxLanguageOptions,
    plugins: basePlugins,
    rules: {
      "design-system/no-raw-form-elements": "error",
      "design-system/no-raw-button-classes": "error"
    }
  },
  {
    // Rule 3 (legacy blue-*/terracotta-* tokens) is scoped narrower, to
    // routes and components only, per the issue scope.
    files: [
      "app/frontend/routes/**/*.{ts,tsx}",
      "app/frontend/components/**/*.{ts,tsx}",
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
