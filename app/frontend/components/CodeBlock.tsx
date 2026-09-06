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
export function CodeBlock({ code, lang, className }: { code: string; lang: HighlighterLanguageId | null; className?: string }) {
  const lines = useHighlightedLines(code, lang)
  const codeLines = code.split("\n")

  return (
    <pre className={className}>
      <code>
        {codeLines.map((line, index) => (
          <Fragment key={index}>
            {renderCodeLine(lines?.[index], line)}
            {index < codeLines.length - 1 ? "\n" : null}
          </Fragment>
        ))}
      </code>
    </pre>
  )
}
