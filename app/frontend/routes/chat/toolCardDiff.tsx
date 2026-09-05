import { diffLineClass, diffMarkerClass, parseUnifiedDiff } from "../../components/diff/diffRendering"

// Shared raw-diff summary/preview rendering for the get_job_diff, read_pr,
// and read_run_transcript tool cards (EPIC-291 / JOB-4221). Lives outside
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
      {stats.fileCount > 0 ? <span className="text-gray-600 dark:text-gray-300">{stats.fileCount} file{stats.fileCount === 1 ? "" : "s"}</span> : null}
      <span className="text-emerald-700 dark:text-emerald-300">+{stats.additions}</span>
      <span className="text-red-700 dark:text-red-300">-{stats.deletions}</span>
    </div>
  )
}

const PREVIEW_LINE_LIMIT = 300

export function RawDiffPreview({ diff }: { diff: string }) {
  const lines = parseUnifiedDiff(diff).slice(0, PREVIEW_LINE_LIMIT)
  if (lines.length === 0) return null

  return (
    <div className="max-h-72 overflow-auto rounded border border-gray-200 bg-white font-mono text-2xs dark:border-gray-800 dark:bg-gray-950">
      {lines.map((line, index) => (
        <div className={`flex ${diffLineClass(line.kind)}`} key={index}>
          <span className={diffMarkerClass(line.kind)}>{line.marker}</span>
          <span className="min-w-0 flex-1 whitespace-pre-wrap break-words px-2 py-0.5">{line.code || " "}</span>
        </div>
      ))}
    </div>
  )
}
