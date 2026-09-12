import { createHighlighterCore, createCssVariablesTheme } from "@shikijs/core"
import { createOnigurumaEngine } from "@shikijs/engine-oniguruma"
import type { HighlighterCore, LanguageInput, ThemedToken } from "@shikijs/core"

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
