import { describe, expect, it } from "vitest"
import type { WorkbenchDefinition } from "../api/workbench"
import { buildDiscussionContext, buildDiscussionPrompt } from "./DiscussDialog"
import { buildFixtures, buildStack, FIXTURE_STATES } from "./fixtures"
import { buildFilterLink, matchesFilters, selectionFromSearch, selectionToSearch } from "./search"

function definition(overrides: Partial<WorkbenchDefinition> = {}): WorkbenchDefinition {
  return {
    key: "example.first_job_landed",
    version: 1,
    scope: "user",
    trigger: "job.closed",
    evaluator: "Achievements::Evaluators::FirstOccurrence",
    subject_kinds: ["job"],
    visibility: "visible",
    category: "landing",
    rarity: "common",
    presentation: { title_key: "achievements:example.first_job_landed.title" },
    implementation_status: "implemented",
    ...overrides
  }
}

describe("fixtures", () => {
  it("builds a complete, internally consistent fixture for every state", () => {
    for (const hidden of [false, true]) {
      const fixtures = buildFixtures(definition({ visibility: hidden ? "hidden" : "visible" }))
      expect(fixtures.map((fixture) => fixture.state)).toEqual([...FIXTURE_STATES])

      const byState = Object.fromEntries(fixtures.map((fixture) => [fixture.state, fixture]))
      expect(byState.locked.unlock).toBeNull()
      expect(byState.locked.locked.hidden).toBe(hidden)
      expect(byState.unlocked.unlock).toMatchObject({ acknowledged: false, acknowledged_at: null })
      expect(byState.acknowledged.unlock).toMatchObject({ acknowledged: true })
      expect(byState.acknowledged.unlock?.acknowledged_at).toBeTruthy()
      // A reset keeps the unlock and only clears the acknowledgment.
      expect(byState.reset.unlock).toMatchObject({ acknowledged: false, acknowledged_at: null, unlocked_at: byState.acknowledged.unlock?.unlocked_at })
    }
  })

  it("never leaks a hidden definition's copy through its locked fixture", () => {
    const locked = buildFixtures(definition({ visibility: "hidden" }))[0].locked
    expect(locked).toEqual({ hidden: true, scope: "user" })
  })

  it("builds distinct stacked reveals", () => {
    const stack = buildStack([definition(), definition({ key: "example.other" })], 3)
    expect(new Set(stack.map((unlock) => unlock.id)).size).toBe(3)
    expect(buildStack([], 3)).toEqual([])
  })
})

describe("selection and filters", () => {
  it("round-trips every setting through the deep link", () => {
    const selection = selectionFromSearch("?scope=user&rarity=rare&definition=a.b&state=reset&viewport=phone&motion=reduced&audio=1")
    expect(selection).toMatchObject({ filters: { scope: "user", rarity: "rare" }, definition: "a.b", state: "reset", viewport: "phone", motion: "reduced", audio: true })
    expect(selectionFromSearch(selectionToSearch(selection))).toEqual(selection)
  })

  it("falls back to defaults for unknown values", () => {
    expect(selectionFromSearch("?state=nope&viewport=huge&motion=wild")).toMatchObject({ state: "unlocked", viewport: "desktop", motion: "system", audio: false })
    expect(selectionToSearch(selectionFromSearch(""))).toBe("")
  })

  it("filters on scope, category, rarity, trigger, visibility and implementation status", () => {
    const d = definition()
    expect(matchesFilters(d, { scope: "user", category: "landing", rarity: "common", trigger: "job.closed", visibility: "visible", implementation_status: "implemented" })).toBe(true)
    for (const filters of [{ scope: "instance" }, { category: "work" }, { rarity: "rare" }, { trigger: "epic.upserted" }, { visibility: "hidden" }, { implementation_status: "planned" }]) {
      expect(matchesFilters(d, filters)).toBe(false)
    }
  })

  it("translates FilterBar's encoded tree into flat params", () => {
    const encoded = btoa(JSON.stringify({ and: [{ field: "rarity", op: "is", value: "rare" }] }))
    expect(buildFilterLink("/admin/achievements_workbench", "?viewport=phone&scope=user", { q: encoded })).toBe("/admin/achievements_workbench?viewport=phone&rarity=rare")
    expect(buildFilterLink("/admin/achievements_workbench", "?viewport=phone&scope=user", { q: null })).toBe("/admin/achievements_workbench?viewport=phone")
  })
})

describe("discussion payload", () => {
  const input = {
    definition: definition(),
    fixtureState: "reset" as const,
    viewport: { id: "phone" as const, width: 390 },
    motion: "reduced" as const,
    audio: { supported: false, enabled: false },
    deepLink: "https://syrus.example/admin/achievements_workbench?definition=example.first_job_landed"
  }

  it("captures definition, fixture, viewport, motion, audio, link, screenshot and annotations", () => {
    const shapes = [{ id: "s1" }] as never
    const context = buildDiscussionContext(input, { attached: true, error: null }, shapes)
    expect(context).toMatchObject({
      definition: { key: "example.first_job_landed", rarity: "common", implementation_status: "implemented" },
      fixture_state: "reset",
      viewport: { id: "phone", width: 390 },
      motion: "reduced",
      audio: { supported: false, enabled: false },
      deep_link: input.deepLink,
      screenshot: { attached: true, error: null },
      annotations: shapes
    })

    const prompt = buildDiscussionPrompt("  Make it shinier  ", context)
    expect(prompt.startsWith("Make it shinier")).toBe(true)
    expect(prompt).toContain("Fixture state: reset")
    expect(prompt).toContain("Audio: not supported yet")
    expect(prompt).toContain(input.deepLink)
    expect(JSON.parse(prompt.split("```json\n")[1].split("\n```")[0])).toEqual(JSON.parse(JSON.stringify(context)))
  })

  it("records a failed screenshot rather than dropping the discussion", () => {
    const prompt = buildDiscussionPrompt("", buildDiscussionContext(input, { attached: false, error: "boom" }))
    expect(prompt).toContain('Discuss the "example.first_job_landed" achievement')
    expect(prompt).toContain("Screenshot: not attached (boom)")
  })
})
