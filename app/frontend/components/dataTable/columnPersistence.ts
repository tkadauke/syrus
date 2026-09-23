import { useState } from "react"
import { visibleOptionalColumnKeys } from "./columnOrder"
import type { DataTableColumnDef, DataTableColumnPreferences } from "./types"

export function readLocalStorageColumnOrder<TRow>(storageKey: string, columns: DataTableColumnDef<TRow>[]): string[] {
  const fallback = visibleOptionalColumnKeys({ columns, order: undefined })
  try {
    const raw = window.localStorage.getItem(storageKey)
    if (!raw) return fallback

    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return fallback

    const validKeys = new Set(columns.filter((column) => !column.required).map((column) => column.key))
    const filtered = parsed.filter((key): key is string => typeof key === "string" && validKeys.has(key))
    return filtered.length > 0 || parsed.length === 0 ? filtered : fallback
  } catch {
    return fallback
  }
}

export function writeLocalStorageColumnOrder(storageKey: string, order: string[]): void {
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(order))
  } catch {
    // localStorage can be unavailable in private or restricted browser contexts.
  }
}

// A pluggable persistence adapter for surfaces that don't have a
// server-backed preference model yet: order lives in localStorage, keyed by
// a caller-provided storageKey (mirrors Repositories.tsx's prior bespoke
// picker). Surfaces with server preferences (e.g. Dashboard) build the same
// { order, onChange, pending, error } shape directly from their own
// query/mutation instead of using this hook -- DataTableColumnMenu and
// DataTableColumnHeaderRow only ever consume that shape, never a specific
// storage mechanism.
export function useLocalStorageColumnPreferences<TRow>({
  columns,
  storageKey
}: {
  columns: DataTableColumnDef<TRow>[]
  storageKey: string
}): DataTableColumnPreferences {
  const [ order, setOrder ] = useState<string[]>(() => readLocalStorageColumnOrder(storageKey, columns))

  function onChange(next: string[]) {
    setOrder(next)
    writeLocalStorageColumnOrder(storageKey, next)
  }

  return { onChange, order }
}
