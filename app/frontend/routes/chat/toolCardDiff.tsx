import { useState } from "react"
import { Button, CodeSurface, Modal, Pill } from "../../components/ui"
import { diffLineClass, diffMarkerClass, parseUnifiedDiff } from "../../components/diff/diffRendering"

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
      {stats.fileCount > 0 ? <Pill tone="neutral">{stats.fileCount} file{stats.fileCount === 1 ? "" : "s"}</Pill> : null}
      <Pill tone="success">+{stats.additions}</Pill>
      <Pill tone="danger">-{stats.deletions}</Pill>
    </div>
  )
}

const PREVIEW_LINE_LIMIT = 300

export function RawDiffPreview({ diff }: { diff: string }) {
  const [open, setOpen] = useState(false)
  const allLines = parseUnifiedDiff(diff)
  const lines = allLines.slice(0, PREVIEW_LINE_LIMIT)
  const truncated = allLines.length > PREVIEW_LINE_LIMIT
  if (allLines.length === 0) return null

  const renderedLines = (selectedLines: typeof allLines) => selectedLines.map((line, index) => (
    <span className={`flex min-w-max ${diffLineClass(line.kind)}`} key={index}>
      <span className={diffMarkerClass(line.kind)}>{line.marker}</span>
      <span className={`px-2 py-0.5 whitespace-pre ${line.kind === "file" ? "font-semibold" : ""}`}>{line.code || " "}</span>
    </span>
  ))

  return (
    <div className="min-w-0 max-w-full space-y-1 overflow-hidden">
      <CodeSurface code={diff} copyLabel="Copy diff" maxHeightClassName="max-h-72" mode="multiline">
        <div className="max-w-full overflow-x-auto">{renderedLines(lines)}</div>
      </CodeSurface>
      {truncated ? (
        <div className="flex flex-wrap items-center gap-2 text-2xs text-text-muted">
          <span>Showing first {PREVIEW_LINE_LIMIT} of {allLines.length} lines.</span>
          <Button onClick={() => setOpen(true)} size="sm" variant="secondary">Show full diff</Button>
        </div>
      ) : null}
      <Modal className="flex h-[min(90dvh,60rem)] w-[min(96vw,80rem)] min-w-0 flex-col overflow-hidden bg-surface p-4" label="Full diff" onClose={() => setOpen(false)} open={open}>
        {open ? <div className="min-h-0 max-w-full flex-1 overflow-auto font-mono text-xs">{renderedLines(allLines)}</div> : null}
      </Modal>
    </div>
  )
}
