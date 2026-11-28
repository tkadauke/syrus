import { chunkWarmup } from "./chunkWarmup"
import { reloadPage } from "./pageReload"
import { recordStartupEvent } from "./startupDiagnostics"

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

//
// Background warm-up (chunkWarmup.ts) fetches chunks nobody is waiting for. A
// failure while only warm-up loads are in flight must not reload the page under
// the operator: the queue stops instead, and the next on-demand load of that
// chunk fails here with a real reason to reload.
export function installStaleChunkRecovery(
  reload: (reason?: string) => void = reloadPage,
  warmup: Pick<typeof chunkWarmup, "backgroundOnlyInFlight"> = chunkWarmup
) {
  const handler = (event: Event) => {
    if (warmup.backgroundOnlyInFlight()) {
      recordStartupEvent("stale_chunk_failure", { outcome: "warmup_stopped" })
      return
    }
    const revision = assetRevision()
    if (readMarker() === revision) {
      recordStartupEvent("stale_chunk_failure", { outcome: "error_boundary", revision })
      return
    }
    // Without a writable marker a reload could loop, so leave the error to
    // the boundary.
    if (!writeMarker(revision)) {
      recordStartupEvent("stale_chunk_failure", { outcome: "error_boundary", revision })
      return
    }

    event.preventDefault()
    recordStartupEvent("stale_chunk_failure", { outcome: "reload", revision })
    reload("stale_chunk_recovery")
  }

  window.addEventListener("vite:preloadError", handler)
  return () => window.removeEventListener("vite:preloadError", handler)
}
