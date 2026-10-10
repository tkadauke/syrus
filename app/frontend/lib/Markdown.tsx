import { Fragment, useLayoutEffect, useRef, useState, type CSSProperties, type MouseEvent, type ReactNode } from "react"
import katex from "katex"
import "katex/dist/katex.min.css"
import { containsSlug, linkifySlugs } from "./linkifySlugs"
import { CodeBlock } from "../components/CodeBlock"
import { detectFenceLanguage } from "./highlighter"

type InlineToken = string | ReactNode
export type MarkdownLinkHandler = (href: string, event: MouseEvent<HTMLAnchorElement>) => void
type SlugTone = "default" | "inverted"
type RenderInlineOptions = { linkifySlugs?: boolean; linkifyUrls?: boolean; onLinkClick?: MarkdownLinkHandler; renderMath?: boolean; slugTone?: SlugTone }
type InlineMatch = { index: number; token: string }
type ListMarker = { indent: number; ordered: boolean; value?: number; content: string }
type ListItem = { content: string; nested: ReactNode[]; value?: number }
type MarkdownProps = { className?: string; text: string; linkifyUrls?: boolean; onLinkClick?: MarkdownLinkHandler; slugTone?: SlugTone }
type PlainTextProps = { className?: string; text: string; linkifyUrls?: boolean; onLinkClick?: MarkdownLinkHandler; slugTone?: SlugTone }
type TableColumnKind = "compact" | "label" | "prose"
type TableColumnHint = { kind: TableColumnKind; width: string }
type TableColumnMeasurement = { kind: TableColumnKind; min: number; preferred: number }
type TableColumnLayout = { wide: boolean; widths: number[] }
const MARKDOWN_SAFE_LINE_CHARS = 2_000
const INLINE_MARKDOWN_PATTERN = /(`[^`]+`|\[[^\]\n]+\]\([^) \n]+(?:\s+"[^"\n]+")?\)|~~[^~\n]+~~|\*\*(?:(?!\*\*)[\s\S])+\*\*|\*[^*\n]+\*)/g
const PLAIN_URL_PATTERN = /\bhttps?:\/\/[^\s<>"'`]+/gi
const WIDE_TABLE_COLUMN_COUNT = 5
const MIN_COLUMN_WIDTHS: Record<TableColumnKind, number> = { compact: 44, label: 72, prose: 96 }
const TABLE_COLUMN_WEIGHTS: Record<TableColumnKind, number> = {
  compact: 0.45,
  label: 1.15,
  prose: 2.4
}

export function Markdown({ className, text, linkifyUrls = false, onLinkClick, slugTone }: MarkdownProps) {
  const preview = safeMarkdownPreview(text)

  return <div className={["chat-prose", className].filter(Boolean).join(" ")}>{renderBlocks(preview, { linkifyUrls, onLinkClick, slugTone })}</div>
}

export function PlainText({ className, text, linkifyUrls = false, onLinkClick, slugTone }: PlainTextProps) {
  return <div className={className}>{linkifyUrls ? renderInlineText(text, true, 0, { linkifyUrls, onLinkClick, slugTone }) : text}</div>
}

// Shared "light markdown" preview renderer for truncated content cards
// (memory tool cards, Epic/Job/Design-Doc preview cards, etc). Unlike
// `Markdown`, it never produces block elements or literal line breaks: block
// markup (headings, list/blockquote markers, code fences, horizontal rules)
// is stripped and every non-blank line is joined into one flowing string, so
// a caller can safely bound the result with CSS `line-clamp-N` — wrapping is
// purely a function of container width, not literal newlines fighting the
// clamp. Headings render bold instead of as header elements. Light inline
// emphasis (bold/italic/inline code) still renders via the same inline
// tokenizer `Markdown` uses; math rendering is skipped.
export function renderLightMarkdown(text: string, options: { linkifySlugs?: boolean } = {}): ReactNode[] {
  const flattened = flattenLightMarkdown(text)
  return renderInline(flattened, { linkifySlugs: options.linkifySlugs, renderMath: false })
}

function flattenLightMarkdown(text: string): string {
  const lines = text.replace(/\r\n?/g, "\n").split("\n")
  const segments: string[] = []
  let inFence = false

  for (const line of lines) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence
      continue
    }

    if (inFence) {
      if (line.trim() !== "") segments.push(line.trim())
      continue
    }

    if (line.trim() === "") continue
    if (/^\s*(?:---+|\*\*\*+)\s*$/.test(line)) continue

    const heading = line.match(/^\s*#{1,6}\s+(.+)$/)
    if (heading) {
      segments.push(`**${heading[1].trim()}**`)
      continue
    }

    let content = line
    while (/^\s*>\s?/.test(content)) content = content.replace(/^\s*>\s?/, "")

    const list = content.match(/^\s*(?:[-*+]|\d+[.)])\s+(.+)$/)
    if (list) content = list[1]

    content = content.trim()
    if (content) segments.push(content)
  }

  return segments.join(" ")
}

function renderBlocks(text: string, options: RenderInlineOptions = {}): ReactNode[] {
  const lines = text.replace(/\r\n?/g, "\n").split("\n")
  const blocks: ReactNode[] = []
  let index = 0
  let key = 0

  while (index < lines.length) {
    const line = lines[index]
    if (line.trim() === "") {
      index += 1
      continue
    }

    const fence = line.match(/^\s*```([\w.-]+)?\s*$/)
    if (fence) {
      const code: string[] = []
      index += 1
      while (index < lines.length && !lines[index].match(/^\s*```\s*$/)) {
        code.push(lines[index])
        index += 1
      }
      if (index < lines.length) index += 1
      const lang = fence[1] ? detectFenceLanguage(fence[1]) : null
      blocks.push(
        <div className="overflow-x-auto" key={`block-${key++}`}>
          <CodeBlock code={code.join("\n")} lang={lang} />
        </div>
      )
      continue
    }

    if (/^\s*(?:---+|\*\*\*+)\s*$/.test(line)) {
      blocks.push(<hr key={`block-${key++}`} />)
      index += 1
      continue
    }

    const heading = line.match(/^(#{1,4})\s+(.+)$/)
    if (heading) {
      blocks.push(renderHeading(heading[1].length, heading[2], key++, options))
      index += 1
      continue
    }

    if (/^\s*>\s?/.test(line)) {
      const quoteLines: string[] = []
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s*>\s?/, ""))
        index += 1
      }
      blocks.push(<blockquote key={`block-${key++}`}>{renderBlocks(quoteLines.join("\n"), options)}</blockquote>)
      continue
    }

    if (isTableStart(lines, index)) {
      const { node, nextIndex } = renderTable(lines, index, key++, options)
      blocks.push(node)
      index = nextIndex
      continue
    }

    if (listMarker(line)) {
      const { node, nextIndex } = renderList(lines, index, key++, options)
      blocks.push(node)
      index = nextIndex
      continue
    }

    const paragraph: string[] = []
    while (index < lines.length && lines[index].trim() !== "" && !startsBlock(lines, index)) {
      paragraph.push(lines[index].trim())
      index += 1
    }
    blocks.push(<p key={`block-${key++}`}>{renderInline(paragraph.join(" "), options)}</p>)
  }

  return blocks
}

function safeMarkdownPreview(text: string) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n")
  let truncated = false
  const preview = lines.map((line) => {
    if (line.length <= MARKDOWN_SAFE_LINE_CHARS) return line

    truncated = true
    return line.slice(0, MARKDOWN_SAFE_LINE_CHARS)
  }).join("\n")

  return truncated ? `${preview}\n\n_One or more lines were truncated because they are too long to render safely._` : preview
}

function renderList(lines: string[], index: number, key: number, options: RenderInlineOptions = {}) {
  const firstMarker = listMarker(lines[index])
  if (!firstMarker) return { node: null, nextIndex: index }

  const items: ListItem[] = []
  const { indent, ordered } = firstMarker

  while (index < lines.length) {
    const marker = listMarker(lines[index])
    if (!marker || marker.indent !== indent || marker.ordered !== ordered) break

    const item: ListItem = { content: marker.content, nested: [], value: marker.value }
    index += 1

    while (index < lines.length) {
      if (lines[index].trim() === "") {
        if (nextNonBlankListMarker(lines, index + 1, indent)) {
          index += 1
          continue
        }
        break
      }

      const nextMarker = listMarker(lines[index])
      if (nextMarker) {
        if (nextMarker.indent > indent) {
          const nested = renderList(lines, index, key + items.length + item.nested.length + 1, options)
          if (nested.node) item.nested.push(nested.node)
          index = nested.nextIndex
          continue
        }
        break
      }

      if (lineIndent(lines[index]) > indent) {
        item.content = `${item.content} ${lines[index].trim()}`
        index += 1
        continue
      }

      break
    }

    items.push(item)
  }

  const node = ordered ? (
    <ol key={`block-${key}`} start={firstMarker.value}>
      {items.map((item, itemIndex) => (
        <li key={itemIndex} value={item.value}>
          {renderInline(item.content, options)}
          {item.nested}
        </li>
      ))}
    </ol>
  ) : (
    <ul key={`block-${key}`}>
      {items.map((item, itemIndex) => (
        <li key={itemIndex}>
          {renderInline(item.content, options)}
          {item.nested}
        </li>
      ))}
    </ul>
  )

  return { node, nextIndex: index }
}

function listMarker(line: string): ListMarker | null {
  const marker = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.+)$/)
  if (!marker) return null

  const ordered = /^\d/.test(marker[2])
  return {
    content: marker[3],
    indent: marker[1].replace(/\t/g, "    ").length,
    ordered,
    value: ordered ? Number.parseInt(marker[2], 10) : undefined
  }
}

function lineIndent(line: string) {
  return line.match(/^\s*/)?.[0].replace(/\t/g, "    ").length ?? 0
}

function nextNonBlankListMarker(lines: string[], index: number, parentIndent: number) {
  while (index < lines.length) {
    if (lines[index].trim() === "") {
      index += 1
      continue
    }

    const marker = listMarker(lines[index])
    return Boolean(marker && marker.indent >= parentIndent)
  }

  return false
}

function startsBlock(lines: string[], index: number) {
  const line = lines[index]
  return (
    /^\s*```/.test(line) ||
    /^(#{1,4})\s+/.test(line) ||
    /^\s*>\s?/.test(line) ||
    Boolean(listMarker(line)) ||
    /^\s*(?:---+|\*\*\*+)\s*$/.test(line) ||
    isTableStart(lines, index)
  )
}

function renderHeading(level: number, text: string, key: number, options: RenderInlineOptions = {}) {
  const children = renderInline(text, options)
  switch (level) {
    case 1:
      return <h1 key={`block-${key}`}>{children}</h1>
    case 2:
      return <h2 key={`block-${key}`}>{children}</h2>
    case 3:
      return <h3 key={`block-${key}`}>{children}</h3>
    default:
      return <h4 key={`block-${key}`}>{children}</h4>
  }
}

function isTableStart(lines: string[], index: number) {
  return index + 1 < lines.length && lines[index].includes("|") && /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(lines[index + 1])
}

function renderTable(lines: string[], index: number, key: number, options: RenderInlineOptions = {}) {
  const headers = splitTableRow(lines[index])
  index += 2
  const rows: string[][] = []

  while (index < lines.length && lines[index].includes("|") && lines[index].trim() !== "") {
    rows.push(splitTableRow(lines[index]))
    index += 1
  }
  const columnHints = tableColumnHints(headers, rows)
  const wide = tableNeedsHorizontalScroll(headers, rows)

  return {
    nextIndex: index,
    node: <MeasuredMarkdownTable columnHints={columnHints} fallbackWide={wide} headers={headers} key={`block-${key}`} measurementKey={tableMeasurementKey(headers, rows)} options={options} rows={rows} />
  }
}

function MeasuredMarkdownTable({ columnHints, fallbackWide, headers, measurementKey, options, rows }: { columnHints: TableColumnHint[]; fallbackWide: boolean; headers: string[]; measurementKey: string; options: RenderInlineOptions; rows: string[][] }) {
  const wrapperRef = useRef<HTMLDivElement | null>(null)
  const tableRef = useRef<HTMLTableElement | null>(null)
  const [layout, setLayout] = useState<TableColumnLayout | null>(null)
  const tableClassName = [
    "chat-prose-table",
    layout?.wide || (!layout && fallbackWide) ? "chat-prose-table--wide" : "chat-prose-table--balanced",
    layout ? "chat-prose-table--measured" : null
  ].filter(Boolean).join(" ")

  useLayoutEffect(() => {
    const wrapper = wrapperRef.current
    const table = tableRef.current
    if (!wrapper || !table) return

    const measure = () => {
      const available = wrapper.getBoundingClientRect().width || wrapper.clientWidth
      if (!available) return

      const nextLayout = allocateMarkdownTableColumns(measureMarkdownTableColumns(table, columnHints), available)
      setLayout((previous) => sameTableLayout(previous, nextLayout) ? previous : nextLayout)
    }

    measure()
    if (typeof ResizeObserver === "undefined") return

    const observer = new ResizeObserver(measure)
    observer.observe(wrapper)
    return () => observer.disconnect()
  }, [measurementKey])

  return (
    <div className="chat-prose-table-wrap" ref={wrapperRef}>
      <table className={tableClassName} ref={tableRef}>
        <colgroup>
          {columnHints.map((hint, cellIndex) => (
            <col
              key={cellIndex}
              className={`chat-prose-table__col chat-prose-table__col--${hint.kind}`}
              data-chat-table-column={hint.kind}
              style={{ "--chat-table-column-width": layout ? `${layout.widths[cellIndex]}px` : hint.width } as CSSProperties}
            />
          ))}
        </colgroup>
        <thead>
          <tr>
            {headers.map((header, cellIndex) => (
              <th key={cellIndex}>{renderInline(header, options)}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {headers.map((_header, cellIndex) => (
                <td key={cellIndex}>{renderInline(row[cellIndex] || "", options)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function tableMeasurementKey(headers: string[], rows: string[][]) {
  return [headers, ...rows].map((row) => row.join("\u001f")).join("\u001e")
}

function measureMarkdownTableColumns(table: HTMLTableElement, columnHints: TableColumnHint[]): TableColumnMeasurement[] {
  const measurements = columnHints.map((hint) => ({
    kind: hint.kind,
    min: MIN_COLUMN_WIDTHS[hint.kind],
    preferred: MIN_COLUMN_WIDTHS[hint.kind]
  }))
  const measurer = document.createElement("div")
  measurer.className = "chat-prose chat-prose-table-measurer"
  measurer.setAttribute("aria-hidden", "true")
  document.body.appendChild(measurer)

  try {
    for (const row of Array.from(table.rows)) {
      Array.from(row.cells).forEach((cell, columnIndex) => {
        const measurement = measurements[columnIndex]
        if (!measurement) return

        measurement.min = Math.max(measurement.min, measureTableCell(cell, measurer, "min-content"))
        measurement.preferred = Math.max(measurement.preferred, measureTableCell(cell, measurer, "max-content"))
      })
    }
  } finally {
    measurer.remove()
  }

  return measurements.map((measurement) => ({
    ...measurement,
    preferred: Math.max(measurement.preferred, measurement.min)
  }))
}

function measureTableCell(cell: HTMLTableCellElement, measurer: HTMLElement, width: "min-content" | "max-content") {
  const clone = cell.cloneNode(true) as HTMLTableCellElement
  clone.style.width = width
  clone.style.minWidth = "0"
  clone.style.maxWidth = "none"
  clone.style.whiteSpace = "normal"

  const table = document.createElement("table")
  table.className = "chat-prose-table"
  table.style.width = width
  table.style.maxWidth = "none"
  const row = document.createElement("tr")
  row.appendChild(clone)
  table.appendChild(row)
  measurer.appendChild(table)
  const measured = clone.getBoundingClientRect().width || clone.scrollWidth
  table.remove()
  return Math.ceil(measured)
}

export function allocateMarkdownTableColumns(columns: TableColumnMeasurement[], availableWidth: number): TableColumnLayout {
  if (columns.length === 0) return { wide: false, widths: [] }

  const minWidths = columns.map((column) => Math.max(MIN_COLUMN_WIDTHS[column.kind], Math.ceil(column.min)))
  const preferredWidths = columns.map((column, index) => Math.max(minWidths[index], Math.ceil(column.preferred)))
  const minTotal = sum(minWidths)

  if (minTotal > availableWidth) return { wide: true, widths: minWidths }

  const preferredTotal = sum(preferredWidths)
  if (preferredTotal >= availableWidth) return { wide: false, widths: distributeByNeed(minWidths, preferredWidths, availableWidth - minTotal) }

  return { wide: false, widths: distributeByWeight(preferredWidths, columns, availableWidth - preferredTotal) }
}

function distributeByNeed(minWidths: number[], preferredWidths: number[], extra: number) {
  const widths = [...minWidths]
  let remaining = extra
  let candidates = preferredWidths.map((preferred, index) => ({ index, need: preferred - minWidths[index] })).filter((candidate) => candidate.need > 0)

  while (remaining > 0.01 && candidates.length > 0) {
    const totalNeed = sum(candidates.map((candidate) => candidate.need))
    const nextCandidates = []

    for (const candidate of candidates) {
      const addition = Math.min(candidate.need, remaining * (candidate.need / totalNeed))
      widths[candidate.index] += addition
      const need = candidate.need - addition
      if (need > 0.01) nextCandidates.push({ index: candidate.index, need })
    }

    const used = sum(widths) - sum(minWidths)
    remaining = extra - used
    if (nextCandidates.length === candidates.length && remaining < 0.5) break
    candidates = nextCandidates
  }

  return roundedWidths(widths, sum(minWidths) + extra)
}

function distributeByWeight(widths: number[], columns: TableColumnMeasurement[], extra: number) {
  const totalWeight = columns.reduce((sum, column) => sum + tableColumnWeight(column.kind), 0)
  return roundedWidths(widths.map((width, index) => width + extra * (tableColumnWeight(columns[index].kind) / totalWeight)), sum(widths) + extra)
}

function roundedWidths(widths: number[], targetTotal: number) {
  const rounded = widths.map((width) => Math.max(1, Math.round(width)))
  const delta = Math.round(targetTotal) - sum(rounded)
  if (rounded.length > 0 && delta !== 0) rounded[rounded.length - 1] += delta
  return rounded
}

function sameTableLayout(previous: TableColumnLayout | null, next: TableColumnLayout) {
  return Boolean(previous && previous.wide === next.wide && previous.widths.length === next.widths.length && previous.widths.every((width, index) => width === next.widths[index]))
}

function sum(values: number[]) {
  return values.reduce((total, value) => total + value, 0)
}

function splitTableRow(line: string) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim())
}

function tableColumnHints(headers: string[], rows: string[][]): TableColumnHint[] {
  const kinds = headers.map((header, columnIndex) =>
    tableColumnKind(
      header,
      rows.map((row) => row[columnIndex] || "")
    )
  )
  const totalWeight = kinds.reduce((sum, kind) => sum + tableColumnWeight(kind), 0)

  return kinds.map((kind) => ({
    kind,
    width: `${Math.round((tableColumnWeight(kind) / totalWeight) * 1000) / 10}%`
  }))
}

function tableColumnKind(header: string, cells: string[]): TableColumnKind {
  const values = [header, ...cells].map(normalizeTableCell)
  const longest = Math.max(...values.map((value) => value.length), 0)
  const proseValues = values.filter((value) => /\s/.test(value) && value.length > 18).length

  if (values.every(compactTableValue) && longest <= 16) return "compact"
  if (proseValues > 0 || longest > 36) return "prose"
  return "label"
}

function tableColumnWeight(kind: TableColumnKind) {
  return TABLE_COLUMN_WEIGHTS[kind]
}

function compactTableValue(value: string) {
  if (value === "") return true
  if (/^(?:#|no\.?|num(?:ber)?|id|ids|count|qty|status)$/i.test(value)) return true
  return /^[A-Z]{1,4}-?\d{1,6}$/.test(value) || /^[\d.,%:/-]+$/.test(value)
}

function normalizeTableCell(value: string) {
  return value
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]\n]+)\]\([^)]+\)/g, "$1")
    .replace(/[*_~]/g, "")
    .trim()
}

function tableNeedsHorizontalScroll(headers: string[], rows: string[][]) {
  if (headers.length >= WIDE_TABLE_COLUMN_COUNT) return true

  return [headers, ...rows].some((row) => row.some((cell) => hasUnbreakableTableToken(cell)))
}

function hasUnbreakableTableToken(value: string) {
  return /https?:\/\/\S{24,}/i.test(value) || /`[^\s`]{24,}`/.test(value) || /[^\s`|]{32,}/.test(value)
}

function renderInline(text: string, options: RenderInlineOptions = {}): InlineToken[] {
  const shouldLinkifySlugs = options.linkifySlugs !== false
  const tokens: InlineToken[] = []
  let cursor = 0
  let key = 0

  while (cursor < text.length) {
    const match = nextInlineToken(text, cursor, options)
    if (!match) break

    if (match.index > cursor) tokens.push(renderInlineText(text.slice(cursor, match.index), shouldLinkifySlugs, key++, options))
    tokens.push(renderInlineToken(match.token, key++, options))
    cursor = match.index + match.token.length
  }

  if (cursor < text.length) tokens.push(renderInlineText(text.slice(cursor), shouldLinkifySlugs, key++, options))
  return tokens
}

function nextInlineToken(text: string, cursor: number, options: RenderInlineOptions): InlineMatch | null {
  INLINE_MARKDOWN_PATTERN.lastIndex = cursor
  const markdownMatch = INLINE_MARKDOWN_PATTERN.exec(text)
  const markdown = markdownMatch ? { index: markdownMatch.index, token: markdownMatch[0] } : null
  const math = options.renderMath === false ? null : findInlineMath(text, cursor)

  if (!markdown) return math
  if (!math) return markdown
  return markdown.index <= math.index ? markdown : math
}

function findInlineMath(text: string, cursor: number): InlineMatch | null {
  for (let index = cursor; index < text.length; index += 1) {
    if (text[index] === "$" && !escapedAt(text, index)) {
      const match = findDollarMath(text, index)
      if (match) return match
      continue
    }

    if (text[index] === "\\" && text[index + 1] === "(" && !escapedAt(text, index)) {
      const match = findParenthesizedMath(text, index)
      if (match) return match
    }
  }

  return null
}

function findDollarMath(text: string, start: number): InlineMatch | null {
  if (!text[start + 1] || /\s|\$/.test(text[start + 1])) return null

  for (let end = start + 1; end < text.length; end += 1) {
    if (text[end] === "\n") return null
    if (text[end] !== "$" || escapedAt(text, end)) continue

    const expression = text.slice(start + 1, end)
    if (validInlineMathExpression(expression)) return { index: start, token: text.slice(start, end + 1) }
    return null
  }

  return null
}

function findParenthesizedMath(text: string, start: number): InlineMatch | null {
  if (!text[start + 2] || /\s/.test(text[start + 2])) return null

  for (let end = start + 2; end < text.length - 1; end += 1) {
    if (text[end] === "\n") return null
    if (text[end] !== "\\" || text[end + 1] !== ")" || escapedAt(text, end)) continue

    const expression = text.slice(start + 2, end)
    if (validInlineMathExpression(expression)) return { index: start, token: text.slice(start, end + 2) }
    return null
  }

  return null
}

function escapedAt(text: string, index: number) {
  let slashes = 0
  for (let cursor = index - 1; cursor >= 0 && text[cursor] === "\\"; cursor -= 1) {
    slashes += 1
  }

  return slashes % 2 === 1
}

function decodeHtmlEntities(text: string): string {
  return text.replace(/&(amp|lt|gt|quot|apos|nbsp|#x[0-9a-fA-F]+|#\d+);/g, (_match, entity) => {
    if (entity.startsWith("#x")) return String.fromCharCode(parseInt(entity.slice(2), 16))
    if (entity.startsWith("#")) return String.fromCharCode(Number(entity.slice(1)))
    const map: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " }
    return map[entity] ?? _match
  })
}

function renderInlineText(text: string, shouldLinkifySlugs: boolean, key: number, options: RenderInlineOptions = {}): InlineToken {
  const decoded = decodeHtmlEntities(text)
  if (options.linkifyUrls) return linkifyPlainUrls(decoded, shouldLinkifySlugs, key, options)
  if (shouldLinkifySlugs && containsSlug(decoded)) {
    return <Fragment key={key}>{linkifySlugs(decoded, { tone: options.slugTone })}</Fragment>
  }
  return decoded
}

function linkifyPlainUrls(text: string, shouldLinkifySlugs: boolean, key: number, options: RenderInlineOptions): InlineToken {
  const nodes: InlineToken[] = []
  let cursor = 0
  let partKey = 0

  for (const match of text.matchAll(PLAIN_URL_PATTERN)) {
    const rawUrl = match[0]
    const start = match.index ?? 0
    const url = plainUrlFromMatch(rawUrl)
    if (!url) continue

    if (start > cursor) nodes.push(renderNonUrlText(text.slice(cursor, start), shouldLinkifySlugs, `text-${partKey++}`, options))
    nodes.push(renderPlainUrlLink(url.href, `url-${partKey++}`, options))
    if (url.trailing) nodes.push(renderNonUrlText(url.trailing, shouldLinkifySlugs, `text-${partKey++}`, options))
    cursor = start + rawUrl.length
  }

  if (cursor < text.length) nodes.push(renderNonUrlText(text.slice(cursor), shouldLinkifySlugs, `text-${partKey++}`, options))
  if (nodes.length === 0) return shouldLinkifySlugs && containsSlug(text) ? <Fragment key={key}>{linkifySlugs(text, { tone: options.slugTone })}</Fragment> : text
  return <Fragment key={key}>{nodes}</Fragment>
}

function renderNonUrlText(text: string, shouldLinkifySlugs: boolean, key: string, options: RenderInlineOptions) {
  if (shouldLinkifySlugs && containsSlug(text)) return <Fragment key={key}>{linkifySlugs(text, { tone: options.slugTone })}</Fragment>
  return <Fragment key={key}>{text}</Fragment>
}

function renderPlainUrlLink(href: string, key: string, options: RenderInlineOptions) {
  return (
    <a href={href} key={key} onClick={options.onLinkClick ? (event) => options.onLinkClick?.(href, event) : undefined} rel="noreferrer" target="_blank">
      {href}
    </a>
  )
}

function plainUrlFromMatch(rawUrl: string) {
  const trailing = rawUrl.match(/[),.!?;:]+$/)?.[0] ?? ""
  const href = trailing ? rawUrl.slice(0, -trailing.length) : rawUrl
  if (!safeHref(href) || !externalHref(href)) return null

  return { href, trailing }
}

function renderInlineToken(token: string, key: number, options: RenderInlineOptions): ReactNode {
  if (token.startsWith("`")) {
    return <code key={key}>{renderInlineText(token.slice(1, -1), options.linkifySlugs !== false, 0)}</code>
  }
  if ((token.startsWith("$") || token.startsWith("\\(")) && options.renderMath !== false) {
    return renderInlineMath(token, key)
  }
  if (token.startsWith("**")) {
    return <strong key={key}>{renderInline(token.slice(2, -2), options)}</strong>
  }
  if (token.startsWith("~~")) {
    return <del key={key}>{renderInline(token.slice(2, -2), options)}</del>
  }
  if (token.startsWith("*")) {
    return <em key={key}>{renderInline(token.slice(1, -1), options)}</em>
  }

  const link = token.match(/^\[([^\]]+)\]\(([^) \n]+)(?:\s+"[^"\n]+")?\)$/)
  if (link) {
    const href = safeHref(link[2])
    if (href) {
      return (
        <a href={href} key={key} onClick={options.onLinkClick ? (event) => options.onLinkClick?.(href, event) : undefined} rel="noreferrer" target={externalHref(href) ? "_blank" : undefined}>
          {renderInline(link[1], { ...options, linkifySlugs: false, linkifyUrls: false, renderMath: false })}
        </a>
      )
    }
  }

  return token
}

function renderInlineMath(token: string, key: number) {
  const expression = token.startsWith("$") ? token.slice(1, -1) : token.slice(2, -2)
  if (!validInlineMathExpression(expression)) return token

  const html = katex.renderToString(expression, {
    displayMode: false,
    output: "htmlAndMathml",
    strict: false,
    throwOnError: false,
    trust: false
  })

  return <span className="syrus-inline-math" dangerouslySetInnerHTML={{ __html: html }} key={key} />
}

function validInlineMathExpression(expression: string) {
  if (expression.trim() !== expression || expression.length === 0) return false
  if (/^\d/.test(expression)) return /[\\^_{}=<>+\-*/]/.test(expression) || /^\d+(?:[A-Za-z]|\\)/.test(expression)

  return /[A-Za-z\\^_{}=<>+\-*/]/.test(expression)
}

function safeHref(href: string) {
  if (href.startsWith("/") || href.startsWith("#")) return href

  try {
    const url = new URL(href, window.location.origin)
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? href : null
  } catch (_error) {
    return null
  }
}

function externalHref(href: string) {
  return href.startsWith("http://") || href.startsWith("https://") || href.startsWith("mailto:")
}
