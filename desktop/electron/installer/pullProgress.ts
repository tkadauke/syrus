// Aggregates `docker compose --progress=json pull` NDJSON into one overall
// percentage for the onboarding installer. In --json mode install.sh forwards
// compose's raw per-layer progress objects as log lines — hundreds of
// near-identical JSON blobs that would drown the visible log. The driver
// feeds each line through parsePullProgressLine + PullProgressAggregator and
// shows a single human summary ("Downloading Syrus image — 42% (312 MB /
// 745 MB)") instead. Older compose versions ignore --progress=json and print
// plain text; those lines don't parse here and flow to the log unchanged, so
// the UI degrades to the spinner-only experience.
//
// Pure module by design: no electron/node imports, so renderer-side vitest
// (desktop/src/pullProgress.test.ts) can exercise it directly.

export type PullProgressEvent = {
  id: string
  text: string
  status: string
  current: number | null
  total: number | null
}

export type PullProgressSnapshot = {
  // 0–100 integer, or null before any layer has been seen.
  percent: number | null
  // Byte counts across layers with known totals; null when no totals have
  // appeared (layer-count fallback mode).
  downloadedBytes: number | null
  totalBytes: number | null
}

// Compose emits image/container/network-level rows on the same stream as
// layer rows ({"id":"Image ghcr.io/…","text":"Pulling"}). Only layer rows
// carry byte progress; the rest would skew the layer count.
const NON_LAYER_ID_PREFIXES = ["Image ", "Container ", "Network ", "Volume "]

// Layer end states. "Download complete" precedes "Extracting"/"Pull
// complete" but the bytes are all on disk, which is what the bar measures.
const DONE_TEXTS = new Set(["Already exists", "Download complete", "Pull complete"])

// Layer-count fallback mode (no byte totals) can only guess. Early cached
// layers ("Already exists") arrive before the real download rows, so a naive
// done/known ratio computes ~100% while multi-GB layers haven't even been
// announced yet. Until the image-level terminal event confirms the pull is
// actually finished, the fallback never claims more than this.
const FALLBACK_MAX_PERCENT = 99

const finiteNumber = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null

// One raw stdout line → a compose pull progress event, or null when the line
// is anything else (plain text from older compose, malformed JSON, JSON that
// isn't a progress object). Null means "not ours — log it normally".
export const parsePullProgressLine = (line: string): PullProgressEvent | null => {
  const trimmed = line.trim()
  if (!trimmed.startsWith("{")) {
    return null
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch {
    return null
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null
  }

  const record = parsed as Record<string, unknown>
  if (typeof record.id !== "string" || record.id === "") {
    return null
  }

  const text = typeof record.text === "string" ? record.text : ""
  const status = typeof record.status === "string" ? record.status : ""
  if (text === "" && status === "") {
    return null
  }

  return {
    id: record.id,
    text,
    status,
    current: finiteNumber(record.current),
    total: finiteNumber(record.total)
  }
}

type LayerState = {
  current: number
  total: number
  done: boolean
}

type PercentMode = "bytes" | "fallback"

export class PullProgressAggregator {
  private layers = new Map<string, LayerState>()
  private maxPercent: number | null = null
  private mode: PercentMode | null = null
  // Image-level parent rows seen / finished ({"id":"Image …"} with
  // text "Pulled" or status "Done" meaning finished). The pull counts as
  // done only when EVERY announced image is done — the desktop stack pulls
  // one image today, but a small side image finishing first must never
  // pretend the big one is done.
  private imagesSeen = new Set<string>()
  private imagesDone = new Set<string>()

  // Only past this gate may the layer-count fallback report 100%.
  private imagesAllDone(): boolean {
    return this.imagesDone.size > 0 && this.imagesDone.size === this.imagesSeen.size
  }

  observe(event: PullProgressEvent): void {
    if (NON_LAYER_ID_PREFIXES.some((prefix) => event.id.startsWith(prefix))) {
      // Parent rows carry no byte progress, but the image-level terminal
      // event ("Pulled"/Done) is the only trustworthy "actually finished"
      // signal in fallback mode.
      if (event.id.startsWith("Image ")) {
        this.imagesSeen.add(event.id)
        if (event.text === "Pulled" || event.status === "Done") {
          this.imagesDone.add(event.id)
        }
      }
      return
    }

    const layer = this.layers.get(event.id) ?? { current: 0, total: 0, done: false }

    if (DONE_TEXTS.has(event.text)) {
      layer.done = true
      if (event.total !== null && event.total > 0 && layer.total === 0) {
        layer.total = event.total
      }
      if (layer.total > 0) {
        layer.current = layer.total
      }
    } else if (event.text === "Downloading" && !layer.done) {
      if (event.total !== null && event.total > 0) {
        layer.total = event.total
      }
      if (event.current !== null) {
        layer.current = layer.total > 0 ? Math.min(event.current, layer.total) : event.current
      }
    }
    // "Pulling fs layer" / "Waiting" / "Verifying Checksum" / "Extracting":
    // register the layer (grows the known-layer denominator) but take no byte
    // counts — extraction reports uncompressed sizes, a different denominator
    // that would make the bar jump around.

    this.layers.set(event.id, layer)
  }

  snapshot(): PullProgressSnapshot {
    let downloadedBytes = 0
    let totalBytes = 0
    let doneLayers = 0

    for (const layer of this.layers.values()) {
      if (layer.total > 0) {
        totalBytes += layer.total
        downloadedBytes += Math.min(layer.current, layer.total)
      }
      if (layer.done) {
        doneLayers += 1
      }
    }

    let rawPercent: number | null = null
    let mode: PercentMode | null = null
    if (totalBytes > 0) {
      mode = "bytes"
      rawPercent = (downloadedBytes / totalBytes) * 100
    } else if (this.layers.size > 0) {
      // No byte totals at all (e.g. every layer "Already exists"): fall back
      // to completed-layers over known-layers. This is a guess — cached
      // layers stream in first, so the ratio can hit 100% before the real
      // download rows are even announced. Cap it below 100 until the
      // image-level terminal event confirms the pull truly finished.
      mode = "fallback"
      rawPercent = (doneLayers / this.layers.size) * 100
      if (!this.imagesAllDone()) {
        rawPercent = Math.min(rawPercent, FALLBACK_MAX_PERCENT)
      }
    }

    // The first byte totals may arrive after fallback mode already reported
    // a high guess. Real data beats the guess: drop the clamp once so the
    // percent can correct downward (a one-time visible dip beats a bar
    // frozen at a false ~100%). Monotonicity still holds WITHIN each mode.
    if (mode === "bytes" && this.mode === "fallback") {
      this.maxPercent = null
    }
    if (mode !== null) {
      this.mode = mode
    }

    // Monotonic clamp: newly discovered layers grow the denominator, which
    // would otherwise pull the shown percent backwards.
    let percent = this.maxPercent
    if (rawPercent !== null) {
      const bounded = Math.max(0, Math.min(100, Math.floor(rawPercent)))
      percent = this.maxPercent === null ? bounded : Math.max(this.maxPercent, bounded)
      this.maxPercent = percent
    }

    return {
      percent,
      downloadedBytes: totalBytes > 0 ? downloadedBytes : null,
      totalBytes: totalBytes > 0 ? totalBytes : null
    }
  }
}

// Decimal units to match what docker's own CLI shows for the same pull.
export const formatByteSize = (bytes: number): string => {
  if (bytes >= 1_000_000_000) {
    return `${(bytes / 1_000_000_000).toFixed(1)} GB`
  }

  return `${Math.round(bytes / 1_000_000)} MB`
}

// The short display label the renderer shows next to the bar — "42% (312 MB
// / 745 MB)", or just "42%" in layer-count fallback mode. Null while no
// percent is known (the UI keeps its spinner).
export const formatPullProgress = (snapshot: PullProgressSnapshot): string | null => {
  if (snapshot.percent === null) {
    return null
  }

  if (snapshot.downloadedBytes !== null && snapshot.totalBytes !== null) {
    return `${snapshot.percent}% (${formatByteSize(snapshot.downloadedBytes)} / ${formatByteSize(snapshot.totalBytes)})`
  }

  return `${snapshot.percent}%`
}
