import { useState } from "react"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Modal } from "../../components/Modal"
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
const MODAL_PANEL_CLASS = [
  "flex h-[100dvh] w-full min-w-0 flex-col overflow-hidden bg-surface",
  "shadow-[var(--shadow-panel)] sm:h-[min(82dvh,52rem)] sm:max-w-5xl sm:rounded-[var(--radius-panel)]"
].join(" ")
const CLOSE_BUTTON_CLASS = [
  "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-[var(--radius-control)]",
  "text-text-muted hover:bg-surface-raised focus:outline-none focus:ring-2 focus:ring-brand"
].join(" ")

export function RawDiffPreview({ diff }: { diff: string }) {
  const { t } = useT("chat")
  const [open, setOpen] = useState(false)
  const allLines = parseUnifiedDiff(diff)
  const lines = allLines.slice(0, PREVIEW_LINE_LIMIT)
  const truncated = allLines.length > lines.length
  if (allLines.length === 0) return null

  const renderedLines = (visibleLines: typeof allLines) =>
    visibleLines.map((line, index) => (
      <span className={`flex min-w-max ${diffLineClass(line.kind)}`} key={index}>
        <span className={diffMarkerClass(line.kind)}>{line.marker}</span>
        <span className={`px-2 py-0.5 whitespace-pre ${line.kind === "file" ? "font-semibold" : ""}`}>{line.code || " "}</span>
      </span>
    ))

  return (
    <div className="min-w-0 max-w-full space-y-2 overflow-hidden">
      <CodeSurface code={diff} copyLabel={t("tool_card_copy_diff")} maxHeightClassName="max-h-72" mode="command">
        {renderedLines(lines)}
      </CodeSurface>
      {truncated ? (
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
          <span>{t("tool_card_diff_truncated", { shown: lines.length, total: allLines.length })}</span>
          <Button onClick={() => setOpen(true)} size="sm" variant="secondary">
            {t("tool_card_diff_show_all")}
          </Button>
        </div>
      ) : null}
      <Modal
        backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-black/50 p-0 sm:items-center sm:p-4"
        className={MODAL_PANEL_CLASS}
        label={t("tool_card_diff_full_title")}
        onClose={() => setOpen(false)}
        open={open}
      >
        <header className="flex shrink-0 items-center gap-3 border-b border-border px-4 py-3">
          <h2 className="min-w-0 flex-1 text-sm font-semibold text-text-primary">{t("tool_card_diff_full_title")}</h2>
          <button aria-label={t("tool_card_diff_close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon />
          </button>
        </header>
        <div className="min-h-0 min-w-0 flex-1 overflow-hidden p-4">
          <CodeSurface className="h-full" code={diff} copyLabel={t("tool_card_copy_diff")} maxHeightClassName="max-h-full" mode="command">
            {renderedLines(allLines)}
          </CodeSurface>
        </div>
      </Modal>
    </div>
  )
}
