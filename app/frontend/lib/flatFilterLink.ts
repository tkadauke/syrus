import type { FilterLinkBuilder } from "../components/FilterBar"

export function decodeFlatFilterChips(encoded: string): Array<{ field: string; value: string }> {
  try {
    const standard = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const parsed = JSON.parse(atob(standard)) as { and?: unknown[] }
    return (parsed.and || []).flatMap((node) => {
      if (!node || typeof node !== "object" || !("field" in node) || !("value" in node)) return []
      const field = String((node as { field: unknown }).field)
      const value = (node as { value: unknown }).value
      return typeof value === "string" && value ? [{ field, value }] : []
    })
  } catch {
    return []
  }
}

export function buildFlatFilterLink(fields: readonly string[], onDecoded?: (params: URLSearchParams) => void): FilterLinkBuilder {
  return (path, search, updates) => {
    const params = new URLSearchParams(search)
    const encodedFilter = updates.q

    for (const [key, value] of Object.entries(updates)) {
      if (key === "q") continue
      if (value == null || String(value).length === 0) params.delete(key)
      else params.set(key, String(value))
    }

    if (typeof encodedFilter === "string" && encodedFilter.length > 0) {
      for (const field of fields) params.delete(field)
      for (const chip of decodeFlatFilterChips(encodedFilter)) {
        if (fields.includes(chip.field) && chip.value) params.set(chip.field, chip.value)
      }
      onDecoded?.(params)
    } else if (encodedFilter == null) {
      for (const field of fields) params.delete(field)
      onDecoded?.(params)
    }

    const query = params.toString()
    return query ? `${path}?${query}` : path
  }
}
