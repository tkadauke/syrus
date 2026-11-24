import { Link, useLocation } from "react-router-dom"
import { Button } from "@app/components/Button"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { Pill } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import type { AchievementUnlock, LockedAchievement } from "../api/achievements"
import { AchievementBadge } from "./AchievementBadge"

export function useAchievementText() {
  const { t } = useT("achievements")
  return {
    t,
    title: (presentation: { title_key?: string }, fallback: string) => (presentation.title_key ? t(presentation.title_key) : fallback),
    description: (presentation: { description_key?: string; teaser_key?: string }, locked = false) => {
      const key = locked ? (presentation.teaser_key ?? presentation.description_key) : presentation.description_key
      return key ? t(key) : null
    }
  }
}

export function UnlockedCard({
  unlock,
  busy,
  onAcknowledge,
  onReplay
}: {
  unlock: AchievementUnlock
  busy: boolean
  onAcknowledge: () => void
  onReplay: () => void
}) {
  const { t, title, description } = useAchievementText()
  const prefix = routePrefix(useLocation().pathname)
  const link = unlock.evidence_link
  const href = link ? withRoutePrefix(`/${link.kind === "job" ? "jobs" : "epics"}/${link.id}`, prefix) : null
  const name = title(unlock.presentation, unlock.key)

  return (
    <li className="rounded-[var(--radius-panel)] border border-border bg-surface p-4" data-testid="achievement-card">
      <div className="flex items-start gap-3">
        <AchievementBadge category={unlock.category} className="mt-0.5" rarity={unlock.rarity} scope={unlock.scope} size="sm" />
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

export function LockedCard({ locked }: { locked: LockedAchievement }) {
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
