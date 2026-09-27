import { Button, Modal, Notice, Page, PageHeading, Section, SectionHeading, Text, Textarea, Toggle, buttonClasses } from "@app/components/ui"
import { UnderlineTabs } from "@app/components/Tabs"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation, useSearchParams } from "react-router-dom"
import { confirmBriefingSourcePreference, createBriefingFeedback, fetchBriefing, regenerateBriefing, updateBriefingSourcePreference, updateBriefingSubscription, type BriefingBlock, type BriefingPayload, type BriefingRecord, type BriefingRepoPayload, type BriefingSourcePreference, type BriefingSubscription } from "../api/briefing"

export default function BriefingRoute() {
  const { t } = useT("operator_briefing")
  usePageTitle(t("title"))
  const briefing = useQuery({ queryKey: ["operator_briefing"], queryFn: fetchBriefing })

  if (briefing.isPending) {
    return <Page.Root gutter="responsive" size="wide"><Notice>{t("common:loading")}</Notice></Page.Root>
  }

  if (briefing.isError) {
    return <Page.Root gutter="responsive" size="wide"><Notice tone="danger">{t("load_error")}</Notice></Page.Root>
  }

  return <BriefingPage payload={briefing.data} />
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
  const prefix = routePrefix(pathname)
  const revision = briefing.latest_revision
  const mainHref = primaryHref || briefing.job.path

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
        <div className={compact ? "space-y-2" : "space-y-3"}>
          {revision.content_blocks.map((block, index) => <BriefingBlockView block={block} key={`${block.kind}-${index}`} prefix={prefix} />)}
        </div>
      ) : (
        <Notice>{briefing.live ? t("generating") : t("no_revision")}</Notice>
      )}

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

function BriefingBlockView({ block, prefix }: { block: BriefingBlock; prefix: string }) {
  const { t } = useT("operator_briefing")

  if (block.kind === "narrative") {
    return <Text className="max-w-4xl whitespace-pre-wrap leading-6">{block.payload.text || ""}</Text>
  }

  if (block.kind === "link_card") {
    return (
      <Link className="block rounded-[var(--radius-panel)] border border-border bg-surface-subtle px-3 py-2 hover:border-brand" to={withRoutePrefix(block.payload.path || "/", prefix)}>
        <Text className="font-medium">{block.payload.title || t("untitled_link")}</Text>
        {block.payload.description ? <Text className="mt-1" variant="caption" tone="muted">{block.payload.description}</Text> : null}
      </Link>
    )
  }

  return null
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}
