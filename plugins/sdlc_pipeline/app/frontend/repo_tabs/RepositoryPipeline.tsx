import { useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { Button, Input, Modal, Notice, PageHeading, Section, Select, Text } from "@app/components/ui"
import { CloseIcon } from "@app/components/CloseIcon"
import { FilterBar } from "@app/components/FilterBar"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { TonePill } from "@app/components/StatusPill"
import { useT } from "@app/hooks/useT"
import { routePrefix } from "@app/lib/routing"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchPipeline,
  fetchPipelineStage,
  type PipelineGroup,
  type PipelineHistory,
  type PipelineItem,
  type PipelinePayload,
  type PipelineStage
} from "../api/pipeline"
import { layoutRail, railLabels } from "./historyRailScale"

const POLL_INTERVAL_MS = 30_000
const ITEM_CARD_CLASSES =
  "block rounded-[var(--radius-control)] border border-border bg-surface p-2.5 shadow-sm transition-colors hover:border-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const STAGE_HEADER_CLASSES =
  "w-full border-b border-border bg-surface/95 p-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand"
const SHOW_ALL_CLASSES =
  "mt-auto rounded p-1.5 text-left text-[length:var(--text-caption)] font-medium text-brand hover:bg-surface-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const RAIL_LABEL_CLASSES =
  "pointer-events-none absolute left-0 w-11 -translate-y-1/2 whitespace-nowrap pr-1 sm:w-14 sm:pr-1.5 text-right text-[10px] leading-none"
const RAIL_TICK_CLASSES =
  "absolute left-[3rem] z-20 flex h-3.5 w-6 sm:left-[4rem] sm:w-8 -translate-y-1/2 items-center justify-center rounded-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const TICK_TONE = { attention: "text-danger-text", deployment: "text-info", movement: "text-text-muted" } as const
const SELECTED_CHIP_CLASSES = "mb-1 shrink-0 break-words rounded bg-surface-raised px-1 py-0.5 text-center text-2xs font-semibold leading-tight text-brand"
const STAGE_SCROLLER_CLASSES =
  "flex min-h-0 flex-1 snap-x gap-3 overflow-x-auto px-3 pb-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const PRESENTATION_LINK_CLASSES =
  "shrink-0 rounded border border-border px-3 py-2 text-sm font-medium text-text-primary hover:bg-surface-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
type Translate = (key: string, options?: Record<string, unknown>) => string

type HistoryEventKind = "attention" | "deployment" | "movement"

function historyEventKind(stages: Array<string | null>): HistoryEventKind {
  if (stages.some((stage) => stage === "failed" || stage === "blocked")) return "attention"
  if (stages.some((stage) => stage?.startsWith("deployment:") || stage === "released")) return "deployment"
  return "movement"
}

function duration(seconds: number | null, t: Translate) {
  if (seconds == null) return t("not_available")
  if (seconds < 3600) return t("minutes", { count: Math.max(1, Math.floor(seconds / 60)) })
  if (seconds < 86_400) return t("hours", { count: Math.floor(seconds / 3600) })
  return t("days", { count: Math.floor(seconds / 86_400) })
}

function ItemCard({ item, onTrace, releaseTail = false }: { item: PipelineItem; onTrace?: () => void; releaseTail?: boolean }) {
  const { t } = useT("sdlc_pipeline")
  const opacity = releaseTail ? Math.max(0.68, 1 - (item.age_seconds / (30 * 86_400)) * 0.32) : 1
  return (
    <div className={`${ITEM_CARD_CLASSES} ${item.needs_attention ? "border-l-4 border-l-danger" : ""}`} style={{ opacity }}>
      <div className="flex items-center gap-2">
        <span className="font-mono text-2xs font-semibold text-text-secondary">{item.slug}</span>
        {item.pinned ? <TonePill tone="blue">{t("pinned")}</TonePill> : null}
        <span className="ml-auto text-2xs text-text-subtle">{duration(item.age_seconds, t)}</span>
      </div>
      <div className="mt-1 text-[length:var(--text-caption)] font-semibold leading-5 text-text-primary">{item.title}</div>
      <div className="mt-2 flex flex-wrap items-center gap-1.5 text-2xs text-text-muted">
        {item.needs_attention ? <TonePill tone="amber">{item.attention_reason || t("attention")}</TonePill> : null}
        <span>{t(`evidence_${item.evidence.type}`)}</span>
      </div>
      <div className="mt-2 flex flex-wrap gap-2 text-2xs font-medium">
        {onTrace ? (
          <button className="text-brand hover:underline" onClick={onTrace} type="button">
            {t("view_trace")}
          </button>
        ) : null}
        <Link className="text-brand hover:underline" to={item.paths.job}>
          {t("job_details")}
        </Link>
        {item.paths.workflow ? (
          <Link className="text-brand hover:underline" to={item.paths.workflow}>
            {t("workflow_details")}
          </Link>
        ) : null}
        {item.paths.delivery ? (
          <Link className="text-brand hover:underline" to={item.paths.delivery}>
            {t("deployment_details")}
          </Link>
        ) : null}
        {releaseTail && item.paths.release ? (
          <Link className="text-brand hover:underline" to={item.paths.release}>
            {t("release_details")}
          </Link>
        ) : null}
      </div>
    </div>
  )
}

function Aggregate({ group, onTrace, stage }: { group: PipelineGroup; onTrace?: () => void; stage: PipelineStage }) {
  const { t } = useT("sdlc_pipeline")
  const count = group.stage_totals[stage.key] || 0
  if (!count) return null
  const body = (
    <div className="rounded-[var(--radius-control)] border border-dashed border-border bg-surface-subtle p-2.5 hover:border-brand">
      <div className="flex items-center gap-2 text-[length:var(--text-caption)] font-medium text-text-primary">
        <span className="truncate">{group.label}</span>
        <span className="ml-auto">
          <TonePill tone="gray">{count}</TonePill>
        </span>
      </div>
      <div className="mt-2 h-1 overflow-hidden rounded-full bg-surface-raised">
        <div className="h-full rounded-full bg-brand" style={{ width: `${Math.max(8, (count / group.total) * 100)}%` }} />
      </div>
    </div>
  )
  if (onTrace) {
    return (
      <button className="text-left" onClick={onTrace} type="button">
        {body}
        <span className="mt-1 block text-2xs text-brand">{t("view_epic_trace")}</span>
      </button>
    )
  }
  return group.epic ? <Link to={`/epics/${group.epic.slug}`}>{body}</Link> : body
}

function StageColumn({
  groups,
  onOpen,
  onEpicTrace,
  onTrace,
  releaseTail,
  fill = false,
  stage
}: {
  fill?: boolean
  groups: PipelineGroup[]
  onOpen: () => void
  onEpicTrace?: (group: PipelineGroup) => void
  onTrace?: (item: PipelineItem) => void
  releaseTail: boolean
  stage: PipelineStage
}) {
  const { t } = useT("sdlc_pipeline")
  const stageGroups = groups.filter((group) => (group.stage_totals[stage.key] || 0) > 0)
  return (
    <Section.Root
      aria-label={t("stage_aria", { stage: stage.label, count: stage.total })}
      className={`flex ${fill ? "h-full" : "h-[31rem]"} w-[17rem] shrink-0 flex-col overflow-hidden p-0 ${stage.kind === "deployment" ? "bg-surface-subtle" : ""}`}
      data-stage={stage.key}
    >
      <button className={STAGE_HEADER_CLASSES} onClick={onOpen} type="button">
        <div className="flex items-center gap-2">
          <span aria-hidden className={`h-2 w-2 rounded-full ${stage.kind === "deployment" ? "bg-info" : "bg-text-subtle"}`} />
          <span className="font-semibold text-text-primary">{stage.label}</span>
          {stage.release_tail ? <TonePill tone="blue">{t("recent_releases")}</TonePill> : null}
          <span className="ml-auto">
            <TonePill tone={stage.attention_count ? "amber" : "gray"}>{stage.total}</TonePill>
          </span>
        </div>
        <div className="mt-1.5 flex flex-wrap gap-x-2 text-2xs text-text-muted">
          {stage.attention_count ? <span className="font-semibold text-danger-text">{t("attention_count", { count: stage.attention_count })}</span> : null}
          {stage.aging_count ? <span>{t("aging_count", { count: stage.aging_count })}</span> : null}
          {stage.oldest_age_seconds != null ? <span>{t("oldest", { age: duration(stage.oldest_age_seconds, t) })}</span> : null}
        </div>
      </button>
      <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-2.5">
        {stage.highlighted_items.map((item) => (
          <ItemCard item={item} key={item.id} onTrace={onTrace ? () => onTrace(item) : undefined} releaseTail={releaseTail} />
        ))}
        {stageGroups.slice(0, 4).map((group) => (
          <Aggregate group={group} key={group.key} onTrace={group.epic && onEpicTrace ? () => onEpicTrace(group) : undefined} stage={stage} />
        ))}
        {!stage.total ? (
          <div className="rounded border border-dashed border-border p-5 text-center text-[length:var(--text-caption)] text-text-muted">{t("empty_stage")}</div>
        ) : null}
        {stage.total > stage.highlighted_items.length ? (
          <button className={SHOW_ALL_CLASSES} onClick={onOpen} type="button">
            {t("show_all", { count: stage.total })} →
          </button>
        ) : null}
      </div>
    </Section.Root>
  )
}

function DrillDown({ onClose, repositoryId, search, stage }: { onClose: () => void; repositoryId: string; search: string; stage: PipelineStage }) {
  const { t } = useT("sdlc_pipeline")
  const [page, setPage] = useState(1)
  const result = useQuery({
    queryKey: ["repositories", repositoryId, "sdlc_pipeline", search, stage.key, page],
    queryFn: () => fetchPipelineStage(repositoryId, stage.key, page, search),
    placeholderData: (previous) => previous
  })
  const drill = result.data?.drill_down
  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex justify-end bg-black/30"
      className="h-full w-full max-w-md overflow-y-auto border-l border-border bg-surface p-5 shadow-xl"
      label={t("drill_down_aria", { stage: stage.label })}
      onClose={onClose}
      open
    >
      <div className="flex items-start gap-3">
        <div>
          <Text variant="caption" tone="muted">
            {stage.kind === "deployment" ? t("observational_evidence") : t("lifecycle_fact")}
          </Text>
          <PageHeading className="mt-1">{stage.label}</PageHeading>
        </div>
        <Button aria-label={t("close")} className="ml-auto" onClick={onClose} size="sm" variant="secondary">
          <CloseIcon />
        </Button>
      </div>
      <Text className="mt-2" tone="muted">
        {stage.kind === "deployment" ? t("evidence_explanation") : t("lifecycle_explanation")}
      </Text>
      {result.isPending ? <Notice className="mt-4">{t("loading_items")}</Notice> : null}
      {result.isError ? (
        <Notice className="mt-4" tone="danger">
          {errorMessage(result.error, t("load_error"))}
        </Notice>
      ) : null}
      <div className="mt-5 space-y-2">
        {drill?.items.map((item) => (
          <ItemCard item={item} key={item.id} releaseTail={Boolean(stage.release_tail)} />
        ))}
      </div>
      <div className="mt-4 flex items-center justify-between">
        <Button disabled={page === 1} onClick={() => setPage((value) => value - 1)} size="sm" variant="secondary">
          {t("previous")}
        </Button>
        <Text variant="caption" tone="muted">
          {t("page", { page, pages: Math.max(1, Math.ceil((drill?.total || stage.total) / (drill?.limit || 25))), total: drill?.total || stage.total })}
        </Text>
        <Button disabled={!drill?.next_page} onClick={() => setPage((value) => value + 1)} size="sm" variant="secondary">
          {t("next")}
        </Button>
      </div>
    </Modal>
  )
}

type EventMark = { tick: string; index: number; kind: HistoryEventKind; count: number }

function EventGlyph({ kind }: { kind: HistoryEventKind }) {
  if (kind === "attention") return <span className="text-[10px] font-bold leading-none">!</span>
  if (kind === "deployment") return <span className="h-1.5 w-1.5 rotate-45 bg-current" />
  return <span className="h-px w-3 bg-current" />
}

/**
 * Independently scrolling, time-proportional rail (newest at the top). Geometry lives in
 * `historyRailScale.ts`. Scrolling here never touches the pipeline canvas: the selected time is kept
 * in view by assigning this container's own scrollTop rather than using scrollIntoView.
 */
function HistoryTrack({
  currentTick,
  eventMarks,
  historical,
  historicalAt,
  history,
  onSelect
}: {
  currentTick: number
  eventMarks: EventMark[]
  historical: boolean
  historicalAt: string | null
  history: PipelineHistory
  onSelect: (at: string | null) => void
}) {
  const { t } = useT("sdlc_pipeline")
  const scrollRef = useRef<HTMLDivElement>(null)
  const fromMs = timeMs(history.from)
  const toMs = timeMs(history.to)
  const layout = useMemo(() => layoutRail(history.ticks, fromMs, toMs), [history.ticks, fromMs, toMs])
  const labels = useMemo(() => railLabels(layout, fromMs, toMs), [layout, fromMs, toMs])
  const selectedY = !historical ? 0 : currentTick >= 0 ? layout.tickY[currentTick] : historicalAt ? layout.yFor(timeMs(historicalAt)) : 0
  const selectedIndex = historical ? Math.max(0, currentTick) : history.ticks.length

  useEffect(() => {
    const node = scrollRef.current
    if (!node) return
    const margin = 48
    if (selectedY >= node.scrollTop + margin && selectedY <= node.scrollTop + node.clientHeight - margin) return
    const top = Math.max(0, selectedY - node.clientHeight / 2)
    if (typeof node.scrollTo === "function") {
      node.scrollTo({ top, behavior: window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" })
    } else {
      node.scrollTop = top
    }
  }, [historicalAt, historical, history.from, history.to, history.ticks.length])

  return (
    <div className="relative flex min-h-0 w-full flex-1 flex-col" data-testid="compact-pipeline-time-rail">
      <div className={SELECTED_CHIP_CLASSES} data-testid="selected-history-time">
        {historical && historicalAt
          ? new Date(historicalAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
          : t("now")}
      </div>
      <Input
        aria-label={`${t("history_short")} ${t("time_scrubber")}`}
        className="sr-only"
        max={history.ticks.length}
        min={0}
        onChange={(event) => onSelect(event.target.value === String(history.ticks.length) ? null : history.ticks[Number(event.target.value)] || history.from)}
        type="range"
        value={selectedIndex}
      />
      <div className="relative min-h-0 flex-1">
        <div
          className="absolute inset-0 touch-pan-y overflow-y-auto overscroll-contain"
          data-testid="history-rail-scroll"
          ref={scrollRef}
          tabIndex={0}
          aria-label={`${t("history_short")} ${t("history_range", { from: new Date(history.from).toLocaleDateString(), to: new Date(history.to).toLocaleDateString() })}`}
          role="group"
        >
          <div className="relative w-full" data-testid="history-rail-content" style={{ height: layout.height }}>
            <div aria-hidden className="absolute bottom-2 left-[2.75rem] top-2 w-px bg-border sm:left-[3.75rem]" />
            {labels.map((label) => (
              <span
                aria-hidden
                className={`${RAIL_LABEL_CLASSES} ${label.major ? "font-semibold text-text-secondary" : "text-text-subtle"}`}
                data-testid="history-rail-label"
                key={label.at}
                style={{ top: label.y }}
              >
                {label.major
                  ? new Date(label.at).toLocaleDateString([], { month: "short", day: "numeric" })
                  : new Date(label.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
              </span>
            ))}
            <div
              aria-hidden
              className="pointer-events-none absolute left-[2.25rem] z-10 h-0.5 w-2 -translate-y-1/2 bg-brand sm:left-[3.25rem]"
              data-testid="history-rail-cursor"
              style={{ top: selectedY }}
            />
            {eventMarks.map((mark) => {
              const active = historical && mark.index === currentTick
              const label = t("event_mark", { time: new Date(mark.tick).toLocaleString(), type: t(`event_type_${mark.kind}`), count: mark.count })
              return (
                <button
                  aria-label={active ? t("event_marker", { time: new Date(mark.tick).toLocaleString() }) : label}
                  aria-pressed={active}
                  className={`${RAIL_TICK_CLASSES} ${active ? "bg-brand/15 text-brand ring-1 ring-brand" : TICK_TONE[mark.kind]}`}
                  data-event-kind={mark.kind}
                  key={mark.tick}
                  onClick={() => onSelect(mark.tick)}
                  style={{ top: layout.tickY[mark.index] }}
                  title={label}
                  type="button"
                >
                  <EventGlyph kind={mark.kind} />
                </button>
              )
            })}
          </div>
        </div>
      </div>
    </div>
  )
}

function HistoryRail({
  currentTick,
  eventMarks,
  historical,
  historicalAt,
  history,
  incompleteEvidenceCount,
  onRangeChange,
  onSelect,
  playing,
  setPlaying
}: {
  currentTick: number
  eventMarks: EventMark[]
  historical: boolean
  historicalAt: string | null
  history: PipelineHistory
  incompleteEvidenceCount: number
  onRangeChange: (days: number) => void
  onSelect: (at: string | null) => void
  playing: boolean
  setPlaying: (value: boolean | ((current: boolean) => boolean)) => void
}) {
  const { t } = useT("sdlc_pipeline")
  return (
    <Section.Root
      aria-label={t("history_aria")}
      className="flex min-h-0 w-28 shrink-0 flex-col items-stretch gap-2 self-stretch overflow-hidden p-2 sm:w-44 sm:p-3"
    >
      <div>
        <Section.Title>{t("history_short")}</Section.Title>
        <Text className="mt-1 break-words leading-tight" variant="caption" tone="muted">
          {historical && historicalAt
            ? new Date(historicalAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
            : t("live_mode")}
        </Text>
      </div>
      {incompleteEvidenceCount > 0 ? (
        <details className="text-2xs text-warning-text">
          <summary className="cursor-pointer rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand">
            {t("partial_evidence_short")}
          </summary>
          <Text className="mt-1" variant="caption" tone="muted">
            {t("partial_evidence", { count: incompleteEvidenceCount })}
          </Text>
        </details>
      ) : null}
      <div className="grid w-full grid-cols-2 gap-1">
        <Button
          aria-label={`${t("history_short")} ${playing ? t("pause_history") : t("play_history")}`}
          disabled={!history.ticks.length}
          onClick={() => {
            if (!historical) onSelect(history.ticks[0])
            setPlaying((value) => !value)
          }}
          size="icon"
          title={history.ticks.length ? (playing ? t("pause_history") : t("play_history")) : t("history_controls_unavailable")}
          variant="secondary"
        >
          {playing ? "Ⅱ" : "▶"}
        </Button>
        <Button
          aria-label={`${t("history_short")} ${t("return_now")}`}
          disabled={!historical}
          onClick={() => onSelect(null)}
          size="icon"
          title={t("return_now")}
          variant="secondary"
        >
          ●
        </Button>
        <Button
          aria-label={`${t("history_short")} ${t("previous_tick")}`}
          disabled={!history.ticks.length || (historical && currentTick <= 0)}
          onClick={() => onSelect(historical ? history.ticks[currentTick - 1] : history.ticks[history.ticks.length - 1])}
          size="icon"
          title={!history.ticks.length || (historical && currentTick <= 0) ? t("history_no_previous") : t("previous_tick")}
          variant="secondary"
        >
          ‹
        </Button>
        <Button
          aria-label={`${t("history_short")} ${t("next_tick")}`}
          disabled={!historical || currentTick >= history.ticks.length - 1}
          onClick={() => onSelect(history.ticks[currentTick + 1])}
          size="icon"
          title={!historical || currentTick >= history.ticks.length - 1 ? t("history_no_next") : t("next_tick")}
          variant="secondary"
        >
          ›
        </Button>
      </div>
      <HistoryTrack
        currentTick={currentTick}
        eventMarks={eventMarks}
        historical={historical}
        historicalAt={historicalAt}
        history={history}
        onSelect={onSelect}
      />
      <div>
        <label className="text-2xs text-text-muted">
          <span className="sr-only sm:not-sr-only">{t("history_short")} </span>
          {t("history_window")}
          <Select
            className="px-1 py-1 text-2xs sm:mt-1 sm:px-2"
            fullWidth
            onChange={(event) => onRangeChange(Number(event.target.value))}
            value={Math.max(1, Math.round((new Date(history.to).getTime() - new Date(history.from).getTime()) / 86_400_000))}
          >
            <option value="1">{t("one_day")}</option>
            <option value="7">{t("seven_days")}</option>
            <option value="30">{t("thirty_days")}</option>
            <option value="90">{t("ninety_days")}</option>
          </Select>
        </label>
      </div>
      {historical && historicalAt ? (
        <Text variant="caption" tone="muted">
          {t("historical_banner_compact", { time: new Date(historicalAt).toLocaleString() })}
        </Text>
      ) : null}
      {history.accuracy.message ? (
        <Text variant="caption" tone="muted">
          {history.accuracy.message}
        </Text>
      ) : null}
    </Section.Root>
  )
}

type HistoryStatus = "loading" | "error" | "empty" | "incomplete" | "ready"

function HistoryStatusNotice({ onRetry, status }: { onRetry: () => void; status: HistoryStatus }) {
  const { t } = useT("sdlc_pipeline")
  if (status === "ready") return null
  return (
    <div className="px-3 pb-1" data-testid="history-status" data-history-status={status} role="status">
      {status === "loading" ? <Notice>{t("history_loading")}</Notice> : null}
      {status === "empty" ? (
        <Text variant="caption" tone="muted">
          {t("history_empty")}
        </Text>
      ) : null}
      {status === "incomplete" ? (
        <Text className="text-warning-text" variant="caption">
          {t("history_incomplete")}
        </Text>
      ) : null}
      {status === "error" ? (
        <Notice tone="danger">
          {t("history_error")}
          <Button className="ml-2" onClick={onRetry} size="sm" variant="secondary">
            {t("retry_history")}
          </Button>
        </Notice>
      ) : null}
    </div>
  )
}

function PipelineOverview({
  embedded = false,
  historyStatus = "ready",
  onRetryHistory = () => {},
  payload,
  repositoryId,
  search
}: {
  embedded?: boolean
  historyStatus?: HistoryStatus
  onRetryHistory?: () => void
  payload: PipelinePayload
  repositoryId: string
  search: string
}) {
  const { t } = useT("sdlc_pipeline")
  const scroller = useRef<HTMLDivElement>(null)
  const [selected, setSelected] = useState<PipelineStage | null>(null)
  const [edges, setEdges] = useState({ left: false, right: false })
  const [traceJobId, setTraceJobId] = useState<number | null>(null)
  const [traceEpic, setTraceEpic] = useState<PipelineGroup["epic"] | null>(null)
  const [playing, setPlaying] = useState(false)
  const selectedAt = new URLSearchParams(search).get("at")
  const historical = Boolean(selectedAt)
  const history = payload.history ?? {
    from: payload.generated_at,
    to: payload.generated_at,
    checkpoint: { at: payload.generated_at, placements: [] },
    deltas: [],
    ticks: [],
    traces: [],
    accuracy: { status: "reconstructed" as const, message: "", truncated: false }
  }
  const requestedAt = selectedAt ? new Date(selectedAt).getTime() : Number.NaN
  const historicalAt = selectedAt
    ? new Date(
        Math.min(
          Math.max(Number.isFinite(requestedAt) ? requestedAt : new Date(history.to).getTime(), new Date(history.from).getTime()),
          new Date(history.to).getTime()
        )
      ).toISOString()
    : null
  const tracesByJob = useMemo(() => new Map(history.traces.map((trace) => [trace.job_id, trace])), [history.traces])
  const displayedPayload = useMemo(() => {
    if (!selectedAt) return payload
    const at = new Date(historicalAt!).getTime()
    const placements = new Map(history.checkpoint.placements.map((placement) => [placement.job_id, placement]))
    history.deltas.forEach((delta) => {
      if (new Date(delta.at).getTime() > at) return
      if (!delta.to_stage || !delta.item) placements.delete(delta.job_id)
      else placements.set(delta.job_id, delta.item)
    })
    const byStage = new Map<string, typeof history.checkpoint.placements>()
    placements.forEach((placement) => byStage.set(placement.stage, [...(byStage.get(placement.stage) || []), placement]))
    const stages = payload.stages.map((stage) => {
      const rows = byStage.get(stage.key) || []
      const highlighted_items = rows.map(({ item }) => ({
        ...item,
        needs_attention: false,
        age_seconds: Math.max(
          0,
          (at -
            new Date(
              tracesByJob.get(item.id)?.segments.find((segment) => at >= timeMs(segment.entered_at) && timeMs(segment.left_at) >= at)?.entered_at ||
                historicalAt!
            ).getTime()) /
            1000
        ),
        evidence: { type: "historical_reconstruction" }
      }))
      return {
        ...stage,
        total: rows.length,
        attention_count: 0,
        aging_count: 0,
        oldest_age_seconds: highlighted_items.length ? Math.max(...highlighted_items.map((item) => item.age_seconds)) : null,
        highlighted_items
      }
    })
    const grouped = new Map<string, PipelineGroup>()
    placements.forEach((placement) => {
      const epic = placement.item.epic
      const key = epic ? `epic:${epic.id}` : "ungrouped"
      const group = grouped.get(key) || { key, label: epic?.title || "Ungrouped", epic, total: 0, stage_totals: {} }
      group.total += 1
      group.stage_totals[placement.stage] = (group.stage_totals[placement.stage] || 0) + 1
      grouped.set(key, group)
    })
    return { ...payload, stages, groups: [...grouped.values()] }
  }, [payload, selectedAt, historicalAt, history, tracesByJob])
  const stages = displayedPayload.stages
  const navigate = useNavigate()
  function setAt(at: string | null) {
    const params = new URLSearchParams(search)
    if (at) params.set("at", at)
    else params.delete("at")
    navigate({ search: params.toString() })
  }
  const selectedTime = historicalAt ? new Date(historicalAt).getTime() : new Date(history.to).getTime()
  const currentTick = history.ticks.reduce((found, tick, index) => (selectedTime >= timeMs(tick) ? index : found), -1)
  const eventMarks = useMemo(() => {
    const deltasByTick = new Map<string, typeof history.deltas>()
    history.deltas.forEach((delta) => deltasByTick.set(delta.at, [...(deltasByTick.get(delta.at) || []), delta]))
    return history.ticks.map((tick, index) => {
      const deltas = deltasByTick.get(tick) || []
      const kind = historyEventKind(deltas.flatMap((delta) => [delta.from_stage, delta.to_stage]))
      return { tick, index, kind, count: deltas.length }
    })
  }, [history.deltas, history.ticks])
  const trace = history.traces.find((candidate) => candidate.job_id === traceJobId)
  const tracedItem =
    history.checkpoint.placements.find((placement) => placement.job_id === traceJobId)?.item ||
    [...history.deltas].reverse().find((delta) => delta.job_id === traceJobId && delta.item)?.item?.item
  const epicTraceJobs = traceEpic
    ? history.traces.filter((candidate) => {
        const placement =
          history.checkpoint.placements.find((row) => row.job_id === candidate.job_id) ||
          [...history.deltas].reverse().find((delta) => delta.job_id === candidate.job_id && delta.item)?.item
        return placement?.item.epic?.id === traceEpic.id
      })
    : []
  useEffect(() => {
    if (!playing) return
    const next = currentTick + 1
    if (next >= history.ticks.length) {
      setPlaying(false)
      return
    }
    const timer = window.setTimeout(() => setAt(history.ticks[next]), reducedMotion() ? 900 : 600)
    return () => window.clearTimeout(timer)
  }, [playing, currentTick, history.ticks])
  function updateEdges() {
    const node = scroller.current
    if (node) {
      const left = node.scrollLeft > 2
      const right = node.scrollLeft + node.clientWidth < node.scrollWidth - 2
      setEdges({ left, right })
    }
  }
  useEffect(updateEdges, [stages.length])
  const reducedMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
  function move(direction: number) {
    scroller.current?.scrollBy({ left: direction * 580, behavior: reducedMotion() ? "auto" : "smooth" })
  }
  function onKeys(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault()
      move(event.key === "ArrowRight" ? 1 : -1)
    }
  }
  const deploymentStages = payload.stages.filter((stage) => stage.kind === "deployment")
  return (
    <>
      {!embedded && (Boolean(trace && tracedItem) || Boolean(traceEpic)) ? (
        <div className="py-2">
          {trace && tracedItem ? (
            <Section.Root className="mt-3 p-3">
              <div className="flex items-center gap-2">
                <Section.Title>{t("trace_heading", { job: tracedItem.slug })}</Section.Title>
                <Button className="ml-auto" onClick={() => setTraceJobId(null)} size="sm" variant="secondary">
                  {t("close")}
                </Button>
              </div>
              {trace.segments.map((segment) => (
                <Text className="mt-2" key={`${segment.stage}-${segment.entered_at}`} variant="caption">
                  {t("trace_segment", {
                    stage: segment.stage,
                    entered: new Date(segment.entered_at).toLocaleString(),
                    left: new Date(segment.left_at).toLocaleString(),
                    dwell: duration(segment.dwell_seconds, t)
                  })}
                </Text>
              ))}
            </Section.Root>
          ) : null}
          {traceEpic ? (
            <Section.Root className="mt-3 p-3">
              <div className="flex items-center gap-2">
                <Section.Title>{t("epic_trace_heading", { epic: traceEpic.slug })}</Section.Title>
                <Button className="ml-auto" onClick={() => setTraceEpic(null)} size="sm" variant="secondary">
                  {t("close")}
                </Button>
              </div>
              {epicTraceJobs.map((jobTrace) => (
                <div className="mt-2" key={jobTrace.job_id}>
                  <Text variant="caption">{t("job_trace_heading", { job: jobTrace.job_id })}</Text>
                  {jobTrace.segments.map((segment) => (
                    <Text className="mt-1" key={`${segment.stage}-${segment.entered_at}`} variant="caption" tone="muted">
                      {t("trace_segment", {
                        stage: segment.stage,
                        entered: new Date(segment.entered_at).toLocaleString(),
                        left: new Date(segment.left_at).toLocaleString(),
                        dwell: duration(segment.dwell_seconds, t)
                      })}
                    </Text>
                  ))}
                </div>
              ))}
            </Section.Root>
          ) : null}
        </div>
      ) : null}
      <HistoryStatusNotice onRetry={onRetryHistory} status={historyStatus} />
      <div
        className={`relative flex min-h-0 border-y border-border bg-surface-subtle ${embedded ? "flex-1" : "h-[calc(100dvh-14rem)] min-h-[32rem]"}`}
        data-testid="pipeline-with-time-rail"
      >
        <div className="relative flex min-w-0 flex-1 flex-col overflow-hidden py-3">
          {edges.left ? (
            <div aria-hidden className="pointer-events-none absolute inset-y-0 left-0 z-10 w-12 bg-gradient-to-r from-surface-subtle to-transparent" />
          ) : null}
          {edges.right ? (
            <div aria-hidden className="pointer-events-none absolute inset-y-0 right-0 z-10 w-12 bg-gradient-to-l from-surface-subtle to-transparent" />
          ) : null}
          <Button
            aria-label={t("scroll_left")}
            className="absolute left-2 top-1/2 z-20 -translate-y-1/2"
            disabled={!edges.left}
            onClick={() => move(-1)}
            size="icon"
            variant="secondary"
          >
            ‹
          </Button>
          <Button
            aria-label={t("scroll_right")}
            className="absolute right-2 top-1/2 z-20 -translate-y-1/2"
            disabled={!edges.right}
            onClick={() => move(1)}
            size="icon"
            variant="secondary"
          >
            ›
          </Button>
          <div
            aria-label={t("stages_aria")}
            className={STAGE_SCROLLER_CLASSES}
            onKeyDown={onKeys}
            onScroll={updateEdges}
            ref={scroller}
            role="region"
            tabIndex={0}
          >
            {stages.map((stage) => (
              <div className="h-full snap-start" key={stage.key}>
                <StageColumn
                  groups={displayedPayload.groups}
                  onOpen={() => setSelected(stage)}
                  onEpicTrace={historical ? (group) => setTraceEpic(group.epic || null) : undefined}
                  onTrace={historical ? (item) => setTraceJobId(item.id) : undefined}
                  releaseTail={Boolean(stage.release_tail)}
                  fill
                  stage={stage}
                />
              </div>
            ))}
            {!stages.length ? <Notice>{t("filter_empty")}</Notice> : null}
          </div>
        </div>
        <HistoryRail
          currentTick={currentTick}
          eventMarks={eventMarks}
          historical={historical}
          historicalAt={historicalAt}
          history={history}
          incompleteEvidenceCount={payload.evidence.status === "partial" ? payload.evidence.incomplete_count : 0}
          onRangeChange={(days) => {
            const params = new URLSearchParams(search)
            const end = new Date(history.to)
            params.set("range_end", end.toISOString())
            params.set("range_start", new Date(end.getTime() - days * 86_400_000).toISOString())
            navigate({ search: params.toString() })
          }}
          onSelect={setAt}
          playing={playing}
          setPlaying={setPlaying}
        />
      </div>
      {!embedded ? <div className="space-y-2 py-3">{!deploymentStages.length ? <Notice tone="warning">{t("no_deployment_config")}</Notice> : null}</div> : null}
      {selected && !historical ? <DrillDown onClose={() => setSelected(null)} repositoryId={repositoryId} search={search} stage={selected} /> : null}
    </>
  )
}

export function RepositoryPipelineRoute({ repositoryId, prefix }: { repositoryId: string; prefix: string }) {
  const { t } = useT("sdlc_pipeline")
  const location = useLocation()
  const embedded = new URLSearchParams(location.search).get("syrus_presentation") === "embedded"
  const requestSearch = useMemo(() => {
    const params = new URLSearchParams(location.search)
    params.delete("at")
    params.delete("syrus_presentation")
    const value = params.toString()
    return value ? `?${value}` : ""
  }, [location.search])
  const queryKey = ["repositories", repositoryId, "sdlc_pipeline", requestSearch]
  const staticPayloads = useRef(new Map<string, PipelinePayload>())
  const withHistory = (value: string, enabled: boolean) => {
    const params = new URLSearchParams(value)
    params.set("history", enabled ? "1" : "0")
    return `?${params.toString()}`
  }
  const pipeline = useQuery({
    queryKey,
    queryFn: async () => {
      const cached = staticPayloads.current.get(requestSearch)
      const search = withHistory(requestSearch, false)
      const payload = await fetchPipeline(repositoryId, cached ? `${search}&section=poll` : search)
      const merged = cached ? { ...cached, ...payload } : payload
      staticPayloads.current.set(requestSearch, merged)
      return merged
    },
    enabled: repositoryId.length > 0,
    placeholderData: (previous) => previous,
    staleTime: 0,
    refetchInterval: POLL_INTERVAL_MS
  })
  const history = useQuery({
    queryKey: [...queryKey, "history"],
    queryFn: () => fetchPipeline(repositoryId, `${withHistory(requestSearch, true)}&section=history-only`),
    enabled: repositoryId.length > 0,
    placeholderData: (previous) => previous,
    staleTime: POLL_INTERVAL_MS,
    // History is secondary and has an explicit Retry action, so surface a failure quickly
    // instead of leaving the rail in "loading" through the default multi-second backoff.
    retry: false
  })
  const historyStatus: HistoryStatus = history.isError
    ? "error"
    : history.isPending || history.isFetching
      ? "loading"
      : (history.data?.history?.ticks.length ?? 0) === 0
        ? history.data?.history?.accuracy.status === "incomplete"
          ? "incomplete"
          : "empty"
        : "ready"
  const retryHistory = () => void history.refetch()
  const buildLink = (pathname: string, search: string, updates: Record<string, string | number | null | undefined>) => {
    const params = new URLSearchParams(search)
    Object.entries(updates).forEach(([key, value]) => (value == null ? params.delete(key) : params.set(key, String(value))))
    const query = params.toString()
    return query ? `${pathname}?${query}` : pathname
  }
  const loading = pipeline.isPending ? (
    <div className="p-3">
      <Notice>{t("loading")}</Notice>
      <div aria-hidden className="mt-4 h-96 animate-pulse rounded bg-surface-subtle motion-reduce:animate-none" />
    </div>
  ) : null
  const error = pipeline.isError ? (
    <div className="p-3">
      <Notice tone="danger">{errorMessage(pipeline.error, t("load_error"))}</Notice>
      <Button className="mt-3" onClick={() => void pipeline.refetch()} size="sm" variant="secondary">
        {t("retry")}
      </Button>
    </div>
  ) : null
  const presentationParams = new URLSearchParams(location.search)
  presentationParams.set("syrus_presentation", "embedded")
  const presentationHref = `${location.pathname}?${presentationParams.toString()}`
  if (embedded) {
    return (
      <main aria-label={t("aria_pipeline")} className="flex h-[100dvh] min-h-full flex-col overflow-hidden bg-surface" data-testid="embedded-pipeline-view">
        {loading}
        {error}
        {pipeline.data ? (
          <>
            <div className="shrink-0 border-b border-border bg-surface px-3 py-2 sm:px-4">
              <FilterBar
                buildLink={buildLink}
                filter={pipeline.data.filter}
                filterSchema={pipeline.data.filter_schema ?? []}
                pathname={location.pathname}
                search={location.search}
                suggestionSearch={{ surface: "sdlc_pipeline", subject: "sdlc_pipeline" }}
              />
            </div>
            <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
              <PipelineOverview
                embedded
                historyStatus={historyStatus}
                onRetryHistory={retryHistory}
                payload={{ ...pipeline.data, history: history.data?.history }}
                repositoryId={repositoryId}
                search={location.search}
              />
            </div>
          </>
        ) : null}
      </main>
    )
  }
  return (
    <RepositoryPageShell
      activeTab="sdlc_pipeline.repository"
      ariaLabel={t("aria_pipeline")}
      heading={pipeline.data ? <PageHeading mono>{pipeline.data.repository.slug}</PageHeading> : null}
      prefix={prefix}
    >
      {loading}
      {error}
      {pipeline.data ? (
        <div className="min-w-0">
          <div className="flex items-center gap-2 border-b border-border py-2" data-testid="pipeline-filter-row">
            <div className="min-w-0 flex-1">
              <FilterBar
                buildLink={buildLink}
                filter={pipeline.data.filter}
                filterSchema={pipeline.data.filter_schema ?? []}
                pathname={location.pathname}
                search={location.search}
                suggestionSearch={{ surface: "sdlc_pipeline", subject: "sdlc_pipeline" }}
              />
            </div>
            <a aria-label={t("open_presentation")} className={PRESENTATION_LINK_CLASSES} href={presentationHref} rel="noopener noreferrer" target="_blank">
              <span aria-hidden>↗</span>
              <span className="sr-only sm:not-sr-only sm:ml-1">{t("open_presentation")}</span>
            </a>
          </div>
          <PipelineOverview
            historyStatus={historyStatus}
            onRetryHistory={retryHistory}
            payload={{ ...pipeline.data, history: history.data?.history }}
            repositoryId={repositoryId}
            search={location.search}
          />
        </div>
      ) : null}
    </RepositoryPageShell>
  )
}

function timeMs(value: string) {
  return new Date(value).getTime()
}

export default function RepositoryPipelineTab() {
  const params = useParams<{ repositoryId: string }>()
  const location = useLocation()
  return <RepositoryPipelineRoute repositoryId={params.repositoryId || ""} prefix={routePrefix(location.pathname)} />
}
