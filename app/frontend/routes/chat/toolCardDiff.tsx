import { CodeSurface, Pill } from "../../components/ui"
import { diffLineClass, diffMarkerClass, parseUnifiedDiff } from "../../components/diff/diffRendering"
import { useT } from "../../hooks/useT"

// Shared raw-diff summary/preview rendering for the get_job_diff, read_pr,
// and read_run_transcript tool cards (the Tier 1 tool-card work). Lives outside
// `tool_cards/` for the same reason as jobsTableCard.tsx / toolCardUi.tsx.
export type DiffStats = { fileCount: number; additions: number; deletions: number }

export function diffStats(diff: string): DiffStats {
  const lines = parseUnifiedDiff(diff)
  return {
    fileCount: lines.filter((line) => line.kind === "file").length,
    additions: lines.filter((line) => line.kind === "add").length,
    deletions: lines.filter((line) => line.kind === "delete").length
  }
}

export function DiffStatBadges({ stats }: { stats: DiffStats }) {
  return (
    <div className="flex flex-wrap items-center gap-2 font-mono text-2xs">
      {stats.fileCount > 0 ? (
        <Pill tone="neutral">
          {stats.fileCount} file{stats.fileCount === 1 ? "" : "s"}
        </Pill>
      ) : null}
      <Pill tone="success">+{stats.additions}</Pill>
      <Pill tone="danger">-{stats.deletions}</Pill>
    </div>
  )
}

const PREVIEW_LINE_LIMIT = 300

export function RawDiffPreview({ diff }: { diff: string }) {
  const { t } = useT("chat")
  const parsedLines = parseUnifiedDiff(diff)
  const lines = parsedLines.slice(0, PREVIEW_LINE_LIMIT)
  if (lines.length === 0) return null

  return (
    <div className="space-y-1">
      <CodeSurface code={diff} copyLabel="Copy diff" maxHeightClassName="max-h-72" mode="multiline">
        {lines.map((line, index) => (
          <span className={`flex ${diffLineClass(line.kind)}`} key={index}>
            <span className={diffMarkerClass(line.kind)}>{line.marker}</span>
            <span className="min-w-0 flex-1 whitespace-pre-wrap break-words px-2 py-0.5">{line.code || " "}</span>
          </span>
        ))}
      </CodeSurface>
      {parsedLines.length > PREVIEW_LINE_LIMIT ? (
        <div className="text-2xs text-text-muted">{t("tool_card_diff_preview_truncated", { shown: PREVIEW_LINE_LIMIT, total: parsedLines.length })}</div>
      ) : null}
    </div>
  )
}
