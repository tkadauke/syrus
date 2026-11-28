export const APP_UPDATE_EVENT = "syrus:app-update"
export const SAVE_DRAFTS_EVENT = "syrus:save-drafts"

const DISMISSED_STORAGE_KEY = "syrus:dismissed-app-update"
export const BREAKING_UPDATE_COUNTDOWN_SECONDS = 30

export type AppUpdateKind = "compatible" | "breaking" | "stale_chunk"

export type AppUpdate = {
  id: string
  kind: AppUpdateKind
  detectedAt: number
  deadline: number | null
}

let currentUpdate: AppUpdate | null = null
let countdownTimer: number | null = null
let reloadImplementation = (target: string) => window.location.assign(target)

function storage(): Storage | null {
  try {
    return window.sessionStorage
  } catch {
    // handled-error-expected: Storage access is optional in hardened browser modes.
    return null
  }
}

function publish(update: AppUpdate) {
  currentUpdate = update
  window.dispatchEvent(new CustomEvent<AppUpdate>(APP_UPDATE_EVENT, { detail: update }))
}

function requestServiceWorkerUpdate() {
  if (!("serviceWorker" in navigator)) return
  void navigator.serviceWorker
    .getRegistration()
    .then((registration) => registration?.update())
    .catch(() => {
      // handled-error-expected: An update check must not disrupt the current page.
    })
}

export function announceAppUpdate(kind: AppUpdateKind, id: string): AppUpdate {
  const existing = readAppUpdate()
  if (existing?.kind === "breaking") return existing
  if (existing?.id === id && existing.kind === kind) return existing

  const detectedAt = Date.now()
  const update: AppUpdate = {
    id,
    kind,
    detectedAt,
    deadline: kind === "breaking" ? detectedAt + BREAKING_UPDATE_COUNTDOWN_SECONDS * 1000 : null
  }
  if (kind === "breaking") window.dispatchEvent(new Event(SAVE_DRAFTS_EVENT))
  publish(update)
  requestServiceWorkerUpdate()
  scheduleBreakingReload(update)
  return update
}

export function readAppUpdate(): AppUpdate | null {
  return currentUpdate
}

export function appUpdateBlocksRetries(): boolean {
  return currentUpdate?.kind === "breaking"
}

export function dismissAppUpdate(id: string) {
  try {
    storage()?.setItem(DISMISSED_STORAGE_KEY, id)
  } catch {
    // handled-error-expected: Dismissal is best effort when storage is unavailable.
  }
  window.dispatchEvent(new CustomEvent<AppUpdate | null>(APP_UPDATE_EVENT, { detail: currentUpdate ? { ...currentUpdate } : null }))
}

export function appUpdateIsDismissed(update: AppUpdate): boolean {
  try {
    return storage()?.getItem(DISMISSED_STORAGE_KEY) === update.id
  } catch {
    // handled-error-expected: Without storage the notice remains visible.
    return false
  }
}

export function reloadForAppUpdate(target = window.location.href) {
  reloadImplementation(target)
}

function scheduleBreakingReload(update: AppUpdate) {
  if (update.kind !== "breaking" || update.deadline == null || countdownTimer != null) return
  countdownTimer = window.setTimeout(
    () => {
      countdownTimer = null
      reloadForAppUpdate()
    },
    Math.max(0, update.deadline - Date.now())
  )
}

function targetFromHistoryArgument(url: string | URL | null | undefined): string {
  return url == null ? window.location.href : new URL(String(url), window.location.href).href
}

export function installReloadOnNavigation() {
  const click = (event: MouseEvent) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const anchor = (event.target as Element | null)?.closest<HTMLAnchorElement>("a[href]")
    if (!anchor || anchor.target || anchor.hasAttribute("download") || anchor.origin !== window.location.origin) return
    if (!readAppUpdate()) return
    event.preventDefault()
    event.stopImmediatePropagation()
    reloadForAppUpdate(anchor.href)
  }
  document.addEventListener("click", click, true)

  const pushState = history.pushState.bind(history)
  const replaceState = history.replaceState.bind(history)
  history.pushState = (data, unused, url) => {
    if (readAppUpdate()) return reloadForAppUpdate(targetFromHistoryArgument(url)) as never
    return pushState(data, unused, url)
  }
  history.replaceState = (data, unused, url) => {
    if (readAppUpdate()) return reloadForAppUpdate(targetFromHistoryArgument(url)) as never
    return replaceState(data, unused, url)
  }
  const popstate = () => {
    if (readAppUpdate()) reloadForAppUpdate()
  }
  window.addEventListener("popstate", popstate)

  return () => {
    document.removeEventListener("click", click, true)
    window.removeEventListener("popstate", popstate)
    history.pushState = pushState
    history.replaceState = replaceState
  }
}

export function resetAppUpdateForTests() {
  currentUpdate = null
  if (countdownTimer != null) window.clearTimeout(countdownTimer)
  countdownTimer = null
  reloadImplementation = (target) => window.location.assign(target)
}

export function setAppUpdateReloaderForTests(reload: (target: string) => void) {
  reloadImplementation = reload
}
