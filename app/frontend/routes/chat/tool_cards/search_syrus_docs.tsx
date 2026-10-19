import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, FilterableList, displayValue, EmptyState, numberValue, Row, SectionLabel } from "../toolCardUi"

const SNIPPET_CHARS = 360
const GITHUB_REPOSITORY_URL = "https://github.com/tkadauke/syrus"

type SyrusDocsResult = {
  key: string
  rank: number
  title: string
  heading: string | null
  path: string | null
  source: string | null
  reference: string | null
  text: string | null
  score: number | null
}

type SyrusDocsCard =
  | { kind: "pending"; query: string | null; limit: number | null }
  | { kind: "results"; query: string; limit: number | null; count: number; results: SyrusDocsResult[]; message: string | null }
  | { kind: "error"; query: string | null; limit: number | null; message: string }
  | { kind: "malformed"; query: string | null; limit: number | null }

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
    text: displayValue(value.text) ?? displayValue(value.snippet),
    score: numberValue(value.score)
  }
}

function parseCard(context: ToolCardContext): SyrusDocsCard {
  const queryFromInput = displayValue(context.input?.query)
  const limit = numberValue(context.input?.limit)
  if (!context.resultError && context.parsedResult == null && !context.resultBody.trim()) return { kind: "pending", query: queryFromInput, limit }
  if (context.resultError) {
    return {
      kind: "error",
      query: queryFromInput,
      limit,
      message: displayValue(context.resultBody) ?? "Syrus Docs search failed."
    }
  }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.results)) return { kind: "malformed", query: queryFromInput, limit }

  const results = parsed.results.flatMap((result, index) => {
    const row = parseResult(result, index)
    return row ? [row] : []
  })
  const count = numberValue(parsed.count) ?? results.length
  return {
    kind: "results",
    query: displayValue(parsed.query) ?? queryFromInput ?? "",
    limit,
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
  if (card.kind === "pending") return card.query ? `Searching Syrus Docs for "${card.query}"` : "Searching Syrus Docs"
  if (card.kind === "error") return card.query ? `"${card.query}" failed` : "Syrus Docs search failed"
  if (card.kind === "malformed") return card.query ? `"${card.query}" returned an unexpected response` : "Syrus Docs search returned an unexpected response"

  const query = card.query || "Syrus Docs"
  return `"${query}" - ${pluralHits(card.count)}`
}

function githubDocUrl(path: string, heading?: string | null) {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/")
  const anchor = heading
    ? `#${heading
        .toLowerCase()
        .trim()
        .replace(/[^\p{L}\p{N}\s-]/gu, "")
        .replace(/\s+/g, "-")}`
    : ""
  return `${GITHUB_REPOSITORY_URL}/blob/main/${encodedPath}${anchor}`
}

function DocLink({ path, heading, children }: { path: string; heading?: string | null; children: string }) {
  return (
    <a
      className="min-w-0 break-all font-mono text-brand hover:underline dark:text-brand-emphasis"
      href={githubDocUrl(path, heading)}
      rel="noreferrer"
      target="_blank"
    >
      {children}
    </a>
  )
}

function ResultReference({ result }: { result: SyrusDocsResult }) {
  const sourceLabel = result.source ? result.source.replace(/^plugin:/, "plugin: ") : null

  return (
    <div className="flex min-w-0 flex-wrap gap-1">
      {result.path ? <DocLink path={result.path}>{result.path}</DocLink> : null}
      {sourceLabel ? <Badge>{sourceLabel}</Badge> : null}
      {result.reference && result.reference !== result.path && result.path ? (
        <DocLink heading={result.heading} path={result.path}>
          {result.reference}
        </DocLink>
      ) : null}
      {result.score != null ? <Badge>score {result.score}</Badge> : null}
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
          <div className="mt-1 min-w-0 max-w-full overflow-hidden">
            <MarkdownPreview
              emptyState="No snippet text was returned."
              linkifySlugs
              linkifyUrls
              maxChars={SNIPPET_CHARS}
              modalLabel={`Full documentation snippet for ${result.title}`}
              text={result.text ?? ""}
              title={result.heading ?? result.title}
            />
          </div>
        </li>
      ))}
    </ol>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)

  if (card.kind === "pending") {
    return (
      <CardShell>
        {card.query ? <Row label="Query" value={card.query} /> : null}
        {card.limit != null ? <Row label="Limit" value={String(card.limit)} /> : null}
        <EmptyState>Searching Syrus Docs…</EmptyState>
      </CardShell>
    )
  }

  if (card.kind === "error") {
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          {card.message}
        </div>
        {card.query ? <Row label="Query" value={card.query} /> : null}
        {card.limit != null ? <Row label="Limit" value={String(card.limit)} /> : null}
      </CardShell>
    )
  }

  if (card.kind === "malformed") {
    return (
      <CardShell>
        {card.query ? <Row label="Query" value={card.query} /> : null}
        {card.limit != null ? <Row label="Limit" value={String(card.limit)} /> : null}
        <EmptyState>Unexpected Syrus Docs search response.</EmptyState>
      </CardShell>
    )
  }

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Query" value={card.query || "(blank)"} />
        {card.limit != null ? <Row label="Limit" value={String(card.limit)} /> : null}
        <Row label="Hits" value={String(card.count)} />
      </dl>
      {card.results.length === 0 ? (
        <EmptyState>{card.message || "No matching documentation found."}</EmptyState>
      ) : (
        <div className="space-y-1">
          <SectionLabel>Ranked results</SectionLabel>
          <FilterableList
            itemText={(result) =>
              [result.title, result.heading, result.path, result.source, result.reference, result.text, result.score].filter((value) => value != null).join(" ")
            }
            items={card.results}
            placeholder="Filter doc results"
          >
            {(results) => <ResultList results={results} />}
          </FilterableList>
        </div>
      )}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "ranked_markdown_results",
    label: "Ranked Markdown documentation results",
    description: "Shows linked document references, relevance scores, and an expandable Markdown snippet.",
    input: { query: "landing queue", limit: 3 },
    parsedResult: {
      query: "landing queue",
      count: 1,
      results: [
        {
          rank: 1,
          score: 2,
          title: "Landing Queue",
          heading: "How landing works",
          path: "config/syrus_docs/landing_queue.md",
          source: "core",
          reference: "config/syrus_docs/landing_queue.md > How landing works",
          text: "## Landing Queue > How landing works\n\nSyrus checks `mergeability` before landing. See JOB-42 for an example."
        }
      ]
    },
    sourceType: "generic"
  }
]

const searchSyrusDocsToolCard: ToolCardRenderer = {
  toolName: "search_syrus_docs",
  collapsedSummary,
  renderExpanded
}

export default searchSyrusDocsToolCard
