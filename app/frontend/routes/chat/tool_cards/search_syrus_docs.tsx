import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, numberValue, Row, SectionLabel } from "../toolCardUi"

const SNIPPET_CHARS = 360

type SyrusDocsResult = {
  key: string
  rank: number
  title: string
  heading: string | null
  path: string | null
  source: string | null
  reference: string | null
  snippet: string | null
}

type SyrusDocsCard =
  | { kind: "results"; query: string; count: number; results: SyrusDocsResult[]; message: string | null }
  | { kind: "error"; query: string | null; message: string }
  | { kind: "malformed"; query: string | null }

function compactText(value: string | null, maxChars: number) {
  if (!value) return null
  const normalized = value.replace(/\s+/g, " ").trim()
  return normalized.length > maxChars ? `${normalized.slice(0, maxChars - 3)}...` : normalized
}

function parseResult(value: unknown, index: number): SyrusDocsResult | null {
  if (!isPlainObject(value)) return null

  const title = displayValue(value.title)
  if (!title) return null

  const rank = numberValue(value.rank) ?? index + 1
  return {
    key: `${displayValue(value.path) ?? title}-${displayValue(value.heading) ?? rank}`,
    rank,
    title,
    heading: displayValue(value.heading),
    path: displayValue(value.path),
    source: displayValue(value.source),
    reference: displayValue(value.reference),
    snippet: compactText(displayValue(value.snippet) ?? displayValue(value.text), SNIPPET_CHARS)
  }
}

function parseCard(context: ToolCardContext): SyrusDocsCard {
  const queryFromInput = displayValue(context.input?.query)
  if (context.resultError) {
    return {
      kind: "error",
      query: queryFromInput,
      message: displayValue(context.resultBody) ?? "Syrus Docs search failed."
    }
  }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.results)) return { kind: "malformed", query: queryFromInput }

  const results = parsed.results.flatMap((result, index) => {
    const row = parseResult(result, index)
    return row ? [row] : []
  })
  const count = numberValue(parsed.count) ?? results.length
  return {
    kind: "results",
    query: displayValue(parsed.query) ?? queryFromInput ?? "",
    count,
    results,
    message: displayValue(parsed.message)
  }
}

function pluralHits(count: number) {
  return `${count} hit${count === 1 ? "" : "s"}`
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (card.kind === "error") return card.query ? `"${card.query}" failed` : "Syrus Docs search failed"
  if (card.kind === "malformed") return card.query ? `"${card.query}" returned an unexpected response` : "Syrus Docs search returned an unexpected response"

  const query = card.query || "Syrus Docs"
  return `"${query}" - ${pluralHits(card.count)}`
}

function ResultReference({ result }: { result: SyrusDocsResult }) {
  const sourceLabel = result.source ? result.source.replace(/^plugin:/, "plugin: ") : null

  return (
    <div className="flex min-w-0 flex-wrap gap-1">
      {result.path ? <Badge>{result.path}</Badge> : null}
      {sourceLabel ? <Badge>{sourceLabel}</Badge> : null}
      {result.reference && result.reference !== result.path ? <Badge>{result.reference}</Badge> : null}
    </div>
  )
}

function ResultList({ results }: { results: SyrusDocsResult[] }) {
  return (
    <ol className="space-y-2">
      {results.map((result) => (
        <li className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950" key={result.key}>
          <div className="flex min-w-0 items-baseline gap-2">
            <span className="shrink-0 font-mono text-2xs text-gray-500 dark:text-gray-400">#{result.rank}</span>
            <div className="min-w-0 flex-1">
              <div className="truncate font-medium text-gray-900 dark:text-gray-100" title={[result.title, result.heading].filter(Boolean).join(" > ")}>
                {result.title}
                {result.heading && result.heading !== result.title ? ` > ${result.heading}` : ""}
              </div>
            </div>
          </div>
          <ResultReference result={result} />
          {result.snippet ? <p className="mt-1 whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{result.snippet}</p> : null}
        </li>
      ))}
    </ol>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)

  if (card.kind === "error") {
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          {card.message}
        </div>
        {card.query ? <Row label="Query" value={card.query} /> : null}
      </CardShell>
    )
  }

  if (card.kind === "malformed") {
    return (
      <CardShell>
        {card.query ? <Row label="Query" value={card.query} /> : null}
        <EmptyState>Unexpected Syrus Docs search response.</EmptyState>
      </CardShell>
    )
  }

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Query" value={card.query || "(blank)"} />
        <Row label="Hits" value={String(card.count)} />
      </dl>
      {card.results.length === 0 ? (
        <EmptyState>{card.message || "No matching documentation found."}</EmptyState>
      ) : (
        <div className="space-y-1">
          <SectionLabel>Ranked results</SectionLabel>
          <ResultList results={card.results} />
        </div>
      )}
    </CardShell>
  )
}

const searchSyrusDocsToolCard: ToolCardRenderer = {
  toolName: "search_syrus_docs",
  collapsedSummary,
  renderExpanded
}

export default searchSyrusDocsToolCard
