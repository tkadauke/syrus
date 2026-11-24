import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Button } from "@app/components/Button"
import { Notice, Page, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  acknowledgeAchievement,
  achievementsQueryKey,
  fetchAchievements,
  replayAchievement,
  resetAchievementAcknowledgments,
  type AchievementScope,
  type AchievementUnlock
} from "../api/achievements"
import { LockedCard, UnlockedCard } from "../components/AchievementCards"
import { AchievementRevealQueue } from "../components/AchievementReveal"

const SCOPES: AchievementScope[] = ["instance", "user"]

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
