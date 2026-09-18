import type { FilterLinkBuilder, FilterTree } from "@app/components/FilterBar"

// Shared client-side filter wiring for syrus_dev's admin catalogs (Tool Card
// Catalog, Artifact Renderer Catalog). Both catalogs read a purely
// client-side, compiled registry -- there is no backend endpoint or
// persisted filter state, so filtering happens against an in-memory entry
// list rather than through Filters::Subject (which exists for
// ActiveRecord-backed collections). FilterBar itself is still the shared
// chip-bar UI; only the "apply the filter" half is local, mirroring the
// pattern ChatSearch.tsx already uses for its own entirely-client-evaluated
// flat filters.
//
// FilterBar's chip UI only speaks its own base64 `q=<tree>` wire format;
// each catalog's filter state is flat query params instead (so a shared
// link is readable and other deep-link params stay independent of the
// filter tree encoding). `buildCatalogFilterLink` decodes `q` back into
// flat params for the given field list.

export function catalogFiltersFromSearch<F extends string>(fields: readonly F[], search: string): Partial<Record<F, string>> {
  const params = new URLSearchParams(search)
  const filters: Partial<Record<F, string>> = {}
  for (const field of fields) {
    const value = params.get(field)?.trim()
    if (value) filters[field] = value
  }
  return filters
}

// `containsFields` are rendered as a "contains" chip (free-text search);
// every other field is rendered as an "is" chip (exact match).
export function catalogFilterTreeFromSearch<F extends string>(fields: readonly F[], containsFields: readonly F[], search: string): FilterTree {
  const filters = catalogFiltersFromSearch(fields, search)
  const and = fields.flatMap((field) => {
    const value = filters[field]
    return value ? [ { field, op: containsFields.includes(field) ? "contains" : "is", value } ] : []
  })
  return { and }
}

export function decodeFilterChips(encoded: string): Array<{ field: string; value: string }> {
  try {
    const standard = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const parsed = JSON.parse(atob(standard)) as { and?: unknown[] }
    return (parsed.and || []).flatMap((node) => {
      if (!node || typeof node !== "object" || !("field" in node) || !("value" in node)) return []
      const field = String((node as { field: unknown }).field)
      const value = (node as { value: unknown }).value
      return typeof value === "string" && value ? [ { field, value } ] : []
    })
  } catch {
    return []
  }
}

export function buildCatalogFilterLink<F extends string>(fields: readonly F[]): FilterLinkBuilder {
  return (path, search, updates) => {
    const params = new URLSearchParams(search)
    const encodedFilter = updates.q

    for (const [ key, value ] of Object.entries(updates)) {
      if (key === "q") continue
      if (value == null || String(value).length === 0) params.delete(key)
      else params.set(key, String(value))
    }

    if (typeof encodedFilter === "string" && encodedFilter.length > 0) {
      for (const field of fields) params.delete(field)
      for (const chip of decodeFilterChips(encodedFilter)) {
        if ((fields as readonly string[]).includes(chip.field) && chip.value) params.set(chip.field, chip.value)
      }
    } else if (encodedFilter == null) {
      for (const field of fields) params.delete(field)
    }

    const query = params.toString()
    return query ? `${path}?${query}` : path
  }
}
