import { useEffect, useRef } from "react"

// Shared deep-link anchor helpers for syrus_dev's admin catalogs (Tool Card
// Catalog, Artifact Renderer Catalog). Each catalog entry gets a stable DOM
// id so a `?tool=...`/`?renderer=...` query param plus a `#anchor` hash can
// link straight to one entry -- `catalogAnchorId` builds that id and
// `useCatalogDeepLinkScroll` scrolls to it once, the first time it becomes
// available (e.g. after the entry list has rendered).

export function catalogAnchorId(prefix: string, key: string) {
  return `${prefix}-${key.replace(/[^a-zA-Z0-9_-]/g, "_")}`
}

// `recomputeTrigger` re-runs the effect when the visible entry list changes
// shape (e.g. a filter narrows/widens results) without needing the caller
// to track scroll state itself; scrolling only ever happens once per
// distinct `elementId`, tracked via `scrolledToRef`.
export function useCatalogDeepLinkScroll(elementId: string | null, recomputeTrigger: unknown) {
  const scrolledToRef = useRef<string | null>(null)

  useEffect(() => {
    if (!elementId || scrolledToRef.current === elementId) return
    const element = document.getElementById(elementId)
    if (!element) return

    element.scrollIntoView({ block: "start" })
    scrolledToRef.current = elementId
  }, [elementId, recomputeTrigger])
}
