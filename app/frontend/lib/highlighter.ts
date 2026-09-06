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

// Shiki's css-variables theme mode emits token colors as
// `var(${HIGHLIGHTER_CSS_VARIABLE_PREFIX}<name>)` -- e.g.
// `var(--shiki-token-keyword)` -- instead of literal hex values, so
// rendered tokens automatically follow whichever `--shiki-*` values are in
// effect for the current theme/dark-mode state. Theme::SYNTAX_TOKEN_KEYS
// (app/models/theme.rb) and ThemeCssGenerator define the matching
// per-theme `--shiki-*` values (with application.css's `:root`/`.dark`
// blocks as the fallback for themes that don't); the prefix is pinned
// explicitly here, rather than left to createCssVariablesTheme()'s default,
// so the two sides can't silently drift if that default ever changes.
export const HIGHLIGHTER_THEME_NAME = "css-variables"
export const HIGHLIGHTER_CSS_VARIABLE_PREFIX = "--shiki-"

const cssVariablesTheme = createCssVariablesTheme({
  name: HIGHLIGHTER_THEME_NAME,
  variablePrefix: HIGHLIGHTER_CSS_VARIABLE_PREFIX
})

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
// to one of the ids this library loads.
export function detectHighlighterLanguage(path: string): HighlighterLanguageId | null {
  const name = (path.split(/[\\/]/).pop() || "").toLowerCase()
  if (!name) return null

  if (FILENAME_LANGUAGE_MAP[name]) return FILENAME_LANGUAGE_MAP[name]

  const extension = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : ""
  return EXTENSION_LANGUAGE_MAP[extension] || null
}

const HIGHLIGHTER_LANGUAGE_IDS = new Set<string>(Object.keys(LANGUAGE_LOADERS))

// Maps a Markdown fenced code block's info string (e.g. the `ruby` in
// ```ruby) to a highlighter language id. Accepts both canonical ids
// ("ruby", "typescript") and the file-extension aliases
// detectHighlighterLanguage() already understands ("rb", "ts", "yml").
export function detectFenceLanguage(hint: string): HighlighterLanguageId | null {
  const normalized = hint.trim().toLowerCase()
  if (!normalized) return null
  if (HIGHLIGHTER_LANGUAGE_IDS.has(normalized)) return normalized as HighlighterLanguageId

  return detectHighlighterLanguage(`fence.${normalized}`)
}
