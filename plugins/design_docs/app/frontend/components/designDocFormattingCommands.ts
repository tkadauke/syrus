export type DesignDocFormattingCommand =
  | "bold"
  | "italic"
  | "inline_code"
  | "link"
  | "strikethrough"
  | "paragraph"
  | "heading_1"
  | "heading_2"
  | "heading_3"
  | "heading_4"
  | "blockquote"
  | "fenced_code"
  | "unordered_list"
  | "ordered_list"
  | "nested_list"
  | "horizontal_rule"
  | "table"

export type DesignDocFormattingSelection = {
  start: number
  end: number
}

export type DesignDocFormattingOptions = {
  href?: string
  tableColumns?: number
  tableRows?: number
}

export type DesignDocFormattingResult = {
  markdown: string
  selection: DesignDocFormattingSelection
  applied: boolean
}

type ProtectedSpan = { start: number; end: number; kind: "anchor" | "code" | "fence" | "link" }
type LineRange = { start: number; end: number }

const ANCHOR_MARKER_PATTERN = /<!--\s*syrus:(?:anchor|range-start|range-end)\s+id="[^"]+"\s*-->/g

export function applyDesignDocFormattingCommand(markdown: string, selection: DesignDocFormattingSelection, command: DesignDocFormattingCommand, options: DesignDocFormattingOptions = {}): DesignDocFormattingResult {
  const source = markdown.replace(/\r\n?/g, "\n")
  const range = normalizeSelection(source, selection)

  if (isInlineCommand(command)) return applyInlineCommand(source, range, command, options)

  return applyBlockCommand(source, range, command, options)
}

function applyInlineCommand(markdown: string, selection: DesignDocFormattingSelection, command: DesignDocFormattingCommand, options: DesignDocFormattingOptions): DesignDocFormattingResult {
  if (selectionTouchesProtectedMarkdown(markdown, selection)) {
    return unchanged(markdown, selection)
  }

  if (command === "link") {
    const href = sanitizeMarkdownHref(options.href || "https://example.com")
    if (!href) return unchanged(markdown, selection)

    return replaceSelection(markdown, selection, (selected) => {
      const text = selected || "link text"
      return `[${escapeLinkText(text)}](${href})`
    })
  }

  const markers = inlineMarkers(command)
  if (!markers) return unchanged(markdown, selection)

  return replaceSelection(markdown, selection, (selected) => {
    if (!selected) return `${markers.open}${placeholderFor(command)}${markers.close}`
    return `${markers.open}${selected}${markers.close}`
  })
}

function applyBlockCommand(markdown: string, selection: DesignDocFormattingSelection, command: DesignDocFormattingCommand, options: DesignDocFormattingOptions): DesignDocFormattingResult {
  if (command === "horizontal_rule") return selectionTouchesBlockProtectedMarkdown(markdown, selection) ? unchanged(markdown, selection) : insertBlock(markdown, selection, "---")
  if (command === "table") return selectionTouchesBlockProtectedMarkdown(markdown, selection) ? unchanged(markdown, selection) : insertTable(markdown, selection, options)
  if (command === "fenced_code") return selectionTouchesBlockProtectedMarkdown(markdown, selection) ? unchanged(markdown, selection) : fenceSelection(markdown, selection)

  const lineRange = selectedLineRange(markdown, selection)
  const protectedRanges = blockProtectedSpans(markdown)
  const block = markdown.slice(lineRange.start, lineRange.end)
  const lines = block.split("\n")
  let lineStart = lineRange.start
  const nextLines = lines.map((line, index) => {
    const lineEnd = lineStart + line.length
    const nextLine = rangeTouchesProtectedSpan(lineStart, lineEnd, protectedRanges) ? line : formatLine(line, command, index)
    lineStart = lineEnd + 1
    return nextLine
  })
  const nextBlock = nextLines.join("\n")

  return replaceRange(markdown, lineRange, nextBlock)
}

function formatLine(line: string, command: DesignDocFormattingCommand, index: number) {
  if (line.trim().length === 0) return line

  const bare = removeBlockPrefix(line)
  if (command === "paragraph") return bare
  if (command === "blockquote") return `> ${bare}`
  if (command === "unordered_list") return `${leadingWhitespace(line)}- ${removeListPrefix(bare)}`
  if (command === "ordered_list") return `${leadingWhitespace(line)}${index + 1}. ${removeListPrefix(bare)}`
  if (command === "nested_list") return `   ${line}`

  const heading = command.match(/^heading_(\d)$/)
  if (heading) return `${"#".repeat(Number(heading[1]))} ${bare}`

  return line
}

function fenceSelection(markdown: string, selection: DesignDocFormattingSelection) {
  const lineRange = selectedLineRange(markdown, selection)
  const selected = markdown.slice(lineRange.start, lineRange.end)
  if (/^\s*```/.test(selected) && /```\s*$/.test(selected)) return unchanged(markdown, selection)

  const longestFence = selected.match(/`{3,}/g)?.reduce((longest, fence) => Math.max(longest, fence.length), 2) ?? 2
  const fence = "`".repeat(longestFence + 1)
  return replaceRange(markdown, lineRange, `${fence}\n${selected}\n${fence}`)
}

function insertTable(markdown: string, selection: DesignDocFormattingSelection, options: DesignDocFormattingOptions) {
  const columns = Math.max(1, Math.min(8, Math.trunc(options.tableColumns ?? 2)))
  const rows = Math.max(1, Math.min(20, Math.trunc(options.tableRows ?? 2)))
  const headers = Array.from({ length: columns }, (_value, index) => `Column ${index + 1}`)
  const body = Array.from({ length: rows }, () => Array.from({ length: columns }, () => ""))
  const table = [
    tableRow(headers),
    tableRow(headers.map(() => "---")),
    ...body.map((row) => tableRow(row))
  ].join("\n")

  return insertBlock(markdown, selection, table)
}

function insertBlock(markdown: string, selection: DesignDocFormattingSelection, block: string) {
  const before = markdown.slice(0, selection.start)
  const after = markdown.slice(selection.end)
  const prefix = before.length === 0 || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n"
  const suffix = after.length === 0 || after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n"
  const inserted = `${prefix}${block}${suffix}`
  const next = `${before}${inserted}${after}`
  const insertedStart = before.length + prefix.length

  return {
    markdown: next,
    selection: { start: insertedStart, end: insertedStart + block.length },
    applied: true
  }
}

function replaceSelection(markdown: string, selection: DesignDocFormattingSelection, replacementFor: (selected: string) => string): DesignDocFormattingResult {
  const selected = markdown.slice(selection.start, selection.end)
  const replacement = replacementFor(selected)

  return replaceRange(markdown, selection, replacement)
}

function replaceRange(markdown: string, range: DesignDocFormattingSelection | LineRange, replacement: string): DesignDocFormattingResult {
  return {
    markdown: `${markdown.slice(0, range.start)}${replacement}${markdown.slice(range.end)}`,
    selection: { start: range.start, end: range.start + replacement.length },
    applied: true
  }
}

function unchanged(markdown: string, selection: DesignDocFormattingSelection): DesignDocFormattingResult {
  return { markdown, selection, applied: false }
}

function inlineMarkers(command: DesignDocFormattingCommand) {
  if (command === "bold") return { open: "**", close: "**" }
  if (command === "italic") return { open: "*", close: "*" }
  if (command === "inline_code") return { open: "`", close: "`" }
  if (command === "strikethrough") return { open: "~~", close: "~~" }
  return null
}

function placeholderFor(command: DesignDocFormattingCommand) {
  return command === "inline_code" ? "code" : "text"
}

function isInlineCommand(command: DesignDocFormattingCommand) {
  return ["bold", "italic", "inline_code", "link", "strikethrough"].includes(command)
}

function selectedLineRange(markdown: string, selection: DesignDocFormattingSelection): LineRange {
  const start = markdown.lastIndexOf("\n", Math.max(0, selection.start - 1)) + 1
  const nextLine = markdown.indexOf("\n", selection.end)
  const end = nextLine === -1 ? markdown.length : nextLine

  return { start, end }
}

function normalizeSelection(markdown: string, selection: DesignDocFormattingSelection): DesignDocFormattingSelection {
  const start = Math.max(0, Math.min(markdown.length, selection.start))
  const end = Math.max(0, Math.min(markdown.length, selection.end))
  return start <= end ? { start, end } : { start: end, end: start }
}

function removeBlockPrefix(line: string) {
  return line
    .replace(/^\s{0,3}#{1,6}\s+/, "")
    .replace(/^\s*>\s?/, "")
    .replace(/^(\s*)(?:[-*+]|\d+[.)])\s+/, "$1")
}

function removeListPrefix(line: string) {
  return line.replace(/^(\s*)(?:[-*+]|\d+[.)])\s+/, "$1")
}

function leadingWhitespace(line: string) {
  return line.match(/^\s*/)?.[0] ?? ""
}

function tableRow(cells: string[]) {
  return `| ${cells.join(" | ")} |`
}

function selectionTouchesProtectedMarkdown(markdown: string, selection: DesignDocFormattingSelection) {
  if (selection.start === selection.end) return false

  return protectedSpans(markdown).some((span) => rangesOverlap(selection.start, selection.end, span.start, span.end))
}

function selectionTouchesBlockProtectedMarkdown(markdown: string, selection: DesignDocFormattingSelection) {
  if (selection.start === selection.end) {
    return blockProtectedSpans(markdown).some((span) => selection.start > span.start && selection.start < span.end)
  }

  return rangeTouchesProtectedSpan(selection.start, selection.end, blockProtectedSpans(markdown))
}

function rangeTouchesProtectedSpan(start: number, end: number, spans: ProtectedSpan[]) {
  return spans.some((span) => rangesOverlap(start, end, span.start, span.end))
}

function protectedSpans(markdown: string): ProtectedSpan[] {
  return [
    ...regexSpans(markdown, ANCHOR_MARKER_PATTERN, "anchor"),
    ...fencedCodeSpans(markdown),
    ...regexSpans(markdown, /`[^`\n]+`/g, "code"),
    ...regexSpans(markdown, /\[[^\]\n]+\]\([^) \n]+(?:\s+"[^"]*")?\)/g, "link")
  ].sort((a, b) => a.start - b.start || a.end - b.end)
}

function blockProtectedSpans(markdown: string) {
  return [
    ...regexSpans(markdown, ANCHOR_MARKER_PATTERN, "anchor"),
    ...fencedCodeSpans(markdown)
  ].sort((a, b) => a.start - b.start || a.end - b.end)
}

function regexSpans(markdown: string, pattern: RegExp, kind: ProtectedSpan["kind"]): ProtectedSpan[] {
  return Array.from(markdown.matchAll(pattern)).map((match) => ({
    start: match.index ?? 0,
    end: (match.index ?? 0) + match[0].length,
    kind
  }))
}

function fencedCodeSpans(markdown: string): ProtectedSpan[] {
  const spans: ProtectedSpan[] = []
  const pattern = /^```[\w.-]*\s*$[\s\S]*?^```\s*$/gm
  for (const match of markdown.matchAll(pattern)) {
    const start = match.index ?? 0
    spans.push({ start, end: start + match[0].length, kind: "fence" })
  }
  return spans
}

function rangesOverlap(startA: number, endA: number, startB: number, endB: number) {
  return startA < endB && startB < endA
}

function sanitizeMarkdownHref(href: string) {
  const value = href.trim()
  if (value.startsWith("/") || value.startsWith("#")) return value

  try {
    const url = new URL(value, window.location.origin)
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? value : null
  } catch (_error) {
    return null
  }
}

function escapeLinkText(text: string) {
  return text.replace(/\]/g, "\\]")
}
