import { createHighlighterCore, createCssVariablesTheme } from "@shikijs/core"
import { createOnigurumaEngine } from "@shikijs/engine-oniguruma"
import type { HighlighterCore, LanguageInput, ThemedToken } from "@shikijs/core"

// The languages the unified highlighting epic wires up first (EPIC-309). Each
// id is a real Shiki grammar id (see @shikijs/langs) so it can be passed
// straight through to loadLanguage()/codeToTokensBase() with no translation
// layer.
export type HighlighterLanguageId =
  | "ruby"
  | "javascript"
  | "typescript"
  | "tsx"
  | "jsx"
  | "json"
  | "yaml"
  | "sql"
  | "shellscript"
  | "erb"
  | "html"
  | "css"
  | "markdown"
  | "dockerfile"

// One dynamic import() per language, spelled out as literal string
// specifiers so Vite/Rollup can statically discover each as its own
// import graph entry point even though the main entry bundle disables
// codeSplitting (see docs/vite build notes in the PR for empirical
// per-language chunking behavior).
const LANGUAGE_LOADERS: Record<HighlighterLanguageId, LanguageInput> = {
  ruby: () => import("@shikijs/langs/ruby"),
  javascript: () => import("@shikijs/langs/javascript"),
  typescript: () => import("@shikijs/langs/typescript"),
  tsx: () => import("@shikijs/langs/tsx"),
  jsx: () => import("@shikijs/langs/jsx"),
  json: () => import("@shikijs/langs/json"),
  yaml: () => import("@shikijs/langs/yaml"),
  sql: () => import("@shikijs/langs/sql"),
  shellscript: () => import("@shikijs/langs/shellscript"),
  erb: () => import("@shikijs/langs/erb"),
  html: () => import("@shikijs/langs/html"),
  css: () => import("@shikijs/langs/css"),
  markdown: () => import("@shikijs/langs/markdown"),
  dockerfile: () => import("@shikijs/langs/dockerfile")
}

// Theme-tokens follow-up job (EPIC-309) maps these --shiki-token-* variables
// to per-theme values in the generated theme CSS. This job only wires up the
// css-variables theme mode itself; it does not define any variable values.
export const HIGHLIGHTER_THEME_NAME = "css-variables"

const cssVariablesTheme = createCssVariablesTheme({ name: HIGHLIGHTER_THEME_NAME })

let highlighterPromise: Promise<HighlighterCore> | null = null

function getHighlighter(): Promise<HighlighterCore> {
  if (!highlighterPromise) {
    highlighterPromise = createHighlighterCore({
      themes: [ cssVariablesTheme ],
      langs: [],
      engine: createOnigurumaEngine(() => import("@shikijs/engine-oniguruma/wasm-inlined"))
    })
  }

  return highlighterPromise
}

export async function loadLanguage(lang: HighlighterLanguageId): Promise<void> {
  const highlighter = await getHighlighter()
  if (highlighter.getLoadedLanguages().includes(lang)) return

  await highlighter.loadLanguage(LANGUAGE_LOADERS[lang])
}

// Tokenizes the full code string (not an isolated diff hunk / line range) so
// multi-line constructs like heredocs and template literals resolve
// correctly via Shiki's grammar continuation state, then returns one token
// array per line, suitable for rendering as <span>s.
export async function tokenizeLines(code: string, lang: HighlighterLanguageId): Promise<ThemedToken[][]> {
  await loadLanguage(lang)
  const highlighter = await getHighlighter()

  return highlighter.codeToTokensBase(code, { lang, theme: HIGHLIGHTER_THEME_NAME })
}

const EXTENSION_LANGUAGE_MAP: Record<string, HighlighterLanguageId> = {
  rb: "ruby",
  rake: "ruby",
  gemspec: "ruby",
  ru: "ruby",
  js: "javascript",
  cjs: "javascript",
  mjs: "javascript",
  ts: "typescript",
  cts: "typescript",
  mts: "typescript",
  tsx: "tsx",
  jsx: "jsx",
  json: "json",
  yml: "yaml",
  yaml: "yaml",
  sql: "sql",
  sh: "shellscript",
  bash: "shellscript",
  zsh: "shellscript",
  erb: "erb",
  html: "html",
  htm: "html",
  css: "css",
  md: "markdown",
  markdown: "markdown",
  dockerfile: "dockerfile"
}

const FILENAME_LANGUAGE_MAP: Record<string, HighlighterLanguageId> = {
  gemfile: "ruby",
  rakefile: "ruby",
  "config.ru": "ruby",
  dockerfile: "dockerfile"
}

// Single canonical language-detection helper, mapping a file path/extension
// to one of the ids this library loads. Later jobs in the epic will replace
// inferToolResultLanguage() (syntaxHighlight.tsx) and sourceLanguage()
// (jobDetail/sourceTree.ts) with this; both are left untouched for now.
export function detectHighlighterLanguage(path: string): HighlighterLanguageId | null {
  const name = (path.split(/[\\/]/).pop() || "").toLowerCase()
  if (!name) return null

  if (FILENAME_LANGUAGE_MAP[name]) return FILENAME_LANGUAGE_MAP[name]

  const extension = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : ""
  return EXTENSION_LANGUAGE_MAP[extension] || null
}
