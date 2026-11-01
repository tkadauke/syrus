import { useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { Button, Input, Metric, Modal, Notice, PageHeading, Section, Text } from "@app/components/ui"
import { CloseIcon } from "@app/components/CloseIcon"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { TonePill } from "@app/components/StatusPill"
import { useT } from "@app/hooks/useT"
import { routePrefix } from "@app/lib/routing"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchPipeline, fetchPipelineStage, type PipelineGroup, type PipelineItem, type PipelinePayload, type PipelineStage } from "../api/pipeline"

const POLL_INTERVAL_MS = 30_000
const ITEM_CARD_CLASSES =
  "block rounded-[var(--radius-control)] border border-border bg-surface p-2.5 shadow-sm transition-colors hover:border-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
const STAGE_HEADER_CLASSES =
  "w-full border-b border-border bg-surface/95 p-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-brand"
const SHOW_ALL_CLASSES =
  "mt-auto rounded p-1.5 text-left text-[length:var(--text-caption)] font-medium text-brand hover:bg-surface-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
type Translate = (key: string, options?: Record<string, unknown>) => string

function duration(seconds: number | null, t: Translate) {
  if (seconds == null) return t("not_available")
  if (seconds < 3600) return t("minutes", { count: Math.max(1, Math.floor(seconds / 60)) })
  if (seconds < 86_400) return t("hours", { count: Math.floor(seconds / 3600) })
  return t("days", { count: Math.floor(seconds / 86_400) })
}

function ItemCard({ item, releaseTail = false }: { item: PipelineItem; releaseTail?: boolean }) {
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

function Aggregate({ group, stage }: { group: PipelineGroup; stage: PipelineStage }) {
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
  return group.epic ? <Link to={`/epics/${group.epic.slug}`}>{body}</Link> : body
}

function StageColumn({ groups, onOpen, releaseTail, stage }: { groups: PipelineGroup[]; onOpen: () => void; releaseTail: boolean; stage: PipelineStage }) {
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
          <ItemCard item={item} key={item.id} releaseTail={releaseTail} />
        ))}
        {stageGroups.slice(0, 4).map((group) => (
          <Aggregate group={group} key={group.key} stage={stage} />
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

function DrillDown({ onClose, repositoryId, stage }: { onClose: () => void; repositoryId: string; stage: PipelineStage }) {
  const { t } = useT("sdlc_pipeline")
  const [page, setPage] = useState(1)
  const result = useQuery({
    queryKey: ["repositories", repositoryId, "sdlc_pipeline", stage.key, page],
    queryFn: () => fetchPipelineStage(repositoryId, stage.key, page),
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

function PipelineOverview({ payload, repositoryId }: { payload: PipelinePayload; repositoryId: string }) {
  const { t } = useT("sdlc_pipeline")
  const scroller = useRef<HTMLDivElement>(null)
  const [selected, setSelected] = useState<PipelineStage | null>(null)
  const [query, setQuery] = useState("")
  const [edges, setEdges] = useState({ left: false, right: false })
  const stages = useMemo(
    () =>
      payload.stages.map((stage) => {
        if (!query) return stage
        const normalized = query.toLowerCase()
        const stageMatches = stage.label.toLowerCase().includes(normalized)
        const highlighted_items = stageMatches
          ? stage.highlighted_items
          : stage.highlighted_items.filter((item) => `${item.slug} ${item.title}`.toLowerCase().includes(normalized))
        return { ...stage, highlighted_items }
      }),
    [payload.stages, query]
  )
  const active = payload.stages.find((stage) => stage.total > 0 && stage.kind === "lifecycle")
  const total = payload.stages.reduce((sum, stage) => sum + stage.total, 0)
  const attention = payload.stages.reduce((sum, stage) => sum + stage.attention_count, 0)
  const landed = payload.stages.find((stage) => stage.key === "landed")?.total || 0
  const oldest = Math.max(0, ...payload.stages.map((stage) => stage.oldest_age_seconds || 0))
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
        <div className="flex flex-col gap-3 xl:flex-row xl:items-start">
          <div>
            <Section.Title>{t("title")}</Section.Title>
            <Text className="mt-1" tone="muted">
              {t("subtitle", { time: new Date(payload.generated_at).toLocaleTimeString() })}
            </Text>
          </div>
          <Metric.Group className="xl:ml-auto xl:w-[38rem]" columns={4}>
            <Metric.Card label={t("in_pipeline")} value={total} />
            <Metric.Card label={t("need_attention")} tone={attention ? "danger" : "neutral"} value={attention} />
            <Metric.Card label={t("landed_gap")} tone={landed ? "warning" : "neutral"} value={landed} />
            <Metric.Card label={t("oldest_active")} value={duration(oldest, t)} />
          </Metric.Group>
        </div>
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
        {!deploymentStages.length ? (
          <Notice className="mt-3" tone="warning">
            {t("no_deployment_config")}
          </Notice>
        ) : null}
        {payload.evidence.status === "partial" ? (
          <Notice className="mt-3" tone="warning">
            {t("partial_evidence", { count: payload.evidence.incomplete_count })}
          </Notice>
        ) : null}
      </div>
      <div className="relative overflow-hidden border-y border-border bg-surface-subtle py-3">
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
              <StageColumn groups={payload.groups} onOpen={() => setSelected(stage)} releaseTail={Boolean(stage.release_tail)} stage={stage} />
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
      {selected ? <DrillDown onClose={() => setSelected(null)} repositoryId={repositoryId} stage={selected} /> : null}
    </>
  )
}

export function RepositoryPipelineRoute({ repositoryId, prefix }: { repositoryId: string; prefix: string }) {
  const { t } = useT("sdlc_pipeline")
  const pipeline = useQuery({
    queryKey: ["repositories", repositoryId, "sdlc_pipeline"],
    queryFn: () => fetchPipeline(repositoryId),
    enabled: repositoryId.length > 0,
    refetchInterval: POLL_INTERVAL_MS
  })
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
      {pipeline.data ? <PipelineOverview payload={pipeline.data} repositoryId={repositoryId} /> : null}
    </RepositoryPageShell>
  )
}

export default function RepositoryPipelineTab() {
  const params = useParams<{ repositoryId: string }>()
  const location = useLocation()
  return <RepositoryPipelineRoute repositoryId={params.repositoryId || ""} prefix={routePrefix(location.pathname)} />
}
