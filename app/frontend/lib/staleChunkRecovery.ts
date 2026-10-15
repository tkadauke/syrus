import { reloadPage } from "./pageReload"

// A deploy replaces every content-hashed chunk, so a tab opened before it
// still points its lazy routes at chunk URLs the new image no longer has.
// Vite reports that as `vite:preloadError`; reloading picks up the current
// shell and its chunk graph. The sessionStorage marker, keyed by the asset
// revision the shell was rendered with, allows one reload per revision so a
// chunk that is genuinely missing from the current build surfaces in the
// error boundary instead of reloading forever.
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

export function installStaleChunkRecovery(reload: () => void = reloadPage) {
  const handler = (event: Event) => {
    const revision = assetRevision()
    if (readMarker() === revision) return
    // Without a writable marker a reload could loop, so leave the error to
    // the boundary.
    if (!writeMarker(revision)) return

    event.preventDefault()
    reload()
  }

  window.addEventListener("vite:preloadError", handler)
  return () => window.removeEventListener("vite:preloadError", handler)
}
