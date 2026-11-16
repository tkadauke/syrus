import { Fragment, useEffect, useState, type ReactNode } from "react"
import type { ThemedToken } from "@shikijs/core"
import { tokenizeLines, type HighlighterLanguageId } from "../lib/highlighter"

// Tokenizes the full `code` string against Shiki's css-variables theme
// (see lib/highlighter.ts) and returns one token array per line. Returns
// null while a language is loading (or when there is no language to
// highlight with) so callers can fall back to plain text for that render.
export function useHighlightedLines(code: string, lang: HighlighterLanguageId | null): ThemedToken[][] | null {
  const [lines, setLines] = useState<ThemedToken[][] | null>(null)

  useEffect(() => {
    setLines(null)
    if (!lang) return

    let cancelled = false
    tokenizeLines(code, lang).then((result) => {
      if (!cancelled) setLines(result)
    }).catch((error: unknown) => {
      // A blocked/failed highlighter load must not surface as an
      // unhandled promise rejection -- `lines` stays null, so the block
      // just keeps rendering its plain-text fallback.
      if (cancelled) return
      console.warn("Code highlighting failed; falling back to plain text.", error)
    })

    return () => {
      cancelled = true
    }
  }, [code, lang])

  return lines
}

// Renders one tokenized line as colored spans, or `fallback` (the plain
// line text) when tokens for this line aren't available yet.
export function renderCodeLine(tokens: ThemedToken[] | undefined, fallback: string): ReactNode {
  if (!tokens) return fallback

  return tokens.map((token, index) => <span key={index} style={{ color: token.color }}>{token.content}</span>)
}

// Shared `<pre><code>` code block, built on the Shiki core highlighter.
// Renders plain text immediately and swaps in highlighted spans once
// tokenization resolves; `lang={null}` (unrecognized/unsupported
// language) renders plain text permanently.
export function CodeBlock({
  code,
  lang,
  className,
  highlightTerms
}: {
  code: string
  lang: HighlighterLanguageId | null
  className?: string
  highlightTerms?: string[]
}) {
  const lines = useHighlightedLines(code, lang)
  const codeLines = code.split("\n")

  return (
    <pre className={className}>
      <code>
        {codeLines.map((line, index) => (
          <Fragment key={index}>
            {renderCodeLineWithHighlights(lines?.[index], line, highlightTerms)}
            {index < codeLines.length - 1 ? "\n" : null}
          </Fragment>
        ))}
      </code>
    </pre>
  )
}

type HighlightRange = { start: number; end: number }

function renderCodeLineWithHighlights(tokens: ThemedToken[] | undefined, line: string, highlightTerms?: string[]) {
  const ranges = highlightRanges(line, highlightTerms)
  if (ranges.length === 0) return renderCodeLine(tokens, line)
  if (!tokens) return renderHighlightedCodeText(line, ranges, "plain")

  let offset = 0
  return tokens.map((token, tokenIndex) => {
    const tokenStart = offset
    const tokenEnd = tokenStart + token.content.length
    offset = tokenEnd
    const tokenRanges = ranges
      .filter((range) => range.start < tokenEnd && range.end > tokenStart)
      .map((range) => ({ start: Math.max(0, range.start - tokenStart), end: Math.min(token.content.length, range.end - tokenStart) }))

    return (
      <span key={tokenIndex} style={{ color: token.color }}>
        {renderHighlightedCodeText(token.content, tokenRanges, `token-${tokenIndex}`)}
      </span>
    )
  })
}

function highlightRanges(text: string, terms?: string[]): HighlightRange[] {
  const normalized = terms?.map((term) => term.trim()).filter(Boolean) ?? []
  if (normalized.length === 0) return []

  const pattern = new RegExp(normalized.map(escapeRegExp).join("|"), "gi")
  return Array.from(text.matchAll(pattern), (match) => ({ start: match.index, end: match.index + match[0].length }))
}

function renderHighlightedCodeText(text: string, ranges: HighlightRange[], keyPrefix: string) {
  const parts: ReactNode[] = []
  let cursor = 0
  ranges.forEach((range, index) => {
    if (range.start > cursor) parts.push(<Fragment key={`${keyPrefix}-text-${index}`}>{text.slice(cursor, range.start)}</Fragment>)
    parts.push(
      <mark className="rounded-sm bg-warning/20 px-0.5 text-inherit" data-search-highlight key={`${keyPrefix}-match-${index}`}>
        {text.slice(range.start, range.end)}
      </mark>
    )
    cursor = range.end
  })
  if (cursor < text.length) parts.push(<Fragment key={`${keyPrefix}-tail`}>{text.slice(cursor)}</Fragment>)
  return parts
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}
