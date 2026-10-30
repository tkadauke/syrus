import { describe, expect, it, vi } from "vitest"
import * as performanceMarkers from "./performanceMarkers"
import { HIGHLIGHTER_CSS_VARIABLE_PREFIX, detectFenceLanguage, detectHighlighterLanguage, highlighterCacheStatsForTest, resetHighlighterCachesForTest, tokenizeLines } from "./highlighter"

function textOf(line: { content: string }[]) {
  return line.map((token) => token.content).join("")
}

describe("tokenizeLines", () => {
  it("coalesces concurrent identical tokenization and reuses the stable cached result", async () => {
    resetHighlighterCachesForTest()
    const first = tokenizeLines("class Job; end", "ruby")
    const second = tokenizeLines("class Job; end", "ruby")
    const [firstResult, secondResult] = await Promise.all([first, second])

    expect(secondResult).toBe(firstResult)
    expect(await tokenizeLines("class Job; end", "ruby")).toBe(firstResult)
  })

  // Regression: the tokenization cache was budgeted by entry count (200) and
  // keyed by the full source text, at module scope with no release path. An
  // entry count says nothing about retained memory -- one entry can be ten
  // lines or ten thousand -- so a session that browsed enough review diffs or
  // chat code blocks held tens of MB of ThemedToken objects, plus a second
  // copy of every file's text in the keys, for as long as the tab lived. iOS
  // Safari jetsams the web process at its per-tab ceiling, which surfaced as
  // a reload loop on whichever page was open rather than on the pages that
  // filled the cache -- and so looked like a problem with specific small
  // diffs. These assert on what the cache *retains*, because the leak was
  // invisible to call counts and to every result-correctness test above.
  describe("cache budget", () => {
    // Distinct, non-trivial sources so each one tokenizes to many spans.
    function sourceFor(index: number) {
      return Array.from({ length: 40 }, (_, line) => `def method_${index}_${line}(argument_${line}) = argument_${line}.to_s # note ${index}`).join("\n")
    }

    it("stays inside its token-span budget no matter how many distinct files are highlighted", async () => {
      resetHighlighterCachesForTest()

      for (let i = 0; i < 120; i++) {
        await tokenizeLines(sourceFor(i), "ruby")
      }

      const stats = highlighterCacheStatsForTest()
      expect(stats.tokenSpans).toBeLessThanOrEqual(stats.maxTokenSpans)
      expect(stats.entries).toBeLessThanOrEqual(stats.maxEntries)
      // The point of the budget is that it actually evicted: 120 files worth
      // of spans must not all still be resident.
      expect(stats.entries).toBeLessThan(120)
    })

    it("still returns the identical cached promise for a repeated file", async () => {
      resetHighlighterCachesForTest()
      const code = sourceFor(0)

      const first = await tokenizeLines(code, "ruby")
      const second = await tokenizeLines(code, "ruby")

      expect(second).toBe(first)
      expect(highlighterCacheStatsForTest().entries).toBe(1)
    })

    it("keeps a recently-used entry and evicts colder ones instead", async () => {
      resetHighlighterCachesForTest()
      const hot = sourceFor(9_000)
      const hotTokens = await tokenizeLines(hot, "ruby")

      for (let i = 0; i < 80; i++) {
        await tokenizeLines(sourceFor(i), "ruby")
        // Touching the hot entry re-inserts it as newest, so LRU order must
        // spare it even though it was cached first.
        await tokenizeLines(hot, "ruby")
      }

      expect(await tokenizeLines(hot, "ruby")).toBe(hotTokens)
    })

    it("does not retain a file larger than the per-entry cap", async () => {
      resetHighlighterCachesForTest()
      const huge = Array.from({ length: 4_000 }, (_, line) => `# padding line ${line} ${"x".repeat(60)}`).join("\n")
      expect(huge.length).toBeGreaterThan(128 * 1024)

      const tokens = await tokenizeLines(huge, "ruby")

      expect(tokens.length).toBe(4_000)
      // Tokenized and returned, simply not held afterwards.
      expect(highlighterCacheStatsForTest().entries).toBe(0)
    })

    it("releases a failed tokenization instead of caching a rejected promise", async () => {
      resetHighlighterCachesForTest()

      await expect(tokenizeLines("whatever", "not-a-language" as never)).rejects.toThrow()

      expect(highlighterCacheStatsForTest().entries).toBe(0)
    })
  })

  it("attributes shared highlighter initialization once across concurrent callers", async () => {
    resetHighlighterCachesForTest()
    const startMarker = vi.spyOn(performanceMarkers, "startMarker")

    await Promise.all([tokenizeLines("class Job; end", "ruby"), tokenizeLines("const job = {}", "typescript")])

    expect(startMarker.mock.calls.filter(([name]) => name === "diff_review.highlighter_initialize")).toHaveLength(1)
    startMarker.mockRestore()
  })

  it("colors tokens with var(--shiki-*) custom properties, not literal colors", async () => {
    const code = 'def greeting\n  "hi" # comment\nend'
    const lines = await tokenizeLines(code, "ruby")

    const keywordToken = lines[0].find((token) => token.content === "def")
    const stringToken = lines[1].find((token) => token.content.includes("hi"))
    const commentToken = lines[1].find((token) => token.content.includes("comment"))

    expect(keywordToken?.color).toBe(`var(${HIGHLIGHTER_CSS_VARIABLE_PREFIX}token-keyword)`)
    expect(commentToken?.color).toBe(`var(${HIGHLIGHTER_CSS_VARIABLE_PREFIX}token-comment)`)
    // Different scopes resolve to different --shiki-token-* variables, so
    // theme-appropriate colors can differ per token category once the CSS
    // custom properties are defined (Theme::SYNTAX_TOKEN_KEYS).
    expect(stringToken?.color).not.toBe(keywordToken?.color)
    expect(stringToken?.color).not.toBe(commentToken?.color)

    const prefixPattern = new RegExp(`^var\\(${HIGHLIGHTER_CSS_VARIABLE_PREFIX}`)
    for (const token of [keywordToken, stringToken, commentToken]) {
      expect(token?.color).toMatch(prefixPattern)
    }
  })

  it("carries a multi-line ruby heredoc's string scope across every line it spans", async () => {
    const code = ["def greeting", "  message = <<~TEXT", "    Hello there,", "    this spans multiple lines.", "  TEXT", "  message", "end"].join("\n")

    const lines = await tokenizeLines(code, "ruby")

    expect(lines).toHaveLength(7)
    lines.forEach((line, index) => expect(textOf(line)).toBe(code.split("\n")[index]))

    // The heredoc body lines (indices 2-3) have no string-opening syntax of
    // their own — only the grammar's continuation state from line 1 marks
    // them as string content. If tokenization were done per-line instead of
    // against the full file, these would fall back to plain/default tokens.
    const heredocOpenLine = lines[1]
    const heredocBodyLine = lines[2]
    const heredocBodyLine2 = lines[3]
    const heredocCloseLine = lines[4]
    const afterHeredocLine = lines[5]

    const stringColorOf = (line: { content: string; color?: string }[]) => line.find((token) => token.content.trim().length > 0)?.color

    const heredocMarkerColor = heredocOpenLine.find((token) => token.content.includes("<<~TEXT"))?.color
    expect(heredocMarkerColor).toBeTruthy()

    expect(stringColorOf(heredocBodyLine)).toBe(heredocMarkerColor)
    expect(stringColorOf(heredocBodyLine2)).toBe(heredocMarkerColor)
    expect(stringColorOf(heredocCloseLine)).toBe(heredocMarkerColor)

    // Back to plain ruby identifiers once the heredoc has closed.
    expect(stringColorOf(afterHeredocLine)).not.toBe(heredocMarkerColor)
  })

  it("carries a multi-line JS/TS template literal's string scope across every line it spans", async () => {
    const code = ["const greeting = `Hello", "  multi", "  line`", "const other = 1"].join("\n")

    const lines = await tokenizeLines(code, "typescript")

    expect(lines).toHaveLength(4)
    lines.forEach((line, index) => expect(textOf(line)).toBe(code.split("\n")[index]))

    const openLine = lines[0]
    const middleLine = lines[1]
    const closeLine = lines[2]
    const afterLine = lines[3]

    const templateColor = openLine.find((token) => token.content.includes("`Hello"))?.color
    expect(templateColor).toBeTruthy()

    const colorOf = (line: { content: string; color?: string }[]) => line.find((token) => token.content.trim().length > 0)?.color

    expect(colorOf(middleLine)).toBe(templateColor)
    expect(colorOf(closeLine)).toBe(templateColor)
    expect(colorOf(afterLine)).not.toBe(templateColor)
  })

  it("carries a multi-line python string scope across every line it spans", async () => {
    const code = ['message = """Hello', "  multi", '  line"""', "other = 1"].join("\n")

    const lines = await tokenizeLines(code, "python")

    expect(lines).toHaveLength(4)
    lines.forEach((line, index) => expect(textOf(line)).toBe(code.split("\n")[index]))

    const openLine = lines[0]
    const middleLine = lines[1]
    const closeLine = lines[2]
    const afterLine = lines[3]

    const stringColor = openLine.find((token) => token.content.includes('"""Hello'))?.color
    expect(stringColor).toBeTruthy()

    const colorOf = (line: { content: string; color?: string }[]) => line.find((token) => token.content.trim().length > 0)?.color

    expect(colorOf(middleLine)).toBe(stringColor)
    expect(colorOf(closeLine)).toBe(stringColor)
    expect(colorOf(afterLine)).not.toBe(stringColor)
  })
})

describe("detectHighlighterLanguage", () => {
  it("maps common file paths and extensions to a highlighter language id", () => {
    expect(detectHighlighterLanguage("app/models/job.rb")).toBe("ruby")
    expect(detectHighlighterLanguage("Gemfile")).toBe("ruby")
    expect(detectHighlighterLanguage("Rakefile")).toBe("ruby")
    expect(detectHighlighterLanguage("config.ru")).toBe("ruby")
    expect(detectHighlighterLanguage("app/frontend/lib/highlighter.ts")).toBe("typescript")
    expect(detectHighlighterLanguage("app/frontend/App.tsx")).toBe("tsx")
    expect(detectHighlighterLanguage("app/frontend/App.jsx")).toBe("jsx")
    expect(detectHighlighterLanguage("script.js")).toBe("javascript")
    expect(detectHighlighterLanguage("package.json")).toBe("json")
    expect(detectHighlighterLanguage("config/routes.rb")).toBe("ruby")
    expect(detectHighlighterLanguage(".github/workflows/ci.yml")).toBe("yaml")
    expect(detectHighlighterLanguage("db/seeds.sql")).toBe("sql")
    expect(detectHighlighterLanguage("bin/setup.sh")).toBe("shellscript")
    expect(detectHighlighterLanguage("app/views/layouts/application.html.erb")).toBe("erb")
    expect(detectHighlighterLanguage("index.html")).toBe("html")
    expect(detectHighlighterLanguage("app.css")).toBe("css")
    expect(detectHighlighterLanguage("README.md")).toBe("markdown")
    expect(detectHighlighterLanguage("Dockerfile")).toBe("dockerfile")
    expect(detectHighlighterLanguage("cli/main.go")).toBe("go")
    expect(detectHighlighterLanguage("src/lib.rs")).toBe("rust")
    expect(detectHighlighterLanguage("src/main.py")).toBe("python")
    expect(detectHighlighterLanguage("src/App.kt")).toBe("kotlin")
    expect(detectHighlighterLanguage("Sources/App.swift")).toBe("swift")
    expect(detectHighlighterLanguage("src/main.m")).toBe("objective-c")
    expect(detectHighlighterLanguage("src/main.mm")).toBe("objective-cpp")
    expect(detectHighlighterLanguage("src/main.cpp")).toBe("cpp")
    expect(detectHighlighterLanguage("src/main.cs")).toBe("csharp")
    expect(detectHighlighterLanguage("src/main.clj")).toBe("clojure")
    expect(detectHighlighterLanguage("src/main.hs")).toBe("haskell")
    expect(detectHighlighterLanguage("src/main.ps1")).toBe("powershell")
    expect(detectHighlighterLanguage("src/main.wgsl")).toBe("wgsl")
    expect(detectHighlighterLanguage("src/template.haml")).toBe("haml")
    expect(detectHighlighterLanguage("src/main.scss")).toBe("scss")
    expect(detectHighlighterLanguage("Cargo.toml")).toBe("toml")
    expect(detectHighlighterLanguage(".env")).toBe("dotenv")
    expect(detectHighlighterLanguage("main.tf")).toBe("terraform")
    expect(detectHighlighterLanguage("variables.tfvars")).toBe("terraform")
    expect(detectHighlighterLanguage("CMakeLists.txt")).toBe("cmake")
    expect(detectHighlighterLanguage("Makefile")).toBe("makefile")
    expect(detectHighlighterLanguage("schema.graphql")).toBe("graphql")
    expect(detectHighlighterLanguage("schema.proto")).toBe("protobuf")
    expect(detectHighlighterLanguage("app.desktop")).toBe("desktop")
    expect(detectHighlighterLanguage("changes.patch")).toBe("diff")
  })

  it("does not auto-detect Angular's enhanced grammars from plain HTML or TypeScript extensions", () => {
    expect(detectHighlighterLanguage("app.component.html")).toBe("html")
    expect(detectHighlighterLanguage("app.component.ts")).toBe("typescript")
  })

  it("returns null for unrecognized paths", () => {
    expect(detectHighlighterLanguage("")).toBeNull()
    expect(detectHighlighterLanguage("LICENSE")).toBeNull()
    expect(detectHighlighterLanguage("app/frontend/lib/foo.unknownext")).toBeNull()
  })
})

describe("detectFenceLanguage", () => {
  it("accepts canonical highlighter language ids directly", () => {
    expect(detectFenceLanguage("ruby")).toBe("ruby")
    expect(detectFenceLanguage("typescript")).toBe("typescript")
    expect(detectFenceLanguage("TSX")).toBe("tsx")
    expect(detectFenceLanguage("python")).toBe("python")
    expect(detectFenceLanguage("angular-html")).toBe("angular-html")
    expect(detectFenceLanguage("angular-ts")).toBe("angular-ts")
  })

  it("accepts the same extension aliases detectHighlighterLanguage understands", () => {
    expect(detectFenceLanguage("rb")).toBe("ruby")
    expect(detectFenceLanguage("js")).toBe("javascript")
    expect(detectFenceLanguage("yml")).toBe("yaml")
    expect(detectFenceLanguage("sh")).toBe("shellscript")
    expect(detectFenceLanguage("py")).toBe("python")
    expect(detectFenceLanguage("gql")).toBe("graphql")
    expect(detectFenceLanguage("c++")).toBe("cpp")
    expect(detectFenceLanguage("c#")).toBe("csharp")
  })

  it("returns null for an empty or unrecognized hint", () => {
    expect(detectFenceLanguage("")).toBeNull()
    expect(detectFenceLanguage("not-a-real-language")).toBeNull()
  })
})
