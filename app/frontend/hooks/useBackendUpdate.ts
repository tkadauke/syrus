// The ONE place the SPA reads "the desktop shell is updating the local
// backend right now". While a backend update recreates the containers the
// backend is DELIBERATELY unreachable for a minute or two; every query
// against it fails. Surfaces that decide between "configured" and "not
// configured" from those checks (readiness banners, credential modals, setup
// empty states) gate on useBackendOutage so a failed check during that
// window never renders as absence — the field failure: a user was told their
// GitHub token was gone (it sat safely in the DB) while containers were
// being recreated.
//
// Gating keys off `outage`, not mere update presence: containers are only
// recreated from the stack_up step on, so during the (long) image pull the
// OLD backend still serves requests and the credential flows keep working.
// The sidebar notice (ShellNotices) shows for the whole update regardless.
//
// Fed by the same window.syrusShell bridge state ShellNotices renders
// (shell:state-changed), but held in a module-level store so any number of
// consumers share one bridge subscription. Plain browsers (and older shells
// without the backendUpdate member) never see a non-null value — the store
// stays inert at zero cost.

import { useSyncExternalStore } from "react"
import { syrusShellBridge, type SyrusBackendUpdate, type SyrusShellState } from "../lib/desktopShell"

// Staleness bound: if the bridge goes silent for this long while an update
// is supposedly in flight, drop the state (and with it the gating) even
// though the shell never cleared it. Defense in depth against a shell whose
// update wedged before its own main-process deadline — indefinitely
// suppressed readiness warnings would be worse than a transient scare. The
// longest legitimately silent stretch (the health/migration wait) is ~3
// minutes, comfortably under this.
export const BACKEND_UPDATE_STALE_MS = 5 * 60 * 1000

let snapshot: SyrusBackendUpdate | null = null
let started = false
let staleTimer: ReturnType<typeof setTimeout> | null = null
const listeners = new Set<() => void>()

function clearStaleTimer() {
  if (staleTimer !== null) {
    clearTimeout(staleTimer)
    staleTimer = null
  }
}

function publish(next: SyrusBackendUpdate | null) {
  // Every delivered non-null state is proof of life — (re)arm the staleness
  // fuse; a null state defuses it.
  clearStaleTimer()
  if (next) {
    staleTimer = setTimeout(() => {
      staleTimer = null
      publish(null)
    }, BACKEND_UPDATE_STALE_MS)
  }

  const changed = next?.phase !== snapshot?.phase || next?.percent !== snapshot?.percent || next?.outage !== snapshot?.outage
  if (!changed) return

  snapshot = next
  for (const listener of listeners) listener()
}

function start() {
  if (started) return
  started = true

  const bridge = syrusShellBridge()
  if (!bridge) return

  let sawEvent = false
  bridge.onStateChanged((state: SyrusShellState) => {
    sawEvent = true
    publish(state.backendUpdate ?? null)
  })
  // Deliberately never unsubscribed: the store lives as long as the page.
  void bridge
    .getState()
    .then((state) => {
      // A state-changed event that lands before this snapshot resolves is
      // fresher than the snapshot — never clobber it with stale data.
      if (!sawEvent) publish(state.backendUpdate ?? null)
    })
    .catch(() => {
      // A misbehaving bridge simply reports "not updating".
    })
}

function subscribe(listener: () => void) {
  start()
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

function getSnapshot() {
  return snapshot
}

// The in-flight backend update (phase + pull percent + outage), or null when
// none. The full state; gating surfaces want useBackendOutage instead.
export function useBackendUpdate(): SyrusBackendUpdate | null {
  return useSyncExternalStore(subscribe, getSnapshot)
}

// The boolean the gating surfaces key off: true only while the update has
// actually taken the backend down (container recreation + migrations),
// never during the image pull.
export function useBackendOutage(): boolean {
  return useBackendUpdate()?.outage ?? false
}

// Test seams: the store is module-global, so specs that install a fresh
// window.syrusShell mock must drop the previous subscription, snapshot, and
// staleness fuse — and the unsubscribe path is only observable through the
// listener count.
export function resetBackendUpdateStoreForTests() {
  snapshot = null
  started = false
  clearStaleTimer()
  listeners.clear()
}

export function backendUpdateListenerCountForTests() {
  return listeners.size
}
