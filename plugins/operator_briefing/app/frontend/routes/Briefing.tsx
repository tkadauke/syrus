import { Button, Notice, Page, PageHeading, Section, SectionHeading, Text, Toggle } from "@app/components/ui"
import { UnderlineTabs } from "@app/components/Tabs"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { fetchBriefing, regenerateBriefing, updateBriefingSubscription, type BriefingBlock, type BriefingPayload, type BriefingRecord, type BriefingRepoPayload, type BriefingSubscription } from "../api/briefing"

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
  const [activeRepositoryId, setActiveRepositoryId] = useState<number | null>(() => payload.repositories[0]?.repository.id ?? null)
  const activeRepo = useMemo(() => {
    if (payload.repositories.length === 0) return null
    return payload.repositories.find((entry) => entry.repository.id === activeRepositoryId) ?? payload.repositories[0]
  }, [activeRepositoryId, payload.repositories])

  return (
    <Page.Root aria-label={t("aria_label")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{t("eyebrow")}</Text>
        <PageHeading>{t("title")}</PageHeading>
        <Page.Description>{t("description", { cadence: payload.settings.cadence_expression })}</Page.Description>
      </Page.Header>

      <Section.Root className="space-y-3">
        <div className="flex items-center justify-between gap-3">
          <SectionHeading>{t("subscriptions")}</SectionHeading>
          <Text variant="caption" tone="muted">{t("subscribed_count", { count: payload.repositories.length })}</Text>
        </div>
        <SubscriptionGrid subscriptions={payload.subscriptions} />
      </Section.Root>

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
    </Page.Root>
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

      {current ? <BriefingCard briefing={current} pathname={pathname} /> : <Notice>{t("no_current_briefing")}</Notice>}

      <Section.Root className="space-y-3">
        <SectionHeading>{t("history")}</SectionHeading>
        {entry.history.length === 0 ? (
          <Text tone="muted">{t("empty_history")}</Text>
        ) : (
          <div className="space-y-3">
            {entry.history.map((briefing) => <BriefingCard briefing={briefing} key={briefing.id} pathname={pathname} compact />)}
          </div>
        )}
      </Section.Root>
    </div>
  )
}

function BriefingCard({ briefing, compact = false, pathname }: { briefing: BriefingRecord; compact?: boolean; pathname: string }) {
  const { t } = useT("operator_briefing")
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const revision = briefing.latest_revision

  return (
    <Section.Root className="space-y-3">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <Link className="text-sm font-semibold text-brand hover:underline" to={withRoutePrefix(briefing.job.path, prefix)}>{briefing.job.title}</Link>
            <span className="rounded-full border border-border px-2 py-0.5 text-2xs font-medium uppercase text-text-muted">{briefing.live ? t("live") : t("archived")}</span>
          </div>
          <Text className="mt-1" variant="caption" tone="muted">
            {briefing.window_start && briefing.window_end ? t("window", { start: briefing.window_start.slice(0, 10), end: briefing.window_end.slice(0, 10) }) : t("window_unknown")}
          </Text>
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
    </Section.Root>
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
