import { Fragment, type MouseEvent, type ReactNode } from "react"
import { containsSlug, linkifySlugs } from "./linkifySlugs"

type InlineToken = string | ReactNode
export type MarkdownLinkHandler = (href: string, event: MouseEvent<HTMLAnchorElement>) => void
type RenderInlineOptions = { linkifySlugs?: boolean; onLinkClick?: MarkdownLinkHandler }
type ListMarker = { indent: number; ordered: boolean; value?: number; content: string }
type ListItem = { content: string; nested: ReactNode[]; value?: number }
type MarkdownProps = { className?: string; text: string; onLinkClick?: MarkdownLinkHandler }

export function Markdown({ className, text, onLinkClick }: MarkdownProps) {
  return <div className={["chat-prose", className].filter(Boolean).join(" ")}>{renderBlocks(text, { onLinkClick })}</div>
}

export function PlainText({ className, text }: { className?: string; text: string }) {
  return <div className={className}>{text}</div>
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
      blocks.push(
        <div key={`block-${key++}`} className="overflow-x-auto">
          <pre>
            <code>{code.join("\n")}</code>
          </pre>
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

  return {
    nextIndex: index,
    node: (
      <div key={`block-${key}`} className="overflow-x-auto"><table>
        <thead>
          <tr>{headers.map((header, cellIndex) => <th key={cellIndex}>{renderInline(header, options)}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {headers.map((_header, cellIndex) => <td key={cellIndex}>{renderInline(row[cellIndex] || "", options)}</td>)}
            </tr>
          ))}
        </tbody>
      </table></div>
    )
  }
}

function splitTableRow(line: string) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((cell) => cell.trim())
}

function renderInline(text: string, options: RenderInlineOptions = {}): InlineToken[] {
  const shouldLinkifySlugs = options.linkifySlugs !== false
  const tokens: InlineToken[] = []
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*\n]+\*|\[[^\]\n]+\]\([^) \n]+(?:\s+"[^"\n]+")?\))/g
  let cursor = 0
  let key = 0
  let match: RegExpExecArray | null

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > cursor) tokens.push(renderInlineText(text.slice(cursor, match.index), shouldLinkifySlugs, key++))
    tokens.push(renderInlineToken(match[0], key++, options))
    cursor = match.index + match[0].length
  }

  if (cursor < text.length) tokens.push(renderInlineText(text.slice(cursor), shouldLinkifySlugs, key++))
  return tokens
}

function decodeHtmlEntities(text: string): string {
  return text.replace(/&(amp|lt|gt|quot|apos|nbsp|#x[0-9a-fA-F]+|#\d+);/g, (_match, entity) => {
    if (entity.startsWith("#x")) return String.fromCharCode(parseInt(entity.slice(2), 16))
    if (entity.startsWith("#")) return String.fromCharCode(Number(entity.slice(1)))
    const map: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " }
    return map[entity] ?? _match
  })
}

function renderInlineText(text: string, shouldLinkifySlugs: boolean, key: number): InlineToken {
  const decoded = decodeHtmlEntities(text)
  if (shouldLinkifySlugs && containsSlug(decoded)) {
    return <Fragment key={key}>{linkifySlugs(decoded)}</Fragment>
  }
  return decoded
}

function renderInlineToken(token: string, key: number, options: RenderInlineOptions): ReactNode {
  if (token.startsWith("`")) {
    return <code key={key}>{renderInlineText(token.slice(1, -1), options.linkifySlugs !== false, 0)}</code>
  }
  if (token.startsWith("**")) {
    return <strong key={key}>{renderInline(token.slice(2, -2), options)}</strong>
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
          {renderInline(link[1], { ...options, linkifySlugs: false })}
        </a>
      )
    }
  }

  return token
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
