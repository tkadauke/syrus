import { describe, expect, it } from "vitest"
import { detectHighlighterLanguage, tokenizeLines } from "./highlighter"

function textOf(line: { content: string }[]) {
  return line.map((token) => token.content).join("")
}

describe("tokenizeLines", () => {
  it("carries a multi-line ruby heredoc's string scope across every line it spans", async () => {
    const code = [
      "def greeting",
      "  message = <<~TEXT",
      "    Hello there,",
      "    this spans multiple lines.",
      "  TEXT",
      "  message",
      "end"
    ].join("\n")

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

    const stringColorOf = (line: { content: string; color?: string }[]) =>
      line.find((token) => token.content.trim().length > 0)?.color

    const heredocMarkerColor = heredocOpenLine.find((token) => token.content.includes("<<~TEXT"))?.color
    expect(heredocMarkerColor).toBeTruthy()

    expect(stringColorOf(heredocBodyLine)).toBe(heredocMarkerColor)
    expect(stringColorOf(heredocBodyLine2)).toBe(heredocMarkerColor)
    expect(stringColorOf(heredocCloseLine)).toBe(heredocMarkerColor)

    // Back to plain ruby identifiers once the heredoc has closed.
    expect(stringColorOf(afterHeredocLine)).not.toBe(heredocMarkerColor)
  })

  it("carries a multi-line JS/TS template literal's string scope across every line it spans", async () => {
    const code = [
      "const greeting = `Hello",
      "  multi",
      "  line`",
      "const other = 1"
    ].join("\n")

    const lines = await tokenizeLines(code, "typescript")

    expect(lines).toHaveLength(4)
    lines.forEach((line, index) => expect(textOf(line)).toBe(code.split("\n")[index]))

    const openLine = lines[0]
    const middleLine = lines[1]
    const closeLine = lines[2]
    const afterLine = lines[3]

    const templateColor = openLine.find((token) => token.content.includes("`Hello"))?.color
    expect(templateColor).toBeTruthy()

    const colorOf = (line: { content: string; color?: string }[]) =>
      line.find((token) => token.content.trim().length > 0)?.color

    expect(colorOf(middleLine)).toBe(templateColor)
    expect(colorOf(closeLine)).toBe(templateColor)
    expect(colorOf(afterLine)).not.toBe(templateColor)
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
  })

  it("returns null for unrecognized paths", () => {
    expect(detectHighlighterLanguage("")).toBeNull()
    expect(detectHighlighterLanguage("LICENSE")).toBeNull()
    expect(detectHighlighterLanguage("app/frontend/lib/foo.unknownext")).toBeNull()
  })
})
