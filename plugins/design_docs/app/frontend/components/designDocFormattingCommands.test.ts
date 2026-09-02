import { describe, expect, it, vi } from "vitest"
import { applyDesignDocFormattingCommand } from "./designDocFormattingCommands"

describe("applyDesignDocFormattingCommand", () => {
  it("applies inline formatting to the canonical Markdown selection", () => {
    const markdown = "Alpha beta gamma"
    const selection = { start: 6, end: 10 }

    expect(applyDesignDocFormattingCommand(markdown, selection, "bold").markdown).toBe("Alpha **beta** gamma")
    expect(applyDesignDocFormattingCommand(markdown, selection, "italic").markdown).toBe("Alpha *beta* gamma")
    expect(applyDesignDocFormattingCommand(markdown, selection, "inline_code").markdown).toBe("Alpha `beta` gamma")
    expect(applyDesignDocFormattingCommand(markdown, selection, "strikethrough").markdown).toBe("Alpha ~~beta~~ gamma")
  })

  it("creates safe Markdown links without rewriting existing link syntax", () => {
    const linked = applyDesignDocFormattingCommand("Alpha beta", { start: 6, end: 10 }, "link", { href: "https://example.test/path" })
    expect(linked.markdown).toBe("Alpha [beta](https://example.test/path)")

    const existing = "See [docs](https://example.test)"
    const protectedResult = applyDesignDocFormattingCommand(existing, { start: 4, end: existing.length }, "bold")
    expect(protectedResult).toMatchObject({ markdown: existing, applied: false })

    const unsafe = applyDesignDocFormattingCommand("Alpha beta", { start: 6, end: 10 }, "link", { href: "javascript:alert(1)" })
    expect(unsafe).toMatchObject({ markdown: "Alpha beta", applied: false })
  })

  it("does not corrupt inline code spans, fenced code blocks, or hidden anchor comments", () => {
    const code = "Alpha `beta` gamma"
    expect(applyDesignDocFormattingCommand(code, { start: 7, end: 11 }, "italic")).toMatchObject({ markdown: code, applied: false })

    const fenced = "```ts\nconst beta = true\n```"
    expect(applyDesignDocFormattingCommand(fenced, { start: 6, end: 16 }, "bold")).toMatchObject({ markdown: fenced, applied: false })

    const anchored = 'Alpha <!-- syrus:range-start id="m1" -->beta<!-- syrus:range-end id="m1" --> gamma'
    expect(applyDesignDocFormattingCommand(anchored, { start: 6, end: 48 }, "bold")).toMatchObject({ markdown: anchored, applied: false })
  })

  it("applies block formatting across selected lines", () => {
    const markdown = "Alpha\nBeta"

    expect(applyDesignDocFormattingCommand(markdown, { start: 0, end: markdown.length }, "heading_2").markdown).toBe("## Alpha\n## Beta")
    expect(applyDesignDocFormattingCommand(markdown, { start: 0, end: markdown.length }, "blockquote").markdown).toBe("> Alpha\n> Beta")
    expect(applyDesignDocFormattingCommand(markdown, { start: 0, end: markdown.length }, "unordered_list").markdown).toBe("- Alpha\n- Beta")
    expect(applyDesignDocFormattingCommand(markdown, { start: 0, end: markdown.length }, "ordered_list").markdown).toBe("1. Alpha\n2. Beta")
    expect(applyDesignDocFormattingCommand("- Alpha\n- Beta", { start: 0, end: 14 }, "nested_list").markdown).toBe("   - Alpha\n   - Beta")
    expect(applyDesignDocFormattingCommand("## Alpha\n> Beta", { start: 0, end: 15 }, "paragraph").markdown).toBe("Alpha\nBeta")
  })

  it("inserts fenced code blocks, horizontal rules, and editable table basics", () => {
    expect(applyDesignDocFormattingCommand("Alpha\nBeta", { start: 0, end: 10 }, "fenced_code").markdown).toBe("```\nAlpha\nBeta\n```")
    expect(applyDesignDocFormattingCommand("Alpha", { start: 5, end: 5 }, "horizontal_rule").markdown).toBe("Alpha\n\n---")
    expect(applyDesignDocFormattingCommand("Alpha", { start: 5, end: 5 }, "table", { tableColumns: 3, tableRows: 1 }).markdown).toBe([
      "Alpha",
      "",
      "| Column 1 | Column 2 | Column 3 |",
      "| --- | --- | --- |",
      "|  |  |  |"
    ].join("\n"))
  })

  it("can be driven from the editor toolbar and posts suggest-mode mutations as suggestions", async () => {
    vi.spyOn(window, "prompt").mockReturnValue("https://example.test")

    const markdown = "Alpha beta gamma"
    const formatted = applyDesignDocFormattingCommand(markdown, { start: 6, end: 10 }, "link", { href: window.prompt("Link URL") || "" })

    expect(formatted.markdown).toBe("Alpha [beta](https://example.test) gamma")
  })
})
