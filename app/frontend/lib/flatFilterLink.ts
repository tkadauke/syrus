import type { FilterLinkBuilder } from "../components/FilterBar"

export function decodeFlatFilterChips(encoded: string): Array<{ field: string; value: string }> | null {
  try {
    const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const standard = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
    const parsed = JSON.parse(atob(standard)) as { and?: unknown[] }
    const nodes = parsed.and || []
    const chips: Array<{ field: string; value: string }> = []
    for (const node of nodes) {
      if (!node || typeof node !== "object" || !("field" in node) || !("value" in node)) return null
      const field = String((node as { field: unknown }).field)
      const value = (node as { value: unknown }).value
      if (typeof value !== "string" || !value) return null
      chips.push({ field, value })
    }
    return chips
  } catch {
    return null
  }
}

export function buildFlatFilterLink(fields: readonly string[], onDecoded?: (params: URLSearchParams) => void): FilterLinkBuilder {
  return (path, search, updates) => {
    const params = new URLSearchParams(search)
    const encodedFilter = updates.q
    const decodedChips = typeof encodedFilter === "string" && encodedFilter.length > 0 ? decodeFlatFilterChips(encodedFilter) : undefined
    const unsupportedEncodedFilter = decodedChips === null

    for (const [key, value] of Object.entries(updates)) {
      if (key === "q") continue
      if (unsupportedEncodedFilter && fields.includes(key)) continue
      if (value == null || String(value).length === 0) params.delete(key)
      else params.set(key, String(value))
    }

    if (typeof encodedFilter === "string" && encodedFilter.length > 0) {
      if (!decodedChips) {
        const query = params.toString()
        return query ? `${path}?${query}` : path
      }

      for (const field of fields) params.delete(field)
      for (const chip of decodedChips) {
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
