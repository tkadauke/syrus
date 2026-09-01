"use strict"

const { RuleTester } = require("eslint")
const path = require("node:path")
const rule = require("./no-legacy-color-tokens")
const { ROOT } = require("./rule-utils")

const parser = require("@typescript-eslint/parser")

const tester = new RuleTester({
  languageOptions: {
    parser,
    parserOptions: {
      ecmaFeatures: { jsx: true },
      sourceType: "module"
    }
  }
})

tester.run("no-legacy-color-tokens", rule, {
  valid: [
    {
      code: "export function recentChatLinkClass(active: boolean) { return active ? 'bg-brand/10 text-brand' : 'text-gray-700 hover:text-brand' }",
      filename: path.join(ROOT, "app/frontend/routes/appChromeV2/helpers.ts")
    },
    {
      code: "export function diffLineClass(kind: string) { return kind === 'hunk' ? 'bg-blue-50 text-blue-700' : 'text-gray-700' }",
      filename: path.join(ROOT, "app/frontend/routes/jobDetail/diffRendering.ts")
    }
  ],
  invalid: [
    {
      code: "export function recentChatLinkClass(active: boolean) { return `flex ${active ? 'bg-blue-50 text-blue-700' : 'hover:text-blue-700'}` }",
      filename: path.join(ROOT, "app/frontend/routes/appChromeV2/helpers.ts"),
      errors: [{ messageId: "forbidden" }, { messageId: "forbidden" }]
    },
    {
      code: "export const authPrimaryButtonClass = 'bg-terracotta-600 text-white'",
      filename: path.join(ROOT, "app/frontend/lib/buttonStyles.ts"),
      errors: [{ messageId: "forbidden" }]
    },
    {
      code: "export const navLinkClass = (active: boolean) => { if (active) return 'bg-blue-50'; return 'text-gray-700' }",
      filename: path.join(ROOT, "app/frontend/routes/appChromeV2/helpers.ts"),
      errors: [{ messageId: "forbidden" }]
    }
  ]
})
