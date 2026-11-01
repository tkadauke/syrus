import { useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { Button, Input, Modal, Notice, PageHeading, Section, Select, Text } from "@app/components/ui"
import { CloseIcon } from "@app/components/CloseIcon"
import { AdminFiltersLayout } from "@app/components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "@app/components/AdminSmartFolderNav"
import { SmartFolderFilterBar } from "@app/components/SmartFolderFilterBar"
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

const POLL_INTERVAL_MS = 30_000
const ITEM_CARD_CLASSES =
  "block rounded-[var(--radius-control)] border border-border bg-surface p-2.5 shadow-sm transition-colors hover:border-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const STAGE_HEADER_CLASSES =
  "w-full border-b border-border bg-surface/95 p-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand"
const SHOW_ALL_CLASSES =
  "mt-auto rounded p-1.5 text-left text-[length:var(--text-caption)] font-medium text-brand hover:bg-surface-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const TIME_RAIL_CLASSES =
  "relative z-20 flex h-[33.75rem] w-[6.5rem] shrink-0 flex-col items-center border-r border-border bg-surface px-1.5 py-2 sm:w-[7.5rem] sm:px-2"
const RAIL_BUTTON_CLASSES =
  "rounded px-1 text-sm font-semibold text-brand hover:bg-surface-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const VERTICAL_SCRUBBER_CLASSES =
  "absolute left-1/2 top-1/2 z-10 h-[92%] w-6 -translate-x-1/2 -translate-y-1/2 cursor-pointer opacity-0 focus-visible:opacity-100"
const EVENT_MARK_CLASSES =
  "absolute left-1/2 z-20 flex h-3 w-5 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-sm text-[8px] font-bold focus-visible:h-5 focus-visible:w-8 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const RAIL_OPTIONS_CLASSES =
  "cursor-pointer list-none rounded border border-border px-1.5 py-1 text-center text-text-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const RAIL_POPOVER_CLASSES =
  "fixed inset-x-2 bottom-2 z-40 rounded border border-border bg-surface p-3 text-left shadow-lg sm:absolute sm:inset-x-auto sm:bottom-8 sm:left-0 sm:w-72"
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
  stage
}: {
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
      className={`flex h-[31rem] w-[17rem] shrink-0 flex-col overflow-hidden p-0 ${stage.kind === "deployment" ? "bg-surface-subtle" : ""}`}
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

function HistoryRail({
  changes,
  currentTick,
  historical,
  historicalAt,
  history,
  onRangeChange,
  onSelect,
  playing,
  setPlaying
}: {
  changes: PipelineHistory["deltas"]
  currentTick: number
  historical: boolean
  historicalAt: string | null
  history: PipelineHistory
  onRangeChange: (days: number) => void
  onSelect: (at: string | null) => void
  playing: boolean
  setPlaying: (value: boolean | ((current: boolean) => boolean)) => void
}) {
  const { t } = useT("sdlc_pipeline")
  const selectedIndex = historical ? Math.max(0, currentTick) : history.ticks.length
  const markerSteps = Math.max(1, history.ticks.length - 1)
  return (
    <Section.Root
      aria-label={t("history_aria")}
      className="flex w-[4.75rem] shrink-0 flex-col items-center gap-2 overflow-hidden p-2 sm:w-44 sm:items-stretch sm:p-3"
    >
      <div className="hidden sm:block">
        <Section.Title>{t("history_short")}</Section.Title>
        <Text className="mt-1" variant="caption" tone="muted">
          {historical && historicalAt ? new Date(historicalAt).toLocaleString() : t("live_mode")}
        </Text>
      </div>
      <div className="flex w-full items-center justify-center gap-1 sm:justify-start">
        <Button
          aria-label={playing ? t("pause_history") : t("play_history")}
          disabled={!history.ticks.length}
          onClick={() => {
            if (!historical) onSelect(history.ticks[0])
            setPlaying((value) => !value)
          }}
          size="icon"
          title={playing ? t("pause_history") : t("play_history")}
          variant="secondary"
        >
          {playing ? "Ⅱ" : "▶"}
        </Button>
        <Button aria-label={t("return_now")} disabled={!historical} onClick={() => onSelect(null)} size="icon" title={t("return_now")} variant="secondary">
          ●
        </Button>
      </div>
      <div className="relative min-h-52 w-full flex-1" data-testid="pipeline-time-rail">
        <Input
          aria-label={t("time_scrubber")}
          className={TIME_SCRUBBER_CLASSES}
          max={history.ticks.length}
          min={0}
          onChange={(event) => onSelect(event.target.value === String(history.ticks.length) ? null : history.ticks[Number(event.target.value)] || history.from)}
          type="range"
          value={selectedIndex}
        />
        {history.ticks.map((tick, index) => {
          const active = historical && index === currentTick
          return (
            <button
              aria-label={t("event_marker", { time: new Date(tick).toLocaleString() })}
              aria-pressed={active}
              className={`${EVENT_MARKER_CLASSES} ${active ? "border-brand text-brand" : "border-border text-text-muted"}`}
              key={tick}
              onClick={() => onSelect(tick)}
              style={{ top: `calc(${history.ticks.length === 1 ? 50 : 8 + ((history.ticks.length - index - 1) / markerSteps) * 84}% - 1.375rem)` }}
              title={new Date(tick).toLocaleString()}
              type="button"
            >
              <span aria-hidden className={`h-2.5 w-2.5 rotate-45 border ${active ? "border-brand bg-brand" : "border-current bg-surface"}`} />
            </button>
          )
        })}
      </div>
      <div className="hidden sm:block">
        <label className="text-2xs text-text-muted">
          {t("history_window")}
          <Select
            className="mt-1 px-2 py-1"
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
        {historical ? (
          <Text className="mt-2" variant="caption" tone="muted">
            {changes.length ? t("changes_count", { count: changes.length }) : t("no_changes")}
          </Text>
        ) : null}
      </div>
    </Section.Root>
  )
}

function PipelineOverview({ payload, repositoryId, search }: { payload: PipelinePayload; repositoryId: string; search: string }) {
  const { t } = useT("sdlc_pipeline")
  const scroller = useRef<HTMLDivElement>(null)
  const [selected, setSelected] = useState<PipelineStage | null>(null)
  const [query, setQuery] = useState("")
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
              tracesByJob.get(item.id)?.segments.find((segment) => new Date(segment.entered_at).getTime() <= at && new Date(segment.left_at).getTime() >= at)
                ?.entered_at || historicalAt!
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
  const stages = useMemo(
    () =>
      displayedPayload.stages.map((stage) => {
        if (!query) return stage
        const normalized = query.toLowerCase()
        const stageMatches = stage.label.toLowerCase().includes(normalized)
        const highlighted_items = stageMatches
          ? stage.highlighted_items
          : stage.highlighted_items.filter((item) => `${item.slug} ${item.title}`.toLowerCase().includes(normalized))
        return { ...stage, highlighted_items }
      }),
    [displayedPayload.stages, query]
  )
  const active = displayedPayload.stages.find((stage) => stage.total > 0 && stage.kind === "lifecycle")
  const total = displayedPayload.stages.reduce((sum, stage) => sum + stage.total, 0)
  const attention = displayedPayload.stages.reduce((sum, stage) => sum + stage.attention_count, 0)
  const landed = displayedPayload.stages.find((stage) => stage.key === "landed")?.total || 0
  const oldest = Math.max(0, ...displayedPayload.stages.map((stage) => stage.oldest_age_seconds || 0))
  const navigate = useNavigate()
  function setAt(at: string | null) {
    const params = new URLSearchParams(search)
    if (at) params.set("at", at)
    else params.delete("at")
    navigate({ search: params.toString() })
  }
  const selectedTime = historicalAt ? new Date(historicalAt).getTime() : new Date(history.to).getTime()
  const currentTick = history.ticks.reduce((found, tick, index) => (new Date(tick).getTime() <= selectedTime ? index : found), -1)
  const previousTick = currentTick > 0 ? history.ticks[currentTick - 1] : history.from
  const changes = historical
    ? history.deltas.filter((delta) => new Date(delta.at).getTime() > new Date(previousTick).getTime() && new Date(delta.at).getTime() <= selectedTime)
    : []
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
    if (node) setEdges({ left: node.scrollLeft > 2, right: node.scrollLeft + node.clientWidth < node.scrollWidth - 2 })
  }
  useEffect(updateEdges, [stages.length])
  const reducedMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
  function move(direction: number) {
    scroller.current?.scrollBy({ left: direction * 580, behavior: reducedMotion() ? "auto" : "smooth" })
  }
  function focusStage(stage: PipelineStage) {
    scroller.current
      ?.querySelector<HTMLElement>(`[data-stage="${CSS.escape(stage.key)}"]`)
      ?.scrollIntoView({ inline: "center", block: "nearest", behavior: reducedMotion() ? "auto" : "smooth" })
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
      <div className="py-4">
        <div className="flex flex-wrap items-end gap-x-4 gap-y-2">
          <div>
            <Section.Title>{t("title")}</Section.Title>
            <Text className="mt-1" tone="muted">
              {t("subtitle", { time: new Date(historicalAt || payload.generated_at).toLocaleString() })}
            </Text>
          </div>
          <div className="flex min-w-0 flex-1 gap-3 overflow-x-auto text-2xs text-text-muted sm:justify-end" aria-label={t("pipeline_summary")}>
            <span className="whitespace-nowrap">
              <strong className="text-text-primary">{total}</strong> {t("in_pipeline")}
            </span>
            <span className={`whitespace-nowrap ${attention && !historical ? "text-danger-text" : ""}`}>
              <strong>{historical ? t("not_available") : attention}</strong> {t("need_attention")}
            </span>
            <span className="whitespace-nowrap">
              <strong className={landed ? "text-warning-text" : "text-text-primary"}>{landed}</strong> {t("landed_gap")}
            </span>
            <span className="whitespace-nowrap">
              <strong className="text-text-primary">{duration(oldest, t)}</strong> {t("oldest_active")}
            </span>
          </div>
        </div>
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
        <div className="mt-4 flex flex-wrap items-center gap-2">
          <Input
            aria-label={t("filter_aria")}
            className="max-w-xs"
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("filter_placeholder")}
            value={query}
          />
          {active ? (
            <Button onClick={() => focusStage(active)} size="sm" variant="secondary">
              {t("center_active")}
            </Button>
          ) : null}
          <Text className="ml-auto" variant="caption" tone="muted">
            {t("represented", { count: total })}
          </Text>
        </div>
      </div>
      <div className="relative flex border-y border-border bg-surface-subtle" data-testid="pipeline-with-time-rail">
        <aside aria-label={t("history_aria")} className={TIME_RAIL_CLASSES} data-testid="pipeline-time-rail">
          <div className="flex w-full flex-col items-center gap-1 sm:flex-row sm:justify-between">
            <TonePill tone={historical ? "amber" : "gray"}>{historical ? t("historical_mode_short") : t("live_mode")}</TonePill>
            {historical ? (
              <button aria-label={t("return_now")} className={RAIL_BUTTON_CLASSES} onClick={() => setAt(null)} title={t("return_now")} type="button">
                ↥
              </button>
            ) : null}
          </div>
          <Text className="mt-1 text-center text-2xs leading-tight" variant="caption" tone="muted">
            {historical ? (
              <time data-testid="selected-history-time" dateTime={historicalAt!}>
                {new Date(historicalAt!).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
              </time>
            ) : (
              t("now")
            )}
          </Text>
          <div className="relative my-2 min-h-0 w-full flex-1" data-testid="history-event-track">
            <div aria-hidden className="absolute bottom-2 left-1/2 top-2 w-px -translate-x-1/2 bg-border" />
            <Input
              aria-label={t("time_scrubber")}
              className={VERTICAL_SCRUBBER_CLASSES}
              max={history.ticks.length}
              min={0}
              onChange={(event) =>
                setAt(event.target.value === String(history.ticks.length) ? null : history.ticks[Number(event.target.value)] || history.from)
              }
              style={{ writingMode: "vertical-lr", direction: "rtl" }}
              type="range"
              value={historical ? Math.max(0, currentTick) : history.ticks.length}
            />
            {eventMarks.map((mark) => {
              const selected = historical && mark.index === currentTick
              const label = t("event_mark", {
                time: new Date(mark.tick).toLocaleString(),
                type: t(`event_type_${mark.kind}`),
                count: mark.count
              })
              return (
                <button
                  aria-label={label}
                  className={`${EVENT_MARK_CLASSES} ${
                    selected
                      ? "bg-brand text-on-brand ring-2 ring-offset-1 ring-offset-surface"
                      : mark.kind === "attention"
                        ? "bg-danger text-on-danger"
                        : mark.kind === "deployment"
                          ? "bg-info text-on-info"
                          : "border border-border-strong bg-surface-raised text-text-muted"
                  }`}
                  key={mark.tick}
                  onClick={() => setAt(mark.tick)}
                  style={{ top: `${96 - (mark.index / Math.max(1, history.ticks.length)) * 92}%` }}
                  title={label}
                  type="button"
                >
                  {mark.kind === "attention" ? "!" : mark.kind === "deployment" ? "◆" : "•"}
                </button>
              )
            })}
            <span aria-hidden className="absolute bottom-0 left-1/2 -translate-x-1/2 text-2xs text-text-subtle">
              −
            </span>
            <span aria-hidden className="absolute left-1/2 top-0 -translate-x-1/2 text-2xs text-text-subtle">
              +
            </span>
          </div>
          <div className="grid grid-cols-3 gap-1">
            <Button
              aria-label={playing ? t("pause_history") : t("play_history")}
              disabled={!history.ticks.length}
              onClick={() => {
                if (!historical) setAt(history.ticks[0])
                setPlaying((value) => !value)
              }}
              className="h-7 w-7"
              size="icon"
              title={playing ? t("pause_history") : t("play_history")}
              variant="secondary"
            >
              {playing ? "Ⅱ" : "▶"}
            </Button>
            <Button
              aria-label={t("previous_tick")}
              disabled={currentTick <= 0}
              className="h-7 w-7"
              onClick={() => setAt(history.ticks[currentTick - 1])}
              size="icon"
              title={t("previous_tick")}
              variant="secondary"
            >
              ↑
            </Button>
            <Button
              aria-label={t("next_tick")}
              disabled={!historical || currentTick >= history.ticks.length - 1}
              className="h-7 w-7"
              onClick={() => setAt(history.ticks[currentTick + 1])}
              size="icon"
              title={t("next_tick")}
              variant="secondary"
            >
              ↓
            </Button>
          </div>
          <details className="group relative mt-2 w-full text-2xs">
            <summary className={RAIL_OPTIONS_CLASSES}>{t("history_options")}</summary>
            <div className={RAIL_POPOVER_CLASSES}>
              <label className="text-2xs text-text-muted">
                {t("history_window")}
                <Select
                  className="mt-1 px-2 py-1"
                  onChange={(event) => {
                    const days = Number(event.target.value)
                    const params = new URLSearchParams(search)
                    const end = new Date(history.to)
                    params.set("range_end", end.toISOString())
                    params.set("range_start", new Date(end.getTime() - days * 86_400_000).toISOString())
                    navigate({ search: params.toString() })
                  }}
                  value={Math.max(1, Math.round((new Date(history.to).getTime() - new Date(history.from).getTime()) / 86_400_000))}
                >
                  <option value="1">{t("one_day")}</option>
                  <option value="7">{t("seven_days")}</option>
                  <option value="30">{t("thirty_days")}</option>
                  <option value="90">{t("ninety_days")}</option>
                </Select>
              </label>
              <Text className="mt-2" variant="caption" tone="muted">
                {t("history_range", { from: new Date(history.from).toLocaleDateString(), to: new Date(history.to).toLocaleDateString() })}
              </Text>
              {historical ? (
                <Text className="mt-2" variant="caption" tone="muted">
                  {t("historical_banner_compact", { time: new Date(historicalAt!).toLocaleString() })}{" "}
                  {t("current_freshness", { time: new Date(payload.generated_at).toLocaleString() })}
                </Text>
              ) : null}
              {history.accuracy.message ? (
                <Text className="mt-2" variant="caption" tone="muted">
                  {history.accuracy.message}
                </Text>
              ) : null}
              {historical ? (
                <div className="mt-2 border-t border-border pt-2">
                  <Text variant="caption">{changes.length ? t("changes_count", { count: changes.length }) : t("no_changes")}</Text>
                  {changes.slice(0, 5).map((change) => (
                    <Text className="mt-1" key={`${change.job_id}-${change.at}`} variant="caption" tone="muted">
                      {t("change_line", {
                        job: change.item?.item.slug || change.job_id,
                        from: change.from_stage || t("outside_pipeline"),
                        to: change.to_stage || t("outside_pipeline")
                      })}
                    </Text>
                  ))}
                </div>
              ) : null}
            </div>
          </details>
        </aside>
        <div className="relative min-w-0 flex-1 overflow-hidden py-3">
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
            className="flex snap-x gap-3 overflow-x-auto px-3 pb-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
            onKeyDown={onKeys}
            onScroll={updateEdges}
            ref={scroller}
            role="region"
            tabIndex={0}
          >
            {stages.map((stage) => (
              <div className="snap-start" key={stage.key}>
                <StageColumn
                  groups={displayedPayload.groups}
                  onOpen={() => setSelected(stage)}
                  onEpicTrace={historical ? (group) => setTraceEpic(group.epic || null) : undefined}
                  onTrace={historical ? (item) => setTraceJobId(item.id) : undefined}
                  releaseTail={Boolean(stage.release_tail)}
                  stage={stage}
                />
              </div>
            ))}
            {!stages.length ? <Notice>{t("filter_empty")}</Notice> : null}
          </div>
          <div aria-label={t("stage_navigation")} className="mt-2 flex flex-wrap justify-center gap-1" role="navigation">
            {payload.stages.map((stage) => (
              <button
                aria-label={t("go_to_stage", { stage: stage.label })}
                className={`h-2 min-w-6 rounded-full ${stage.attention_count ? "bg-warning" : "bg-border"} focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand`}
                key={stage.key}
                onClick={() => focusStage(stage)}
                title={stage.label}
                type="button"
              />
            ))}
          </div>
        </div>
        <HistoryRail
          changes={changes}
          currentTick={currentTick}
          historical={historical}
          historicalAt={historicalAt}
          history={history}
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
      <div className="space-y-2 py-3">
        {!deploymentStages.length ? <Notice tone="warning">{t("no_deployment_config")}</Notice> : null}
        {payload.evidence.status === "partial" ? <Notice tone="warning">{t("partial_evidence", { count: payload.evidence.incomplete_count })}</Notice> : null}
      </div>
      {selected && !historical ? <DrillDown onClose={() => setSelected(null)} repositoryId={repositoryId} search={search} stage={selected} /> : null}
    </>
  )
}

export function RepositoryPipelineRoute({ repositoryId, prefix }: { repositoryId: string; prefix: string }) {
  const { t } = useT("sdlc_pipeline")
  const location = useLocation()
  const requestSearch = useMemo(() => {
    const params = new URLSearchParams(location.search)
    params.delete("at")
    const value = params.toString()
    return value ? `?${value}` : ""
  }, [location.search])
  const queryKey = ["repositories", repositoryId, "sdlc_pipeline", requestSearch]
  const withHistory = (value: string, enabled: boolean) => {
    const params = new URLSearchParams(value)
    params.set("history", enabled ? "1" : "0")
    return `?${params.toString()}`
  }
  const pipeline = useQuery({
    queryKey,
    queryFn: () => fetchPipeline(repositoryId, withHistory(requestSearch, false)),
    enabled: repositoryId.length > 0,
    placeholderData: (previous) => previous,
    refetchInterval: POLL_INTERVAL_MS
  })
  const history = useQuery({
    queryKey: [...queryKey, "history"],
    queryFn: () => fetchPipeline(repositoryId, withHistory(requestSearch, true)),
    enabled: repositoryId.length > 0,
    placeholderData: (previous) => previous,
    staleTime: POLL_INTERVAL_MS
  })
  const folders = useMemo(() => {
    const presentation = new URLSearchParams(location.search)
    const keys = ["at", "range_start", "range_end"]
    return (pipeline.data?.smart_folders ?? []).map((folder) => {
      const url = new URL(folder.path, window.location.origin)
      keys.forEach((key) => {
        const value = presentation.get(key)
        if (value) url.searchParams.set(key, value)
      })
      return { ...folder, path: `${url.pathname}?${url.searchParams.toString()}` }
    })
  }, [pipeline.data?.smart_folders, location.search])
  return (
    <RepositoryPageShell
      activeTab="sdlc_pipeline.repository"
      ariaLabel={t("aria_pipeline")}
      heading={pipeline.data ? <PageHeading mono>{pipeline.data.repository.slug}</PageHeading> : null}
      prefix={prefix}
      tabs={pipeline.data?.tabs ?? []}
    >
      {pipeline.isPending ? (
        <div className="py-5">
          <Notice>{t("loading")}</Notice>
          <div aria-hidden className="mt-4 h-96 animate-pulse rounded bg-surface-subtle motion-reduce:animate-none" />
        </div>
      ) : null}
      {pipeline.isError ? (
        <div className="py-5">
          <Notice tone="danger">{errorMessage(pipeline.error, t("load_error"))}</Notice>
          <Button className="mt-3" onClick={() => void pipeline.refetch()} size="sm" variant="secondary">
            {t("retry")}
          </Button>
        </div>
      ) : null}
      {pipeline.data ? (
        <AdminFiltersLayout
          filterBar={
            <SmartFolderFilterBar
              activeSmartFolderId={pipeline.data.active_smart_folder_id}
              buildLink={(pathname, search, updates) => {
                const params = new URLSearchParams(search)
                Object.entries(updates).forEach(([key, value]) => (value == null ? params.delete(key) : params.set(key, String(value))))
                const query = params.toString()
                return query ? `${pathname}?${query}` : pathname
              }}
              filter={pipeline.data.filter}
              filterSchema={pipeline.data.filter_schema ?? []}
              pathname={location.pathname}
              search={location.search}
              smartFolders={folders}
              suggestionSearch={{ surface: "sdlc_pipeline", subject: "sdlc_pipeline" }}
            />
          }
          mobileSummaryLabel={folders.find((folder) => folder.active)?.name}
          smartFolders={
            <AdminSmartFolderNav
              activeFolderId={pipeline.data.active_smart_folder_id}
              allowSaveWithoutActiveFolder
              ariaLabel={t("folders_aria")}
              currentFilter={pipeline.data.filter}
              folders={folders}
              heading={t("folders_heading")}
              onMutationSuccess={() => void pipeline.refetch()}
              prefix={prefix}
              queryKey={queryKey}
              rewriteRedirectTo={(path) => {
                const query = path.split("?", 2)[1]
                return query ? `${location.pathname}?${query}` : location.pathname
              }}
              subjectType="sdlc_pipeline"
            />
          }
        >
          <PipelineOverview payload={{ ...pipeline.data, history: history.data?.history }} repositoryId={repositoryId} search={location.search} />
        </AdminFiltersLayout>
      ) : null}
    </RepositoryPageShell>
  )
}

export default function RepositoryPipelineTab() {
  const params = useParams<{ repositoryId: string }>()
  const location = useLocation()
  return <RepositoryPipelineRoute repositoryId={params.repositoryId || ""} prefix={routePrefix(location.pathname)} />
}
