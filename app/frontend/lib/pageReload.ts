const RELOAD_BREADCRUMB_KEY = "syrus:reload-breadcrumb"

export type ReloadBreadcrumb = {
  reason: string
  at: string
  path: string
}

let cachedReloadBreadcrumb: ReloadBreadcrumb | null | undefined

export function reloadPage(reason = "app_requested", reload: () => void = () => window.location.reload()) {
  try {
    window.sessionStorage.setItem(RELOAD_BREADCRUMB_KEY, JSON.stringify({ reason, at: new Date().toISOString(), path: window.location.pathname }))
  } catch {
    // Reload remains available when storage is disabled.
  }
  reload()
}

export function readReloadBreadcrumb(): ReloadBreadcrumb | null {
  if (cachedReloadBreadcrumb !== undefined) return cachedReloadBreadcrumb
  try {
    const value = window.sessionStorage.getItem(RELOAD_BREADCRUMB_KEY)
    window.sessionStorage.removeItem(RELOAD_BREADCRUMB_KEY)
    if (!value) return (cachedReloadBreadcrumb = null)
    const parsed = JSON.parse(value) as Partial<ReloadBreadcrumb>
    if (typeof parsed.reason !== "string" || typeof parsed.at !== "string" || typeof parsed.path !== "string") return (cachedReloadBreadcrumb = null)
    return (cachedReloadBreadcrumb = parsed as ReloadBreadcrumb)
  } catch {
    return (cachedReloadBreadcrumb = null)
  }
}

export function resetReloadBreadcrumbForTests() {
  cachedReloadBreadcrumb = undefined
}
