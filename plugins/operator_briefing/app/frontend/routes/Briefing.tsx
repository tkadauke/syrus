import { Button, Modal, Notice, Page, PageHeading, Section, SectionHeading, Text, Textarea, Toggle, buttonClasses } from "@app/components/ui"
import { ArtifactBody } from "@app/components/artifacts/TypedArtifactPanel"
import { UnderlineTabs } from "@app/components/Tabs"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom"
import { confirmBriefingSourcePreference, createBriefingFeedback, discussBriefing, fetchBriefing, fetchBriefingTopic, regenerateBriefing, startBriefingDive, updateBriefingSourcePreference, updateBriefingSubscription, type BriefingBlock, type BriefingChartDatum, type BriefingDiveCandidate, type BriefingPayload, type BriefingRecord, type BriefingRepoPayload, type BriefingSourcePreference, type BriefingSubscription } from "../api/briefing"

type SelectionRect = {
  left: number
  top: number
  width: number
  containerWidth: number
}

type BriefingSelection = {
  text: string
  rect: SelectionRect | null
}

export default function BriefingRoute() {
  const { t } = useT("operator_briefing")
  const params = useParams()
  usePageTitle(t("title"))
  if (params.id) return <BriefingTopicRoute topicId={params.id} />

  const briefing = useQuery({ queryKey: ["operator_briefing"], queryFn: fetchBriefing })

  if (briefing.isPending) {
    return <Page.Root gutter="responsive" size="wide"><Notice>{t("common:loading")}</Notice></Page.Root>
  }

  if (briefing.isError) {
    return <Page.Root gutter="responsive" size="wide"><Notice tone="danger">{t("load_error")}</Notice></Page.Root>
  }

  return <BriefingPage payload={briefing.data} />
}

function BriefingTopicRoute({ topicId }: { topicId: string }) {
  const { t } = useT("operator_briefing")
  const topic = useQuery({ queryKey: ["operator_briefing_topic", topicId], queryFn: () => fetchBriefingTopic(topicId) })

  if (topic.isPending) return <Page.Root gutter="responsive" size="wide"><Notice>{t("common:loading")}</Notice></Page.Root>
  if (topic.isError) return <Page.Root gutter="responsive" size="wide"><Notice tone="danger">{t("topic_load_error")}</Notice></Page.Root>

  const latest = topic.data.revisions[0]
  return (
    <Page.Root aria-label={topic.data.title} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{topic.data.repository.slug}</Text>
        <PageHeading>{topic.data.title}</PageHeading>
        <Page.Description>{t("topic_revision_count", { count: topic.data.revisions.length })}</Page.Description>
      </Page.Header>
      {latest ? (
        <Section.Root className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <SectionHeading>{t("topic_latest")}</SectionHeading>
            {latest.generated_at ? <Text as="span" variant="caption" tone="muted"><RelativeTimestamp value={latest.generated_at} /></Text> : null}
          </div>
          <Text className="max-w-4xl whitespace-pre-wrap leading-6">{latest.narrative}</Text>
          {latest.findings.length > 0 ? (
            <ul className="list-disc space-y-1 pl-5 text-sm text-text-primary">
              {latest.findings.map((finding, index) => <li key={`${finding}-${index}`}>{finding}</li>)}
            </ul>
          ) : null}
        </Section.Root>
      ) : <Notice>{t("topic_empty")}</Notice>}
      {topic.data.revisions.length > 1 ? (
        <Section.Root className="space-y-3">
          <SectionHeading>{t("topic_history")}</SectionHeading>
          {topic.data.revisions.slice(1).map((revision) => (
            <div className="rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-2" key={revision.id}>
              <Text className="font-medium">{t("topic_revision", { number: revision.revision_number })}</Text>
              {revision.generated_at ? <Text variant="caption" tone="muted"><RelativeTimestamp value={revision.generated_at} /></Text> : null}
            </div>
          ))}
        </Section.Root>
      ) : null}
    </Page.Root>
  )
}

function BriefingPage({ payload }: { payload: BriefingPayload }) {
  const { t } = useT("operator_briefing")
  const location = useLocation()
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [activeRepositoryId, setActiveRepositoryId] = useState<number | null>(() => payload.repositories[0]?.repository.id ?? null)
  const activeRepo = useMemo(() => {
    if (payload.repositories.length === 0) return null
    return payload.repositories.find((entry) => entry.repository.id === activeRepositoryId) ?? payload.repositories[0]
  }, [activeRepositoryId, payload.repositories])
  const historyPath = withRoutePrefix("/briefing/history", routePrefix(location.pathname))

  if (location.pathname.endsWith("/briefing/history")) {
    return <BriefingHistoryPage payload={payload} />
  }

  return (
    <Page.Root aria-label={t("aria_label")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{t("eyebrow")}</Text>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <PageHeading>{t("title")}</PageHeading>
            <Page.Description>{t("description", { cadence: payload.settings.cadence_expression })}</Page.Description>
          </div>
          <div className="flex flex-wrap gap-2">
            <Link className={buttonClasses("secondary", "sm")} to={historyPath}>{t("history")}</Link>
            <Button onClick={() => setSettingsOpen(true)} size="sm" variant="secondary">{t("settings")}</Button>
          </div>
        </div>
      </Page.Header>

      <SourcePreferences preferences={payload.source_preferences} suggestions={payload.source_preference_suggestions} />

      {payload.repositories.length === 0 ? (
        <Notice>{t("empty_enabled")}</Notice>
      ) : (
        <section className="space-y-4" aria-label={t("repo_tabs_aria")}>
          <UnderlineTabs
            activeKey={activeRepo?.repository.id ?? null}
            ariaLabel={t("repo_tabs_aria")}
            className="flex flex-wrap border-b border-border"
            itemClassName="-mb-px inline-flex items-center gap-1.5 px-4 py-2 text-sm"
            items={payload.repositories.map((entry) => ({
              key: entry.repository.id,
              label: entry.repository.slug
            }))}
            onSelect={setActiveRepositoryId}
          />
          {activeRepo ? <RepositoryBriefing entry={activeRepo} pathname={location.pathname} /> : null}
        </section>
      )}

      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} payload={payload} />
    </Page.Root>
  )
}

function BriefingHistoryPage({ payload }: { payload: BriefingPayload }) {
  const { t } = useT("operator_briefing")
  const location = useLocation()
  const [searchParams] = useSearchParams()
  const prefix = routePrefix(location.pathname)
  const selectedId = Number(searchParams.get("briefing_id") || "")
  const archived = payload.repositories.flatMap((entry) => entry.history.map((briefing) => ({ entry, briefing })))
  const selected = archived.find((item) => item.briefing.id === selectedId) ?? archived[0] ?? null

  return (
    <Page.Root aria-label={t("history_aria_label")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{t("eyebrow")}</Text>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <PageHeading>{t("history")}</PageHeading>
            <Page.Description>{t("history_description")}</Page.Description>
          </div>
          <Link className={buttonClasses("secondary", "sm")} to={withRoutePrefix("/briefing", prefix)}>{t("back_to_briefing")}</Link>
        </div>
      </Page.Header>

      {archived.length === 0 ? (
        <Notice>{t("empty_history")}</Notice>
      ) : (
        <div className="grid gap-5 lg:grid-cols-[minmax(220px,320px),1fr]">
          <Section.Root className="space-y-2">
            {archived.map(({ entry, briefing }) => (
              <Link
                className={`block rounded-[var(--radius-panel)] border px-3 py-2 text-sm ${selected?.briefing.id === briefing.id ? "border-brand bg-surface-raised text-text-primary" : "border-border bg-surface hover:border-brand"}`}
                key={briefing.id}
                to={withRoutePrefix(`/briefing/history?briefing_id=${briefing.id}`, prefix)}
              >
                <span className="block font-medium">{entry.repository.slug}</span>
                <span className="block text-xs text-text-muted">{briefing.window_start && briefing.window_end ? t("window", { start: briefing.window_start.slice(0, 10), end: briefing.window_end.slice(0, 10) }) : t("window_unknown")}</span>
              </Link>
            ))}
          </Section.Root>
          {selected ? (
            <BriefingCard briefing={selected.briefing} pathname={location.pathname} primaryHref={`/briefing/history?briefing_id=${selected.briefing.id}`} showJobLink />
          ) : null}
        </div>
      )}
    </Page.Root>
  )
}

function SettingsModal({ open, onClose, payload }: { open: boolean; onClose: () => void; payload: BriefingPayload }) {
  const { t } = useT("operator_briefing")

  return (
    <Modal className="max-w-2xl" label={t("settings")} onClose={onClose} open={open}>
      <div className="space-y-4">
        <div>
          <SectionHeading>{t("settings")}</SectionHeading>
          <Text className="mt-1" variant="caption" tone="muted">{t("settings_description", { cadence: payload.settings.cadence_expression })}</Text>
        </div>
        {payload.settings.budget_check_enabled && payload.settings.budget_gate.reason ? (
          <Notice tone="warning">{t("budget_gate_unenforced", { reason: payload.settings.budget_gate.reason })}</Notice>
        ) : null}
        <Section.Root className="space-y-3">
          <div className="flex items-center justify-between gap-3">
            <SectionHeading>{t("subscriptions")}</SectionHeading>
            <Text variant="caption" tone="muted">{t("subscribed_count", { count: payload.repositories.length })}</Text>
          </div>
          <SubscriptionGrid subscriptions={payload.subscriptions} />
        </Section.Root>
        <div className="flex justify-end">
          <Button onClick={onClose} size="sm">{t("close_settings")}</Button>
        </div>
      </div>
    </Modal>
  )
}

function SourcePreferences({ preferences, suggestions }: { preferences: BriefingSourcePreference[]; suggestions: BriefingSourcePreference[] }) {
  const { t } = useT("operator_briefing")
  const queryClient = useQueryClient()
  const update = useMutation({
    mutationFn: ({ id, enabled }: { id: number; enabled: boolean }) => updateBriefingSourcePreference(id, enabled),
    onSuccess: (payload) => queryClient.setQueryData(["operator_briefing"], payload)
  })
  const confirm = useMutation({
    mutationFn: (id: number) => confirmBriefingSourcePreference(id),
    onSuccess: (payload) => queryClient.setQueryData(["operator_briefing"], payload)
  })

  if (preferences.length === 0) return null

  return (
    <Section.Root className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <SectionHeading>{t("source_preferences")}</SectionHeading>
        <Text variant="caption" tone="muted">{t("source_preferences_count", { count: preferences.filter((preference) => preference.enabled).length })}</Text>
      </div>
      {suggestions.length > 0 ? (
        <div className="space-y-2">
          {suggestions.map((suggestion) => (
            <div className="flex flex-col gap-2 rounded-[var(--radius-panel)] border border-border bg-surface-subtle px-3 py-2" key={suggestion.id}>
              <div>
                <Text className="font-medium">{t("source_suggestion_title", { source: suggestion.label })}</Text>
                <Text variant="caption" tone="muted">{suggestion.enabled ? t("source_suggestion_enable") : t("source_suggestion_disable")}</Text>
              </div>
              <div>
                <Button disabled={confirm.isPending} onClick={() => confirm.mutate(suggestion.id)} size="sm">{t("confirm_suggestion")}</Button>
              </div>
            </div>
          ))}
        </div>
      ) : null}
      <div className="grid gap-2 md:grid-cols-2 xl:grid-cols-3">
        {preferences.map((preference) => (
          <div className="flex min-h-16 items-start justify-between gap-3 rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-2" key={preference.id}>
            <div className="min-w-0">
              <Text className="font-medium">{preference.label}</Text>
              {preference.description ? <Text className="mt-1" variant="caption" tone="muted">{preference.description}</Text> : null}
            </div>
            <Toggle
              checked={preference.enabled}
              disabled={update.isPending}
              label={preference.enabled ? t("enabled") : t("disabled")}
              onChange={(enabled) => update.mutate({ id: preference.id, enabled })}
            />
          </div>
        ))}
      </div>
    </Section.Root>
  )
}

function SubscriptionGrid({ subscriptions }: { subscriptions: BriefingSubscription[] }) {
  const { t } = useT("operator_briefing")
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ id, enabled }: { id: number; enabled: boolean }) => updateBriefingSubscription(id, enabled),
    onSuccess: (payload) => queryClient.setQueryData(["operator_briefing"], payload)
  })

  if (subscriptions.length === 0) return <Text tone="muted">{t("empty_subscriptions")}</Text>

  return (
    <div className="grid gap-2 md:grid-cols-2 xl:grid-cols-3">
      {subscriptions.map((subscription) => (
        <div className="flex min-h-12 items-center justify-between gap-3 rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-2" key={subscription.id}>
          <Link className="min-w-0 truncate text-sm font-medium text-brand hover:underline" to={subscription.repository.path}>
            {subscription.repository.slug}
          </Link>
          <Toggle
            checked={subscription.enabled}
            disabled={mutation.isPending}
            label={subscription.enabled ? t("enabled") : t("disabled")}
            onChange={(enabled) => mutation.mutate({ id: subscription.id, enabled })}
          />
        </div>
      ))}
    </div>
  )
}

function RepositoryBriefing({ entry, pathname }: { entry: BriefingRepoPayload; pathname: string }) {
  const { t } = useT("operator_briefing")
  const queryClient = useQueryClient()
  const regenerate = useMutation({
    mutationFn: () => regenerateBriefing(entry.repository.id),
    onSuccess: (payload) => queryClient.setQueryData(["operator_briefing"], payload)
  })

  const current = entry.current

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <SectionHeading>{entry.repository.slug}</SectionHeading>
          {entry.status.message ? <Text className="mt-1" variant="caption" tone="muted">{entry.status.message}</Text> : null}
        </div>
        <Button onClick={() => regenerate.mutate()} size="sm" disabled={regenerate.isPending}>
          {regenerate.isPending ? t("regenerating") : t("regenerate")}
        </Button>
      </div>

      {current ? <BriefingCard briefing={current} pathname={pathname} /> : <Notice>{entry.status.message || t("no_current_briefing")}</Notice>}
    </div>
  )
}

function BriefingCard({ briefing, compact = false, pathname, primaryHref, showJobLink = false }: { briefing: BriefingRecord; compact?: boolean; pathname: string; primaryHref?: string; showJobLink?: boolean }) {
  const { t } = useT("operator_briefing")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const prefix = routePrefix(pathname)
  const revision = briefing.latest_revision
  const mainHref = primaryHref || briefing.job.path
  const contentRef = useRef<HTMLDivElement | null>(null)
  const [selection, setSelection] = useState<BriefingSelection | null>(null)
  const dive = useMutation({
    mutationFn: (input: { selected_text: string; prompt?: string; evidence?: unknown[] }) => startBriefingDive(briefing.id, input),
    onSuccess: (response) => {
      queryClient.setQueryData(["operator_briefing"], response.briefing)
      setSelection(null)
    }
  })
  const discuss = useMutation({
    mutationFn: () => discussBriefing(briefing.id),
    onSuccess: (response) => navigate(withRoutePrefix(response.redirect_to, prefix))
  })

  useEffect(() => {
    const container = contentRef.current
    if (!container || compact) return
    const selectionContainer = container

    function updateSelection() {
      const browserSelection = window.getSelection()
      const text = browserSelection?.toString().trim() || ""
      if (!browserSelection || text.length === 0 || !selectionContainer.contains(browserSelection.anchorNode) || !selectionContainer.contains(browserSelection.focusNode)) {
        setSelection(null)
        return
      }

      const range = browserSelection.rangeCount > 0 ? browserSelection.getRangeAt(0) : null
      const rect = range?.getBoundingClientRect()
      const containerRect = selectionContainer.getBoundingClientRect()
      if (!rect || rect.width === 0) {
        setSelection({ text, rect: null })
        return
      }

      setSelection({
        text,
        rect: {
          left: rect.left - containerRect.left,
          top: rect.top - containerRect.top,
          width: rect.width,
          containerWidth: containerRect.width
        }
      })
    }

    document.addEventListener("selectionchange", updateSelection)
    return () => document.removeEventListener("selectionchange", updateSelection)
  }, [compact])

  return (
    <Section.Root className="space-y-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <Link className="text-sm font-semibold text-brand hover:underline" to={withRoutePrefix(mainHref, prefix)}>{briefing.job.title}</Link>
            <span className="rounded-full border border-border px-2 py-0.5 text-2xs font-medium uppercase text-text-muted">{briefing.live ? t("live") : t("archived")}</span>
          </div>
          <Text className="mt-1" variant="caption" tone="muted">
            {briefing.window_start && briefing.window_end ? t("window", { start: briefing.window_start.slice(0, 10), end: briefing.window_end.slice(0, 10) }) : t("window_unknown")}
          </Text>
          {showJobLink ? <Link className="mt-1 inline-block text-xs text-brand hover:underline" to={withRoutePrefix(briefing.job.path, prefix)}>{t("view_job")}</Link> : null}
        </div>
        {revision?.generated_at ? <Text as="span" variant="caption" tone="muted"><RelativeTimestamp value={revision.generated_at} /></Text> : null}
      </div>

      {revision ? (
        <div className={`${compact ? "space-y-2" : "space-y-3"} relative`} ref={contentRef}>
          {selection && !compact ? (
            <SelectionDiveAffordance
              disabled={dive.isPending}
              onOpen={() => dive.mutate({ selected_text: selection.text })}
              selection={selection}
            />
          ) : null}
          {revision.content_blocks.map((block, index) => <BriefingBlockView block={block} briefingId={briefing.id} key={`${block.kind}-${index}`} prefix={prefix} />)}
        </div>
      ) : (
        <Notice>{briefing.live ? t("generating") : t("no_revision")}</Notice>
      )}

      {!compact ? (
        <div className="flex flex-wrap items-center gap-2 border-t border-border pt-3">
          <Button disabled={discuss.isPending} onClick={() => discuss.mutate()} size="sm" variant="secondary">{discuss.isPending ? t("discussing") : t("discuss_this")}</Button>
        </div>
      ) : null}
      {!compact ? <BriefingFeedbackForm briefingId={briefing.id} /> : null}
    </Section.Root>
  )
}

function BriefingFeedbackForm({ briefingId }: { briefingId: number }) {
  const { t } = useT("operator_briefing")
  const queryClient = useQueryClient()
  const [sentiment, setSentiment] = useState<"positive" | "negative" | "neutral" | null>(null)
  const [note, setNote] = useState("")
  const feedback = useMutation({
    mutationFn: () => createBriefingFeedback({ briefing_id: briefingId, sentiment: sentiment || undefined, note: note.trim() || undefined }),
    onSuccess: (response) => {
      queryClient.setQueryData(["operator_briefing"], response.briefing)
      setSentiment(null)
      setNote("")
    }
  })
  const canSubmit = Boolean(sentiment || note.trim())

  return (
    <form className="space-y-2 border-t border-border pt-3" onSubmit={(event) => {
      event.preventDefault()
      if (canSubmit) feedback.mutate()
    }}>
      <div className="flex flex-wrap items-center gap-2">
        <Text variant="caption" tone="muted">{t("feedback_label")}</Text>
        {(["positive", "negative", "neutral"] as const).map((value) => (
          <Button key={value} onClick={() => setSentiment(sentiment === value ? null : value)} size="sm" variant={sentiment === value ? "primary" : "secondary"} type="button">
            {t(`feedback_${value}`)}
          </Button>
        ))}
      </div>
      <Textarea
        aria-label={t("feedback_note")}
        onChange={(event) => setNote(event.target.value)}
        placeholder={t("feedback_note_placeholder")}
        value={note}
      />
      {feedback.isError ? <Text variant="caption" tone="danger">{t("feedback_error")}</Text> : null}
      <Button disabled={!canSubmit || feedback.isPending} size="sm" type="submit">
        {feedback.isPending ? t("feedback_saving") : t("feedback_submit")}
      </Button>
    </form>
  )
}

function BriefingBlockView({ block, briefingId, prefix }: { block: BriefingBlock; briefingId: number; prefix: string }) {
  const { t } = useT("operator_briefing")

  if (block.kind === "narrative") {
    return <NarrativeBlock briefingId={briefingId} candidates={block.payload.dive_candidates || []} text={block.payload.text || ""} />
  }

  if (block.kind === "link_card") {
    return (
      <Link className="block rounded-[var(--radius-panel)] border border-border bg-surface-subtle px-3 py-2 hover:border-brand" to={withRoutePrefix(block.payload.path || "/", prefix)}>
        <Text className="font-medium">{block.payload.title || t("untitled_link")}</Text>
        {block.payload.description ? <Text className="mt-1" variant="caption" tone="muted">{block.payload.description}</Text> : null}
      </Link>
    )
  }

  if (block.kind === "chart") {
    return <BriefingChart data={block.payload.data || []} title={block.payload.title || t("chart_title")} />
  }

  if (block.kind === "image" || block.kind === "artifact") {
    return (
      <div className="overflow-hidden rounded-[var(--radius-panel)] border border-border bg-surface">
        <div className="border-b border-border px-3 py-2">
          <Text className="font-medium">{block.payload.title || block.payload.artifact?.title || block.payload.type || t("artifact_title")}</Text>
          {block.payload.caption ? <Text className="mt-1" variant="caption" tone="muted">{block.payload.caption}</Text> : null}
        </div>
        <div className="overflow-x-auto p-3">
          {block.payload.artifact ? <ArtifactBody artifact={block.payload.artifact} /> : <Text tone="muted">{t("artifact_unavailable")}</Text>}
        </div>
      </div>
    )
  }

  return null
}

function NarrativeBlock({ briefingId, candidates, text }: { briefingId: number; candidates: BriefingDiveCandidate[]; text: string }) {
  const queryClient = useQueryClient()
  const dive = useMutation({
    mutationFn: (candidate: BriefingDiveCandidate) => startBriefingDive(briefingId, { selected_text: candidate.text, prompt: candidate.prompt || undefined, evidence: candidate.evidence || undefined }),
    onSuccess: (response) => queryClient.setQueryData(["operator_briefing"], response.briefing)
  })
  const parts = narrativeParts(text, candidates)

  return (
    <Text className="max-w-4xl whitespace-pre-wrap leading-6">
      {parts.map((part, index) => part.candidate ? (
        <button
          className="inline border-b border-dashed border-brand text-left text-brand hover:bg-brand/10 disabled:opacity-60"
          disabled={dive.isPending}
          key={`${part.text}-${index}`}
          onClick={() => dive.mutate(part.candidate!)}
          type="button"
        >
          {part.text}<span className="ml-0.5 text-2xs font-semibold">?</span>
        </button>
      ) : <span key={`${part.text}-${index}`}>{part.text}</span>)}
    </Text>
  )
}

function narrativeParts(text: string, candidates: BriefingDiveCandidate[]) {
  const parts: Array<{ text: string; candidate?: BriefingDiveCandidate }> = []
  let cursor = 0
  for (const candidate of candidates) {
    const needle = candidate.text
    if (!needle) continue
    const index = text.indexOf(needle, cursor)
    if (index < 0) continue
    if (index > cursor) parts.push({ text: text.slice(cursor, index) })
    parts.push({ text: text.slice(index, index + needle.length), candidate })
    cursor = index + needle.length
  }
  if (cursor < text.length) parts.push({ text: text.slice(cursor) })
  return parts.length > 0 ? parts : [ { text } ]
}

function BriefingChart({ data, title }: { data: BriefingChartDatum[]; title: string }) {
  const max = Math.max(1, ...data.map((datum) => Number(datum.value) || 0))
  return (
    <div className="rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-3">
      <Text className="font-medium">{title}</Text>
      <div className="mt-3 space-y-2">
        {data.map((datum) => (
          <div className="grid grid-cols-[minmax(7rem,12rem)_1fr_auto] items-center gap-2 text-sm" key={datum.label}>
            <span className="truncate text-text-muted">{datum.label}</span>
            <span className="h-2 rounded-full bg-surface-subtle">
              <span className="block h-2 rounded-full bg-brand" style={{ width: `${Math.max(4, (datum.value / max) * 100)}%` }} />
            </span>
            <span className="tabular-nums text-text-primary">{datum.value}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function SelectionDiveAffordance({ disabled, selection, onOpen }: { disabled: boolean; selection: BriefingSelection; onOpen: () => void }) {
  const { t } = useT("operator_briefing")
  return (
    <div className="absolute z-30" style={selection.rect ? selectionAffordanceStyle(selection.rect) : { left: "1rem", top: "1rem" }}>
      <Button
        disabled={disabled}
        onClick={onOpen}
        onMouseDown={(event) => event.preventDefault()}
        size="sm"
        title={t("more_info")}
        variant="secondary"
      >
        {t("more_info")}
      </Button>
    </div>
  )
}

function selectionAffordanceStyle(rect: SelectionRect) {
  const iconWidth = 92
  const inset = 8
  const gap = 8
  const preferredTop = rect.top - 36 - gap
  if (preferredTop >= inset) return { left: `${clampAffordanceLeft(rect.left, rect.containerWidth, iconWidth)}px`, top: `${preferredTop}px` }
  const rightSideLeft = rect.left + rect.width + gap
  if (rightSideLeft + iconWidth <= rect.containerWidth - inset) return { left: `${rightSideLeft}px`, top: `${inset}px` }
  const leftSideLeft = rect.left - iconWidth - gap
  if (leftSideLeft >= inset) return { left: `${leftSideLeft}px`, top: `${inset}px` }
  return { left: `${clampAffordanceLeft(rect.left, rect.containerWidth, iconWidth)}px`, top: `${inset}px` }
}

function clampAffordanceLeft(left: number, containerWidth: number, iconWidth: number) {
  const inset = 8
  const maxLeft = Math.max(inset, containerWidth - iconWidth - inset)
  return Math.min(Math.max(left, inset), maxLeft)
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}
