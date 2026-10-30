import { createHighlighterCore, createCssVariablesTheme } from "@shikijs/core"
import { createOnigurumaEngine } from "@shikijs/engine-oniguruma"
import type { HighlighterCore, LanguageInput, ThemedToken } from "@shikijs/core"
import { endMarker, startMarker } from "./performanceMarkers"

// The languages the unified highlighter wires up. Each
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
  | "python"
  | "go"
  | "rust"
  | "php"
  | "hack"
  | "java"
  | "c"
  | "cpp"
  | "csharp"
  | "kotlin"
  | "swift"
  | "objective-c"
  | "objective-cpp"
  | "scala"
  | "dart"
  | "perl"
  | "lua"
  | "elixir"
  | "erlang"
  | "crystal"
  | "d"
  | "ocaml"
  | "pascal"
  | "common-lisp"
  | "scheme"
  | "clojure"
  | "haskell"
  | "coffeescript"
  | "vb"
  | "powershell"
  | "applescript"
  | "awk"
  | "r"
  | "wasm"
  | "wgsl"
  | "angular-html"
  | "angular-ts"
  | "bibtex"
  | "haml"
  | "http"
  | "jinja"
  | "latex"
  | "tex"
  | "regexp"
  | "rst"
  | "less"
  | "sass"
  | "scss"
  | "toml"
  | "ini"
  | "xml"
  | "xsl"
  | "csv"
  | "tsv"
  | "dotenv"
  | "hcl"
  | "terraform"
  | "cmake"
  | "makefile"
  | "gnuplot"
  | "openscad"
  | "graphql"
  | "protobuf"
  | "desktop"
  | "diff"

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
  dockerfile: () => import("@shikijs/langs/dockerfile"),
  python: () => import("@shikijs/langs/python"),
  go: () => import("@shikijs/langs/go"),
  rust: () => import("@shikijs/langs/rust"),
  php: () => import("@shikijs/langs/php"),
  hack: () => import("@shikijs/langs/hack"),
  java: () => import("@shikijs/langs/java"),
  c: () => import("@shikijs/langs/c"),
  cpp: () => import("@shikijs/langs/cpp"),
  csharp: () => import("@shikijs/langs/csharp"),
  kotlin: () => import("@shikijs/langs/kotlin"),
  swift: () => import("@shikijs/langs/swift"),
  "objective-c": () => import("@shikijs/langs/objective-c"),
  "objective-cpp": () => import("@shikijs/langs/objective-cpp"),
  scala: () => import("@shikijs/langs/scala"),
  dart: () => import("@shikijs/langs/dart"),
  perl: () => import("@shikijs/langs/perl"),
  lua: () => import("@shikijs/langs/lua"),
  elixir: () => import("@shikijs/langs/elixir"),
  erlang: () => import("@shikijs/langs/erlang"),
  crystal: () => import("@shikijs/langs/crystal"),
  d: () => import("@shikijs/langs/d"),
  ocaml: () => import("@shikijs/langs/ocaml"),
  pascal: () => import("@shikijs/langs/pascal"),
  "common-lisp": () => import("@shikijs/langs/common-lisp"),
  scheme: () => import("@shikijs/langs/scheme"),
  clojure: () => import("@shikijs/langs/clojure"),
  haskell: () => import("@shikijs/langs/haskell"),
  coffeescript: () => import("@shikijs/langs/coffeescript"),
  vb: () => import("@shikijs/langs/vb"),
  powershell: () => import("@shikijs/langs/powershell"),
  applescript: () => import("@shikijs/langs/applescript"),
  awk: () => import("@shikijs/langs/awk"),
  r: () => import("@shikijs/langs/r"),
  wasm: () => import("@shikijs/langs/wasm"),
  wgsl: () => import("@shikijs/langs/wgsl"),
  "angular-html": () => import("@shikijs/langs/angular-html"),
  "angular-ts": () => import("@shikijs/langs/angular-ts"),
  bibtex: () => import("@shikijs/langs/bibtex"),
  haml: () => import("@shikijs/langs/haml"),
  http: () => import("@shikijs/langs/http"),
  jinja: () => import("@shikijs/langs/jinja"),
  latex: () => import("@shikijs/langs/latex"),
  tex: () => import("@shikijs/langs/tex"),
  regexp: () => import("@shikijs/langs/regexp"),
  rst: () => import("@shikijs/langs/rst"),
  less: () => import("@shikijs/langs/less"),
  sass: () => import("@shikijs/langs/sass"),
  scss: () => import("@shikijs/langs/scss"),
  toml: () => import("@shikijs/langs/toml"),
  ini: () => import("@shikijs/langs/ini"),
  xml: () => import("@shikijs/langs/xml"),
  xsl: () => import("@shikijs/langs/xsl"),
  csv: () => import("@shikijs/langs/csv"),
  tsv: () => import("@shikijs/langs/tsv"),
  dotenv: () => import("@shikijs/langs/dotenv"),
  hcl: () => import("@shikijs/langs/hcl"),
  terraform: () => import("@shikijs/langs/terraform"),
  cmake: () => import("@shikijs/langs/cmake"),
  makefile: () => import("@shikijs/langs/makefile"),
  gnuplot: () => import("@shikijs/langs/gnuplot"),
  openscad: () => import("@shikijs/langs/openscad"),
  graphql: () => import("@shikijs/langs/graphql"),
  protobuf: () => import("@shikijs/langs/protobuf"),
  desktop: () => import("@shikijs/langs/desktop"),
  diff: () => import("@shikijs/langs/diff")
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
const languagePromises = new Map<HighlighterLanguageId, Promise<void>>()

type TokenizationCacheEntry = {
  promise: Promise<ThemedToken[][]>
  tokenSpans: number
}

// This cache is module-scoped and shared by every surface that highlights
// code -- the diff review and chat's CodeBlock -- so it outlives any one view
// and is never torn down. Two properties therefore have to hold, and an
// earlier entry-counted version of this cache held neither:
//
//   1. It must be budgeted by what it actually retains. An entry count says
//      nothing about memory, because one entry can be ten lines or ten
//      thousand; 200 entries of review diffs is tens of MB of ThemedToken
//      objects held for the life of the SPA session. iOS Safari enforces a
//      hard per-tab ceiling and jetsams the web process when it is crossed,
//      which presents as a reload loop on whichever page happened to be open
//      -- not on the page that filled the cache.
//
//   2. The key must not be the source text. `${lang}\0${code}` allocates a
//      fresh string per entry, so the keys alone retained a second full copy
//      of every file ever highlighted.
//
// Budgeting by resolved token spans fixes (1) and a content hash fixes (2).
const MAX_CACHED_TOKEN_SPANS = 20_000
// Backstop for in-flight entries, whose span count is not known yet and so
// cannot be budgeted. Deliberately far below what the span budget admits.
const MAX_CACHED_ENTRIES = 64
// A single file above this size is still tokenized and rendered -- it just is
// not retained afterwards, so one large file cannot evict everything else.
const MAX_CACHEABLE_CHARACTERS = 128 * 1024

const tokenizationCache = new Map<string, TokenizationCacheEntry>()
let cachedTokenSpans = 0

// cyrb53: a fast non-cryptographic 53-bit hash. The key also carries the
// language and the source length, so a collision would need the same length,
// the same language and the same hash -- and the cost of one would be
// mis-colored tokens, never incorrect content.
function hashCode(value: string): string {
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let i = 0; i < value.length; i++) {
    const ch = value.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36)
}

function tokenizationCacheKey(code: string, lang: HighlighterLanguageId): string {
  return `${lang}\u0000${code.length}\u0000${hashCode(code)}`
}

function forgetTokenization(key: string) {
  const entry = tokenizationCache.get(key)
  if (!entry) return

  cachedTokenSpans -= entry.tokenSpans
  tokenizationCache.delete(key)
}

// Evicts least-recently-used entries until the cache is inside both budgets.
// Map preserves insertion order and a cache hit re-inserts, so iteration
// order is LRU order.
function evictTokenizationsOverBudget(keep: string) {
  for (const key of tokenizationCache.keys()) {
    if (cachedTokenSpans <= MAX_CACHED_TOKEN_SPANS && tokenizationCache.size <= MAX_CACHED_ENTRIES) return
    if (key === keep) continue

    forgetTokenization(key)
  }
}

function getHighlighter(): Promise<HighlighterCore> {
  if (!highlighterPromise) {
    const marker = startMarker("diff_review.highlighter_initialize", { maxPerSession: 1 })
    highlighterPromise = createHighlighterCore({
      themes: [cssVariablesTheme],
      langs: [],
      engine: createOnigurumaEngine(() => import("@shikijs/engine-oniguruma/wasm-inlined"))
    })
    highlighterPromise.then(
      () => endMarker(marker),
      () => endMarker(marker, { metadata: { error: true } })
    )
  }

  return highlighterPromise
}

export async function loadLanguage(lang: HighlighterLanguageId): Promise<void> {
  const highlighter = await getHighlighter()
  if (highlighter.getLoadedLanguages().includes(lang)) return
  let promise = languagePromises.get(lang)
  if (!promise) {
    promise = highlighter.loadLanguage(LANGUAGE_LOADERS[lang]).finally(() => languagePromises.delete(lang))
    languagePromises.set(lang, promise)
  }
  await promise
}

// Tokenizes the full code string (not an isolated diff hunk / line range) so
// multi-line constructs like heredocs and template literals resolve
// correctly via Shiki's grammar continuation state, then returns one token
// array per line, suitable for rendering as <span>s.
export async function tokenizeLines(code: string, lang: HighlighterLanguageId, options: { performanceMarker?: string } = {}): Promise<ThemedToken[][]> {
  const key = tokenizationCacheKey(code, lang)
  const existing = tokenizationCache.get(key)
  if (existing) {
    // Re-insert so this entry becomes the newest, which is what makes
    // iteration order LRU rather than insertion order. Without it a hot
    // entry is evicted on its original schedule no matter how often the
    // view re-renders against it.
    tokenizationCache.delete(key)
    tokenizationCache.set(key, existing)
    return existing.promise
  }

  const marker = options.performanceMarker ? startMarker(options.performanceMarker, { maxPerSession: 300 }) : null
  const promise = (async () => {
    await loadLanguage(lang)
    const highlighter = await getHighlighter()
    return highlighter.codeToTokensBase(code, { lang, theme: HIGHLIGHTER_THEME_NAME })
  })()

  const retainable = code.length <= MAX_CACHEABLE_CHARACTERS
  const entry: TokenizationCacheEntry = { promise, tokenSpans: 0 }
  if (retainable) tokenizationCache.set(key, entry)

  promise.then(
    (tokens) => {
      const tokenSpans = tokens.reduce((sum, line) => sum + line.length, 0)
      // Only account spans if this entry is still the cached one: it may
      // have been evicted, or reset, while tokenization was in flight.
      if (tokenizationCache.get(key) === entry) {
        entry.tokenSpans = tokenSpans
        cachedTokenSpans += tokenSpans
        evictTokenizationsOverBudget(key)
      }
      if (marker) {
        endMarker(marker, {
          metadata: {
            character_count: Math.min(code.length, 1_000_000),
            language: lang,
            line_count: Math.min(tokens.length, 100_000),
            token_span_count: Math.min(tokenSpans, 1_000_000)
          }
        })
      }
    },
    () => {
      forgetTokenization(key)
      if (marker) endMarker(marker, { metadata: { character_count: Math.min(code.length, 1_000_000), error: true, language: lang } })
    }
  )
  return promise
}

export function resetHighlighterCachesForTest() {
  highlighterPromise = null
  tokenizationCache.clear()
  cachedTokenSpans = 0
  languagePromises.clear()
}

// Lets the regression test assert on what the cache retains rather than on
// how many times it was called -- the leak was invisible to call counts.
export function highlighterCacheStatsForTest() {
  return { entries: tokenizationCache.size, tokenSpans: cachedTokenSpans, maxTokenSpans: MAX_CACHED_TOKEN_SPANS, maxEntries: MAX_CACHED_ENTRIES }
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
  dockerfile: "dockerfile",
  py: "python",
  pyw: "python",
  pyi: "python",
  go: "go",
  rs: "rust",
  php: "php",
  phtml: "php",
  hh: "hack",
  hck: "hack",
  java: "java",
  c: "c",
  h: "c",
  cpp: "cpp",
  cxx: "cpp",
  cc: "cpp",
  hpp: "cpp",
  hxx: "cpp",
  hhpp: "cpp",
  cs: "csharp",
  kt: "kotlin",
  kts: "kotlin",
  swift: "swift",
  m: "objective-c",
  mm: "objective-cpp",
  scala: "scala",
  sc: "scala",
  dart: "dart",
  pl: "perl",
  pm: "perl",
  t: "perl",
  lua: "lua",
  ex: "elixir",
  exs: "elixir",
  erl: "erlang",
  hrl: "erlang",
  cr: "crystal",
  d: "d",
  ml: "ocaml",
  mli: "ocaml",
  pas: "pascal",
  pp: "pascal",
  lisp: "common-lisp",
  lsp: "common-lisp",
  l: "common-lisp",
  scm: "scheme",
  ss: "scheme",
  clj: "clojure",
  cljs: "clojure",
  cljc: "clojure",
  edn: "clojure",
  hs: "haskell",
  lhs: "haskell",
  coffee: "coffeescript",
  litcoffee: "coffeescript",
  vb: "vb",
  ps1: "powershell",
  psm1: "powershell",
  psd1: "powershell",
  applescript: "applescript",
  scpt: "applescript",
  awk: "awk",
  r: "r",
  rmd: "r",
  wasm: "wasm",
  wat: "wasm",
  wgsl: "wgsl",
  bib: "bibtex",
  haml: "haml",
  http: "http",
  jinja: "jinja",
  jinja2: "jinja",
  latex: "latex",
  tex: "tex",
  regexp: "regexp",
  regex: "regexp",
  rst: "rst",
  rest: "rst",
  less: "less",
  sass: "sass",
  scss: "scss",
  toml: "toml",
  ini: "ini",
  conf: "ini",
  cfg: "ini",
  xml: "xml",
  xsd: "xml",
  xsl: "xsl",
  xslt: "xsl",
  csv: "csv",
  tsv: "tsv",
  env: "dotenv",
  hcl: "hcl",
  tf: "terraform",
  tfvars: "terraform",
  cmake: "cmake",
  mk: "makefile",
  mak: "makefile",
  make: "makefile",
  gnuplot: "gnuplot",
  gp: "gnuplot",
  plot: "gnuplot",
  scad: "openscad",
  graphql: "graphql",
  gql: "graphql",
  proto: "protobuf",
  desktop: "desktop",
  diff: "diff",
  patch: "diff"
}

const FILENAME_LANGUAGE_MAP: Record<string, HighlighterLanguageId> = {
  gemfile: "ruby",
  rakefile: "ruby",
  "config.ru": "ruby",
  dockerfile: "dockerfile",
  makefile: "makefile",
  gnumakefile: "makefile",
  "cmakelists.txt": "cmake",
  ".env": "dotenv",
  ".env.local": "dotenv",
  ".env.development": "dotenv",
  ".env.test": "dotenv",
  ".env.production": "dotenv"
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
const FENCE_LANGUAGE_ALIASES: Record<string, HighlighterLanguageId> = {
  "c++": "cpp",
  "c#": "csharp"
}

// Maps a Markdown fenced code block's info string (e.g. the `ruby` in
// ```ruby) to a highlighter language id. Accepts both canonical ids
// ("ruby", "typescript") and the file-extension aliases
// detectHighlighterLanguage() already understands ("rb", "ts", "yml").
export function detectFenceLanguage(hint: string): HighlighterLanguageId | null {
  const normalized = hint.trim().toLowerCase()
  if (!normalized) return null
  if (FENCE_LANGUAGE_ALIASES[normalized]) return FENCE_LANGUAGE_ALIASES[normalized]
  if (HIGHLIGHTER_LANGUAGE_IDS.has(normalized)) return normalized as HighlighterLanguageId

  return detectHighlighterLanguage(`fence.${normalized}`)
}
