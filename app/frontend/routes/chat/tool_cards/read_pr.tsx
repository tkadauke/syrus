import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, numberValue, SectionLabel, StatePill } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Core-owned tool card for read_pr (EPIC-291 / JOB-4221). Shows PR title,
// number (linked to GitHub when a URL is available), state, body preview,
// and the capped diff.
type PrDiff = { text: string; truncated: boolean; bytes: number | null; omittedBytes: number | null }

type PrCard = {
  number: string
  title: string
  state: string
  htmlUrl: string | null
  body: string | null
  diff: PrDiff | null
}

function parseDiff(value: unknown): PrDiff | null {
  if (!isPlainObject(value) || typeof value.text !== "string") return null
  return {
    text: value.text,
    truncated: value.truncated === true,
    bytes: numberValue(value.bytes),
    omittedBytes: numberValue(value.omitted_bytes)
  }
}

function parsePr(context: ToolCardContext): PrCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.pr)) return null

  const pr = parsed.pr
  const number = displayValue(pr.number)
  const state = displayValue(pr.state)
  if (!number || !state) return null

  return {
    number,
    title: displayValue(pr.title) || `PR #${number}`,
    state,
    htmlUrl: displayValue(pr.html_url),
    body: displayValue(pr.body),
    diff: parseDiff(pr.diff)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const pr = parsePr(context)
  if (!pr) return null
  return `PR #${pr.number} (${pr.state})`
}

function renderExpanded(context: ToolCardContext) {
  const pr = parsePr(context)
  if (!pr) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {pr.htmlUrl ? (
          <a className="font-mono font-semibold text-brand hover:underline dark:text-brand-emphasis" href={pr.htmlUrl} rel="noreferrer" target="_blank">
            #{pr.number}
          </a>
        ) : (
          <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{pr.number}</span>
        )}
        <StatePill state={pr.state} />
      </div>
      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{pr.title}</div>
      {pr.body ? <div className="whitespace-pre-wrap text-gray-600 dark:text-gray-300">{pr.body}</div> : null}
      {pr.diff ? (
        <div>
          <SectionLabel>Diff</SectionLabel>
          <div className="mt-1 space-y-1">
            <DiffStatBadges stats={diffStats(pr.diff.text)} />
            {pr.diff.truncated ? (
              <div className="text-2xs text-gray-500 dark:text-gray-400">
                Truncated{pr.diff.omittedBytes != null ? ` — ${pr.diff.omittedBytes} bytes omitted` : ""}
              </div>
            ) : null}
            <RawDiffPreview diff={pr.diff.text} />
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

const readPrToolCard: ToolCardRenderer = {
  toolName: "read_pr",
  collapsedSummary,
  renderExpanded
}

export default readPrToolCard
