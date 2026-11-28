import { chunkWarmup } from "./chunkWarmup"
import { announceAppUpdate, reloadForAppUpdate } from "./appUpdate"

// A deploy replaces every content-hashed chunk, so a tab opened before it
// still points its lazy routes at chunk URLs the new image no longer has.
// Vite reports that as `vite:preloadError`. A failed route navigation can
// safely full-load its destination; an in-page lazy component instead keeps
// the page alive and announces the available update. The session marker keeps
// a genuinely missing chunk from repeatedly intercepting the error boundary.
const RELOAD_MARKER_KEY = "syrus:stale-chunk-reload"

function assetRevision() {
  return document.querySelector<HTMLMetaElement>('meta[name="syrus-asset-revision"]')?.content ?? ""
}

function readMarker() {
  try {
    return window.sessionStorage.getItem(RELOAD_MARKER_KEY)
  } catch {
    return null
  }
}

function writeMarker(value: string) {
  try {
    window.sessionStorage.setItem(RELOAD_MARKER_KEY, value)
    return true
  } catch {
    return false
  }
}

//
// Background warm-up (chunkWarmup.ts) fetches chunks nobody is waiting for. A
// failure while only warm-up loads are in flight must not reload the page under
// the operator: the queue stops instead, and the next on-demand load of that
// chunk fails here with a real reason to reload.
export function installStaleChunkRecovery(
  reload: (target?: string) => void = reloadForAppUpdate,
  warmup: Pick<typeof chunkWarmup, "backgroundOnlyInFlight"> = chunkWarmup
) {
  const handler = (event: Event) => {
    if (warmup.backgroundOnlyInFlight()) return
    const revision = assetRevision()
    if (readMarker() === revision) return
    // Without a writable marker a reload could loop, so leave the error to
    // the boundary.
    if (!writeMarker(revision)) return

    event.preventDefault()
    const navigationTarget = recentNavigationTarget()
    if (navigationTarget) reload(navigationTarget)
    else announceAppUpdate("stale_chunk", `chunk:${revision}`)
  }

  window.addEventListener("vite:preloadError", handler)
  return () => window.removeEventListener("vite:preloadError", handler)
}

let navigationTarget: { href: string; at: number } | null = null

export function installChunkNavigationTracking() {
  const remember = (event: MouseEvent) => {
    const anchor = (event.target as Element | null)?.closest<HTMLAnchorElement>("a[href]")
    if (!anchor || anchor.origin !== window.location.origin) return
    navigationTarget = { href: anchor.href, at: Date.now() }
  }
  document.addEventListener("click", remember, true)
  return () => document.removeEventListener("click", remember, true)
}

function recentNavigationTarget() {
  if (!navigationTarget || Date.now() - navigationTarget.at > 10_000) return null
  const target = navigationTarget.href
  navigationTarget = null
  return target
}
