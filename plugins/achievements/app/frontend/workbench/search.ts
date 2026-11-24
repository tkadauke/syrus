import type { FilterLinkBuilder, FilterTree } from "@app/components/FilterBar"
import type { WorkbenchDefinition } from "../api/workbench"
import { FIXTURE_STATES, type FixtureState } from "./fixtures"

export const FILTER_FIELDS = ["scope", "category", "rarity", "trigger", "visibility", "implementation_status"] as const
export type FilterField = (typeof FILTER_FIELDS)[number]

export const VIEWPORTS = [
  { id: "phone", width: 390 },
  { id: "tablet", width: 768 },
  { id: "desktop", width: 1280 }
] as const
export type ViewportId = (typeof VIEWPORTS)[number]["id"]

export type MotionSetting = "system" | "reduced" | "full"
export const MOTION_SETTINGS: MotionSetting[] = ["system", "reduced", "full"]

export type WorkbenchSelection = {
  filters: Partial<Record<FilterField, string>>
  definition: string | null
  state: FixtureState
  viewport: ViewportId
  motion: MotionSetting
  audio: boolean
}

export function selectionFromSearch(search: string): WorkbenchSelection {
  const params = new URLSearchParams(search)
  const filters: Partial<Record<FilterField, string>> = {}
  for (const field of FILTER_FIELDS) {
    const value = params.get(field)?.trim()
    if (value) filters[field] = value
  }
  const state = FIXTURE_STATES.find((candidate) => candidate === params.get("state")) ?? "unlocked"
  const viewport = VIEWPORTS.find((candidate) => candidate.id === params.get("viewport"))?.id ?? "desktop"
  const motion = MOTION_SETTINGS.find((candidate) => candidate === params.get("motion")) ?? "system"
  return { filters, definition: params.get("definition"), state, viewport, motion, audio: params.get("audio") === "1" }
}

export function selectionToSearch(selection: WorkbenchSelection): string {
  const params = new URLSearchParams()
  for (const field of FILTER_FIELDS) {
    const value = selection.filters[field]
    if (value) params.set(field, value)
  }
  if (selection.definition) params.set("definition", selection.definition)
  if (selection.state !== "unlocked") params.set("state", selection.state)
  if (selection.viewport !== "desktop") params.set("viewport", selection.viewport)
  if (selection.motion !== "system") params.set("motion", selection.motion)
  if (selection.audio) params.set("audio", "1")
  const query = params.toString()
  return query ? `?${query}` : ""
}

export function matchesFilters(definition: WorkbenchDefinition, filters: Partial<Record<FilterField, string>>) {
  return FILTER_FIELDS.every((field) => {
    const wanted = filters[field]
    if (!wanted) return true
    const actual = field === "trigger" ? definition.trigger : String(definition[field])
    return actual === wanted
  })
}

export function filterTree(filters: Partial<Record<FilterField, string>>): FilterTree {
  return { and: FILTER_FIELDS.flatMap((field) => (filters[field] ? [{ field, op: "is", value: filters[field] as string }] : [])) }
}

function decodeChips(encoded: string): Array<{ field: string; value: string }> {
  try {
    const parsed = JSON.parse(atob(encoded.replace(/-/g, "+").replace(/_/g, "/"))) as { and?: unknown[] }
    return (parsed.and ?? []).flatMap((node) => {
      const chip = node as { field?: unknown; value?: unknown }
      return typeof chip?.field === "string" && typeof chip.value === "string" && chip.value ? [{ field: chip.field, value: chip.value }] : []
    })
  } catch {
    // handled-error-expected: a hand-edited or stale link may carry a malformed filter; it simply yields no chips.
    return []
  }
}

// FilterBar speaks a base64 `q=<tree>` wire format; the workbench keeps its
// state as flat, readable query params so a deep link is legible and the other
// settings (viewport, motion, ...) stay independent of the filter encoding.
export const buildFilterLink: FilterLinkBuilder = (path, search, updates) => {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (key === "q") continue
    if (value == null || String(value).length === 0) params.delete(key)
    else params.set(key, String(value))
  }
  const encoded = updates.q
  if (typeof encoded === "string" && encoded.length > 0) {
    for (const field of FILTER_FIELDS) params.delete(field)
    for (const chip of decodeChips(encoded)) if ((FILTER_FIELDS as readonly string[]).includes(chip.field)) params.set(chip.field, chip.value)
  } else if (encoded == null) {
    for (const field of FILTER_FIELDS) params.delete(field)
  }
  const query = params.toString()
  return query ? `${path}?${query}` : path
}
