import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { Button } from "@app/components/Button"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { Notice, Page, Pill, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import {
  acknowledgeAchievement,
  achievementsQueryKey,
  fetchAchievements,
  replayAchievement,
  resetAchievementAcknowledgments,
  type AchievementScope,
  type AchievementUnlock,
  type LockedAchievement
} from "../api/achievements"
import { AchievementRevealQueue } from "../components/AchievementReveal"

const SCOPES: AchievementScope[] = ["instance", "user"]

function useAchievementText() {
  const { t } = useT("achievements")
  return {
    t,
    title: (presentation: { title_key?: string }, fallback: string) => (presentation.title_key ? t(presentation.title_key) : fallback),
    description: (presentation: { description_key?: string; teaser_key?: string }, locked = false) => {
      const key = locked ? presentation.teaser_key ?? presentation.description_key : presentation.description_key
      return key ? t(key) : null
    }
  }
}

function UnlockedCard({ unlock, busy, onAcknowledge, onReplay }: { unlock: AchievementUnlock; busy: boolean; onAcknowledge: () => void; onReplay: () => void }) {
  const { t, title, description } = useAchievementText()
  const prefix = routePrefix(useLocation().pathname)
  const link = unlock.evidence_link
  const href = link ? withRoutePrefix(`/${link.kind === "job" ? "jobs" : "epics"}/${link.id}`, prefix) : null
  const name = title(unlock.presentation, unlock.key)

  return (
    <li className="rounded-[var(--radius-panel)] border border-border bg-surface p-4" data-testid="achievement-card">
      <div className="flex items-start gap-3">
        <span aria-hidden="true" className="mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-full border-2 border-border bg-surface-raised">
          <span className="h-4 w-4 rounded-full border-2 border-brand" />
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="min-w-0 break-words text-sm font-semibold text-text-primary">{name}</h3>
            {!unlock.acknowledged ? <Pill tone="info">{t("status_new")}</Pill> : null}
            {unlock.visibility === "hidden" ? <Pill>{t("status_hidden")}</Pill> : null}
          </div>
          {description(unlock.presentation) ? <p className="mt-1 text-sm text-text-secondary">{description(unlock.presentation)}</p> : null}
          <p className="mt-2 text-xs text-text-secondary">
            {t("earned")} <RelativeTimestamp value={unlock.unlocked_at} />
            {link && href ? (
              <>
                {" · "}
                <Link className="text-brand hover:underline" to={href}>
                  {t("evidence_link", { slug: link.slug })}
                </Link>
              </>
            ) : null}
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            {!unlock.acknowledged ? (
              <Button aria-label={t("acknowledge_label", { name })} disabled={busy} onClick={onAcknowledge} size="sm" variant="secondary">
                {t("acknowledge")}
              </Button>
            ) : null}
            <Button aria-label={t("replay_label", { name })} disabled={busy} onClick={onReplay} size="sm" variant="secondary">
              {t("replay")}
            </Button>
          </div>
        </div>
      </div>
    </li>
  )
}

function LockedCard({ locked }: { locked: LockedAchievement }) {
  const { t, title, description } = useAchievementText()
  if (locked.hidden) {
    return (
      <li className="rounded-[var(--radius-panel)] border border-dashed border-border p-4 text-text-secondary" data-testid="achievement-hidden">
        <p className="text-sm font-medium">{t("hidden_title")}</p>
        <p className="mt-1 text-xs">{t("hidden_description")}</p>
      </li>
    )
  }

  return (
    <li className="rounded-[var(--radius-panel)] border border-dashed border-border p-4 text-text-secondary" data-testid="achievement-locked">
      <div className="flex flex-wrap items-center gap-2">
        <p className="min-w-0 break-words text-sm font-medium">{title(locked.presentation, locked.key)}</p>
        <Pill>{t("status_locked")}</Pill>
      </div>
      {description(locked.presentation, true) ? <p className="mt-1 text-xs">{description(locked.presentation, true)}</p> : null}
    </li>
  )
}

export default function Achievements() {
  const { t } = useT("achievements")
  usePageTitle(t("title"))
  const queryClient = useQueryClient()
  const list = useQuery({ queryKey: [...achievementsQueryKey, "list"], queryFn: fetchAchievements })
  const [replaying, setReplaying] = useState<AchievementUnlock[]>([])
  const [replayKey, setReplayKey] = useState(0)

  const refresh = () => queryClient.invalidateQueries({ queryKey: achievementsQueryKey })
  const acknowledge = useMutation({ mutationFn: (unlock: AchievementUnlock) => acknowledgeAchievement(unlock.id), onSuccess: refresh })
  const replay = useMutation({
    mutationFn: (unlock: AchievementUnlock) => replayAchievement(unlock.id),
    onSuccess: (response) => {
      setReplaying([response.achievement])
      setReplayKey((key) => key + 1)
      void refresh()
    }
  })
  const reset = useMutation({ mutationFn: resetAchievementAcknowledgments, onSuccess: refresh })
  const busy = acknowledge.isPending || replay.isPending || reset.isPending
  const failure = acknowledge.error ?? replay.error ?? reset.error

  const unlocked = list.data?.achievements ?? []
  const locked = list.data?.locked ?? []

  return (
    <Page.Root aria-label={t("title")} className="space-y-5" gutter="responsive" size="default">
      <Page.Header className="border-b border-border pb-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <Page.Title>{t("title")}</Page.Title>
            <Page.Description>{t("description")}</Page.Description>
          </div>
          <Button disabled={busy || unlocked.length === 0} onClick={() => reset.mutate()} size="sm" variant="secondary">
            {t("reset_mine")}
          </Button>
        </div>
      </Page.Header>

      {failure ? <Notice tone="danger">{errorMessage(failure, t("action_failed"))}</Notice> : null}
      {list.isLoading ? <Text tone="muted">{t("loading")}</Text> : null}
      {list.isError ? (
        <Notice tone="danger">
          <span>{t("load_failed")}</span>{" "}
          <Button onClick={() => list.refetch()} size="sm" variant="secondary">
            {t("reveal_retry")}
          </Button>
        </Notice>
      ) : null}

      {list.data
        ? SCOPES.map((scope) => {
            const earned = unlocked.filter((unlock) => unlock.scope === scope)
            const open = locked.filter((entry) => entry.scope === scope)
            return (
              <section aria-labelledby={`achievements-${scope}`} key={scope}>
                <h2 className="text-base font-semibold text-text-primary" id={`achievements-${scope}`}>
                  {t(`section_${scope}`)}
                </h2>
                <Text tone="muted" variant="caption">
                  {t(`section_${scope}_hint`)}
                </Text>
                {earned.length === 0 && open.length === 0 ? <p className="mt-3 text-sm text-text-secondary">{t("empty")}</p> : null}
                <ul className="mt-3 grid gap-3 sm:grid-cols-2">
                  {earned.map((unlock) => (
                    <UnlockedCard
                      busy={busy}
                      key={unlock.id}
                      onAcknowledge={() => acknowledge.mutate(unlock)}
                      onReplay={() => replay.mutate(unlock)}
                      unlock={unlock}
                    />
                  ))}
                  {open.map((entry, index) => (
                    <LockedCard key={entry.hidden ? `hidden-${index}` : entry.key} locked={entry} />
                  ))}
                </ul>
              </section>
            )
          })
        : null}

      <AchievementRevealQueue
        acknowledge={async (unlock) => {
          await acknowledgeAchievement(unlock.id)
          void refresh()
        }}
        key={replayKey}
        onFinished={() => setReplaying([])}
        reveals={replaying}
      />
    </Page.Root>
  )
}
