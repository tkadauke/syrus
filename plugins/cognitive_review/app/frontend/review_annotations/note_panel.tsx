import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useRef, type FocusEvent } from "react"
import type { PluginReviewAnnotationComponentProps } from "@app/pluginReviewAnnotations"
import { Button } from "@app/components/Button"
import { useT } from "@app/hooks/useT"
import { acknowledgeCognitiveReviewNote, startCognitiveReviewNoteDiscussion } from "../api/cognitiveReviewNotes"

type CognitiveReviewNote = {
  confidence?: number | null
  discussion_entries?: Array<{ body: string; created_at?: string | null; id: number }>
  end_line: number
  explanation?: string | null
  handled?: boolean | null
  handled_by_comment?: boolean | null
  open_unhandled?: boolean | null
  job_id: number
  note_id: number
  path: string
  priority?: string | null
  reason_codes?: string[]
  side: "old" | "new"
  start_line: number
  state?: string | null
  summary?: string | null
  title?: string | null
}

type NotePanelProps = {
  hide_header?: boolean
  notes?: CognitiveReviewNote[]
  rollup?: {
    acknowledged_count?: number
    discussed_count?: number
    dismissed_count?: number
    handled_count?: number
    open_unhandled_count?: number
    total_flagged_ranges?: number
    user_commented_count?: number
    zero_note_state?: boolean
  }
  total?: number
}
type NotePanelItemProps = NotePanelProps & Partial<CognitiveReviewNote>

const VISIBLE_NOTE_LIMIT = 12
const NOTE_CARD_CLASS = [
  "rounded border p-3 text-sm text-text-primary focus-within:ring-2"
].join(" ")
const OPEN_NOTE_CARD_CLASS = "border-warning-border bg-warning-bg/45 focus-within:ring-warning-border"
const HANDLED_NOTE_CARD_CLASS = "border-success-border bg-success-bg/35 focus-within:ring-success-border"
const AGENT_NOTE_BADGE_CLASS = [
  "shrink-0 rounded border bg-surface px-1.5 py-0.5",
  "text-2xs font-semibold uppercase"
].join(" ")
const METADATA_CHIP_CLASS = "rounded border border-border bg-surface px-1.5 py-0.5 text-2xs text-text-secondary"

export default function CognitiveReviewNotePanel({ item }: PluginReviewAnnotationComponentProps) {
  const { t } = useT("cognitive_review")
  const props = (item.props ?? {}) as NotePanelItemProps
  const notes = Array.isArray(props.notes) ? props.notes : isCognitiveReviewNote(props) ? [props] : []
  const rollup = props.rollup
  const total = typeof rollup?.total_flagged_ranges === "number" ? rollup.total_flagged_ranges : typeof props.total === "number" ? props.total : notes.length
  const hideHeader = props.hide_header === true
  const visibleNotes = notes.slice(0, VISIBLE_NOTE_LIMIT)
  const hiddenCount = Math.max(0, notes.length - visibleNotes.length)

  return (
    <div className="space-y-3">
      {hideHeader ? null : <div>
        <div className="text-sm font-semibold text-text-primary">{t("panel.title")}</div>
        <p className="mt-1 text-xs text-text-secondary">{summaryText(t, rollup, total)}</p>
      </div>}
      {rollup ? <RollupGrid rollup={rollup} /> : null}
      {visibleNotes.length > 0 ? (
        <div className="space-y-3">
          {visibleNotes.map((note) => (
            <CognitiveReviewNoteCard key={note.note_id} note={note} />
          ))}
        </div>
      ) : null}
      {hiddenCount > 0 ? <p className="text-xs text-text-muted">{t("panel.hidden_count", { count: hiddenCount })}</p> : null}
    </div>
  )
}

function isCognitiveReviewNote(props: NotePanelItemProps): props is CognitiveReviewNote {
  return typeof props.note_id === "number" && typeof props.job_id === "number" && typeof props.path === "string"
}

function RollupGrid({ rollup }: { rollup: NonNullable<NotePanelProps["rollup"]> }) {
  const { t } = useT("cognitive_review")
  const cells = [
    { key: "total", label: t("rollup.total"), value: rollup.total_flagged_ranges ?? 0 },
    { key: "open", label: t("rollup.open"), value: rollup.open_unhandled_count ?? 0 },
    { key: "handled", label: t("rollup.handled"), value: rollup.handled_count ?? 0 },
    { key: "dismissed", label: t("rollup.dismissed"), value: rollup.dismissed_count ?? 0 }
  ]

  return (
    <div className="grid grid-cols-2 gap-2">
      {cells.map((cell) => (
        <div className="rounded border border-border bg-surface px-2 py-1.5" key={cell.key}>
          <div className="text-2xs font-semibold uppercase text-text-muted">{cell.label}</div>
          <div className="text-sm font-semibold text-text-primary">{cell.value}</div>
        </div>
      ))}
    </div>
  )
}

function summaryText(t: ReturnType<typeof useT>["t"], rollup: NotePanelProps["rollup"], total: number) {
  if (rollup?.zero_note_state) return t("panel.zero_summary")
  if (rollup) {
    return t("panel.rollup_summary", {
      acknowledged: rollup.acknowledged_count ?? 0,
      count: total,
      discussed: rollup.discussed_count ?? 0,
      dismissed: rollup.dismissed_count ?? 0,
      handled: rollup.handled_count ?? 0,
      open: rollup.open_unhandled_count ?? 0,
      user_commented: rollup.user_commented_count ?? 0
    })
  }
  return t("panel.summary", { count: total })
}

function CognitiveReviewNoteCard({ note }: { note: CognitiveReviewNote }) {
  const { t } = useT("cognitive_review")
  const queryClient = useQueryClient()
  const hoveredRef = useRef(false)
  const focusedRef = useRef(false)
  const highlightConditionRefs = { focus: focusedRef, hover: hoveredRef }
  const annotationId = `cognitive_review_note:${note.note_id}`
  const handled = note.handled ?? note.handled_by_comment ?? (note.state === "acknowledged" || note.state === "discussed")
  const openUnhandled = note.open_unhandled ?? !handled
  const title = note.title || note.summary || t("note.fallback_title")
  const rangeLabel = t("note.range", {
    end: note.end_line,
    path: note.path,
    side: t(`note.side.${note.side}`),
    start: note.start_line
  })

  const acknowledge = useMutation({
    mutationFn: () => acknowledgeCognitiveReviewNote(note.job_id, note.note_id),
    onSuccess: () => invalidateReviewQueries(queryClient, note.job_id)
  })
  const discuss = useMutation({
    mutationFn: () => startCognitiveReviewNoteDiscussion(note.job_id, note.note_id),
    onSuccess: (payload) => {
      invalidateReviewQueries(queryClient, note.job_id)
      window.location.assign(payload.redirect_to)
    }
  })

  function focusRange() {
    window.dispatchEvent(
      new CustomEvent("syrus:focus-review-annotation", {
        detail: {
          annotationId,
          line: note.start_line,
          path: note.path,
          side: note.side
        }
      })
    )
  }

  function highlightRange(active: boolean) {
    window.dispatchEvent(
      new CustomEvent("syrus:highlight-review-annotation", {
        detail: {
          annotationId: active ? annotationId : null
        }
      })
    )
  }

  function setHighlightCondition(kind: "focus" | "hover", active: boolean) {
    highlightConditionRefs[kind].current = active
    highlightRange(focusedRef.current || hoveredRef.current)
  }

  function clearHighlightOnBlur(event: FocusEvent<HTMLElement>) {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return
    setHighlightCondition("focus", false)
  }

  return (
    <article
      className={`${NOTE_CARD_CLASS} ${openUnhandled ? OPEN_NOTE_CARD_CLASS : HANDLED_NOTE_CARD_CLASS}`}
      data-cognitive-review-note-id={note.note_id}
      data-cognitive-review-note-state={handled ? "handled" : "open"}
      onBlur={clearHighlightOnBlur}
      onFocus={() => setHighlightCondition("focus", true)}
      onMouseEnter={() => setHighlightCondition("hover", true)}
      onMouseLeave={() => setHighlightCondition("hover", false)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="font-medium">{title}</div>
          <button className="mt-1 truncate text-left text-xs text-text-secondary underline-offset-2 hover:underline" onClick={focusRange} type="button">
            {rangeLabel}
          </button>
        </div>
        <span className={`${AGENT_NOTE_BADGE_CLASS} ${openUnhandled ? "border-warning-border text-warning-text" : "border-success-border text-success-text"}`}>
          {handled ? t("note.handled") : t("note.agent_authored")}
        </span>
      </div>
      {note.explanation ? <p className="mt-2 whitespace-pre-wrap text-sm text-text-secondary">{note.explanation}</p> : null}
      <NoteMetadata note={note} />
      <LegacyDiscussionEntries entries={note.discussion_entries ?? []} />
      <div className="mt-3 flex flex-wrap gap-2">
        {openUnhandled && !acknowledge.isPending && !discuss.isPending ? (
          <Button onClick={() => acknowledge.mutate()} size="sm" variant="secondary">
            {t("actions.acknowledge")}
          </Button>
        ) : null}
        <Button disabled={acknowledge.isPending || discuss.isPending} onClick={() => discuss.mutate()} size="sm" variant="secondary">
          {discuss.isPending ? t("actions.discussing") : t("actions.discuss")}
        </Button>
      </div>
      {acknowledge.isError || discuss.isError ? <p className="mt-2 text-xs text-danger-text">{t("actions.error")}</p> : null}
    </article>
  )
}

function LegacyDiscussionEntries({ entries }: { entries: NonNullable<CognitiveReviewNote["discussion_entries"]> }) {
  const { t } = useT("cognitive_review")
  if (entries.length === 0) return null

  return (
    <div className="mt-3 space-y-1.5 rounded border border-border bg-surface/80 p-2">
      <div className="text-2xs font-semibold uppercase text-text-muted">{t("note.legacy_discussion_entries")}</div>
      {entries.map((entry) => (
        <p className="whitespace-pre-wrap text-xs text-text-secondary" key={entry.id}>
          {entry.body}
        </p>
      ))}
    </div>
  )
}

function NoteMetadata({ note }: { note: CognitiveReviewNote }) {
  const { t } = useT("cognitive_review")
  const chips = [
    note.priority ? t("note.priority", { priority: note.priority }) : null,
    typeof note.confidence === "number" ? t("note.confidence", { confidence: Math.round(note.confidence * 100) }) : null,
    ...(note.reason_codes ?? [])
  ].filter((chip): chip is string => Boolean(chip))

  if (chips.length === 0) return null

  return (
    <div className="mt-2 flex flex-wrap gap-1.5">
      {chips.map((chip) => (
        <span className={METADATA_CHIP_CLASS} key={chip}>
          {chip}
        </span>
      ))}
    </div>
  )
}

function invalidateReviewQueries(queryClient: ReturnType<typeof useQueryClient>, jobId: number) {
  void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId), "review_source_diff"] })
  void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId), "diff_review_comments"] })
}
