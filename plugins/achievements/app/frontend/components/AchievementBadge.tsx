import type { AchievementScope } from "../api/achievements"

export type AchievementBadgeSize = "sm" | "md" | "lg"
export type AchievementBadgeState = "unlocked" | "locked" | "hidden"

const SIZES: Record<AchievementBadgeSize, { outer: string; inner: string }> = {
  sm: { outer: "h-10 w-10 border-2", inner: "h-4 w-4 border-2" },
  md: { outer: "h-14 w-14 border-2", inner: "h-6 w-6 border-2" },
  lg: { outer: "h-20 w-20 border-4", inner: "h-8 w-8 border-2" }
}

type Props = {
  size?: AchievementBadgeSize
  state?: AchievementBadgeState
  rarity?: string
  category?: string
  scope?: AchievementScope
  className?: string
}

// The one badge every production surface (collection cards, reveals) and the
// development workbench draw. Artwork is a deliberately neutral ring; the later
// badge-design round replaces the inside of this component only. The data-*
// attributes expose the definition facts design variants can key on.
export function AchievementBadge({ size = "md", state = "unlocked", rarity, category, scope, className = "" }: Props) {
  const dimensions = SIZES[size]
  const faded = state === "unlocked" ? "border-border bg-surface-raised" : "border-dashed border-border bg-surface opacity-70"
  const ring = state === "unlocked" ? "border-brand" : "border-border"
  return (
    <span
      aria-hidden="true"
      className={`flex shrink-0 items-center justify-center rounded-full ${dimensions.outer} ${faded} ${className}`}
      data-category={category}
      data-rarity={rarity}
      data-scope={scope}
      data-state={state}
      data-testid="achievement-badge"
    >
      <span className={`rounded-full ${dimensions.inner} ${ring}`} />
    </span>
  )
}
