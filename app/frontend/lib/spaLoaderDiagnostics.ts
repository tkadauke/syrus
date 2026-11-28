import { chunkWarmup, type ChunkWarmupSnapshot } from "./chunkWarmup"
import type { StartupDiagnosticsSnapshot } from "./startupDiagnostics"

export type SpaLoaderDiagnosticsSnapshot = {
  warmup: ChunkWarmupSnapshot
  startup: StartupDiagnosticsSnapshot | null
}

const listeners = new Set<() => void>()
let stopWarmup: (() => void) | null = null
let stopStartup: (() => void) | null = null
let cachedSnapshot: SpaLoaderDiagnosticsSnapshot | null = null

function readSnapshot(): SpaLoaderDiagnosticsSnapshot {
  const startup = window.SyrusStartupDiagnostics?.snapshot?.() ?? null
  const warmup = chunkWarmup.snapshot()
  if (startup) {
    warmup.entries.forEach((entry) => {
      entry.size = entry.manifestKey ? (startup.lazy_chunks?.[entry.manifestKey]?.size ?? null) : null
    })
  }
  return { warmup, startup }
}

function emit() {
  cachedSnapshot = readSnapshot()
  listeners.forEach((listener) => listener())
}

export const spaLoaderDiagnostics = {
  snapshot(): SpaLoaderDiagnosticsSnapshot {
    return (cachedSnapshot ??= readSnapshot())
  },
  subscribe(listener: () => void) {
    listeners.add(listener)
    if (listeners.size === 1) {
      cachedSnapshot = readSnapshot()
      stopWarmup = chunkWarmup.subscribe(emit)
      stopStartup = window.SyrusStartupDiagnostics?.subscribe?.(emit) ?? null
    }
    return () => {
      listeners.delete(listener)
      if (listeners.size === 0) {
        stopWarmup?.()
        stopStartup?.()
        stopWarmup = null
        stopStartup = null
        cachedSnapshot = null
      }
    }
  },
  warmEverythingNow() {
    chunkWarmup.warmEverythingNow()
  },
  clearWarmupState() {
    chunkWarmup.clearWarmupState()
  }
}
