import { getJson, postJson } from "@app/api/client"

export type AchievementScope = "instance" | "user"

export type AchievementPresentation = {
  title_key?: string
  description_key?: string
  teaser_key?: string
  glyph?: string
}

export type AchievementEvidenceLink = {
  kind: "job" | "epic"
  id: number
  slug: string
}

export type AchievementUnlock = {
  id: number
  key: string
  version: number
  scope: AchievementScope
  category: string
  rarity: string
  visibility: "visible" | "hidden"
  presentation: AchievementPresentation
  unlocked_at: string
  acknowledged: boolean
  acknowledged_at: string | null
  evidence_link?: AchievementEvidenceLink | null
}

export type LockedAchievement =
  | { hidden: true; scope: AchievementScope }
  | { hidden: false; key: string; scope: AchievementScope; category: string; rarity: string; presentation: AchievementPresentation }

export type AchievementsPayload = {
  achievements: AchievementUnlock[]
  locked: LockedAchievement[]
}

const BASE = "/api/v1/app/achievements"

export const achievementsQueryKey = ["achievements"] as const

export function fetchAchievements() {
  return getJson<AchievementsPayload>(BASE)
}

export function fetchPendingAchievements(subject?: { type: string; id: number }) {
  const query = subject ? `?subject_type=${encodeURIComponent(subject.type)}&subject_id=${subject.id}` : ""
  return getJson<{ achievements: AchievementUnlock[] }>(`${BASE}/pending${query}`)
}

export function acknowledgeAchievement(id: number) {
  return postJson<{ achievement: AchievementUnlock }>(`${BASE}/${id}/acknowledge`)
}

export function replayAchievement(id: number) {
  return postJson<{ achievement: AchievementUnlock }>(`${BASE}/${id}/replay`)
}

export function resetAchievementAcknowledgments() {
  return postJson<{ reset: number }>(`${BASE}/reset_acknowledgments`)
}
