import type { AchievementUnlock, LockedAchievement } from "../api/achievements"
import type { WorkbenchDefinition } from "../api/workbench"

// Synthetic fixtures: the workbench never touches real unlock data, so the
// admin can replay and "reset" freely. Each state mirrors what the production
// payloads (`/api/v1/app/achievements`) look like for that state.
export const FIXTURE_STATES = ["locked", "unlocked", "acknowledged", "reset"] as const
export type FixtureState = (typeof FIXTURE_STATES)[number]

export type Fixture = {
  state: FixtureState
  definition: WorkbenchDefinition
  unlock: AchievementUnlock | null
  locked: LockedAchievement
}

const FIXTURE_TIME = "2026-01-01T09:00:00Z"
const ACK_TIME = "2026-01-01T09:05:00Z"

export function buildFixture(definition: WorkbenchDefinition, state: FixtureState, index = 0): Fixture {
  const locked: LockedAchievement =
    definition.visibility === "hidden"
      ? { hidden: true, scope: definition.scope }
      : {
          hidden: false,
          key: definition.key,
          scope: definition.scope,
          category: definition.category,
          rarity: definition.rarity,
          presentation: definition.presentation
        }
  if (state === "locked") return { state, definition, unlock: null, locked }

  const acknowledged = state === "acknowledged"
  const unlock: AchievementUnlock = {
    id: -(index + 1),
    key: definition.key,
    version: definition.version,
    scope: definition.scope,
    category: definition.category,
    rarity: definition.rarity,
    visibility: definition.visibility,
    presentation: definition.presentation,
    unlocked_at: FIXTURE_TIME,
    acknowledged,
    acknowledged_at: acknowledged ? ACK_TIME : null,
    evidence_link: null
  }
  return { state, definition, unlock, locked }
}

export function buildFixtures(definition: WorkbenchDefinition, index = 0): Fixture[] {
  return FIXTURE_STATES.map((state) => buildFixture(definition, state, index))
}

// A stack of distinct unlocks for the queue: each definition appears once, with
// ids and times that keep the production ordering deterministic.
export function buildStack(definitions: WorkbenchDefinition[], count: number): AchievementUnlock[] {
  if (definitions.length === 0) return []
  return Array.from({ length: count }, (_, position) => {
    const definition = definitions[position % definitions.length]
    const unlock = buildFixture(definition, "unlocked", position).unlock as AchievementUnlock
    return { ...unlock, unlocked_at: `2026-01-01T09:00:${String(position).padStart(2, "0")}Z` }
  })
}
