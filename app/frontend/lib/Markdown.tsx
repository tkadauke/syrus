import { Fragment, type ReactNode } from "react"
import { containsSlug, linkifySlugs } from "./linkifySlugs"

type InlineToken = string | ReactNode
type RenderInlineOptions = { linkifySlugs?: boolean }

export function Markdown({ className, text }: { className?: string; text: string }) {
  return <div className={className}>{renderBlocks(text)}</div>
}

export function PlainText({ className, text }: { className?: string; text: string }) {
  return <div className={className}>{text}</div>
}

function renderBlocks(text: string): ReactNode[] {
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
        <pre key={`block-${key++}`}>
          <code>{code.join("\n")}</code>
        </pre>
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
      blocks.push(renderHeading(heading[1].length, heading[2], key++))
      index += 1
      continue
    }

    if (/^\s*>\s?/.test(line)) {
      const quoteLines: string[] = []
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s*>\s?/, ""))
        index += 1
      }
      blocks.push(<blockquote key={`block-${key++}`}>{renderBlocks(quoteLines.join("\n"))}</blockquote>)
      continue
    }

    if (isTableStart(lines, index)) {
      const { node, nextIndex } = renderTable(lines, index, key++)
      blocks.push(node)
      index = nextIndex
      continue
    }

    if (/^\s*[-*+]\s+/.test(line)) {
      const { items, nextIndex } = collectListItems(lines, index, /^\s*[-*+]\s+/, /^\s*[-*+]\s+/)
      index = nextIndex
      blocks.push(
        <ul key={`block-${key++}`}>
          {items.map((item, itemIndex) => <li key={itemIndex}>{renderInline(item)}</li>)}
        </ul>
      )
      continue
    }

    if (/^\s*\d+[.)]\s+/.test(line)) {
      const { items, nextIndex } = collectListItems(lines, index, /^\s*\d+[.)]\s+/, /^\s*\d+[.)]\s+/)
      index = nextIndex
      blocks.push(
        <ol key={`block-${key++}`}>
          {items.map((item, itemIndex) => <li key={itemIndex}>{renderInline(item)}</li>)}
        </ol>
      )
      continue
    }

    const paragraph: string[] = []
    while (index < lines.length && lines[index].trim() !== "" && !startsBlock(lines, index)) {
      paragraph.push(lines[index].trim())
      index += 1
    }
    blocks.push(<p key={`block-${key++}`}>{renderInline(paragraph.join(" "))}</p>)
  }

  return blocks
}

function collectListItems(lines: string[], index: number, markerPattern: RegExp, markerReplacement: RegExp) {
  const items: string[] = []

  while (index < lines.length) {
    const line = lines[index]
    if (markerPattern.test(line)) {
      items.push(line.replace(markerReplacement, ""))
      index += 1
      continue
    }

    if (line.trim() === "" && nextNonBlankLineMatches(lines, index + 1, markerPattern)) {
      index += 1
      continue
    }

    break
  }

  return { items, nextIndex: index }
}

function nextNonBlankLineMatches(lines: string[], index: number, pattern: RegExp) {
  while (index < lines.length && lines[index].trim() === "") index += 1
  return index < lines.length && pattern.test(lines[index])
}

function startsBlock(lines: string[], index: number) {
  const line = lines[index]
  return (
    /^\s*```/.test(line) ||
    /^(#{1,4})\s+/.test(line) ||
    /^\s*>\s?/.test(line) ||
    /^\s*[-*+]\s+/.test(line) ||
    /^\s*\d+[.)]\s+/.test(line) ||
    /^\s*(?:---+|\*\*\*+)\s*$/.test(line) ||
    isTableStart(lines, index)
  )
}

function renderHeading(level: number, text: string, key: number) {
  const children = renderInline(text)
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

function renderTable(lines: string[], index: number, key: number) {
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
      <table key={`block-${key}`}>
        <thead>
          <tr>{headers.map((header, cellIndex) => <th key={cellIndex}>{renderInline(header)}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {headers.map((_header, cellIndex) => <td key={cellIndex}>{renderInline(row[cellIndex] || "")}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
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

function renderInlineText(text: string, shouldLinkifySlugs: boolean, key: number): InlineToken {
  if (shouldLinkifySlugs && containsSlug(text)) {
    return <Fragment key={key}>{linkifySlugs(text)}</Fragment>
  }
  return text
}

function renderInlineToken(token: string, key: number, options: RenderInlineOptions): ReactNode {
  if (token.startsWith("`")) {
    return <code key={key}>{token.slice(1, -1)}</code>
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
        <a href={href} key={key} rel="noreferrer" target={externalHref(href) ? "_blank" : undefined}>
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
