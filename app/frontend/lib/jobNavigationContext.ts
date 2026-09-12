import { withRoutePrefix } from "./routing"

export type JobNavigationItem = {
  id: number
  slug: string
  path: string
  title: string
  repository?: string | null
  state?: string | null
}

export type JobNavigationContext = {
  token: string
  kind: "dashboard" | "epic"
  label: string
  items: JobNavigationItem[]
  currentJobId: number
  capturedAt: string
  sourcePath?: string
  epicId?: number
}

const STORAGE_PREFIX = "syrus.jobNavigationContext."
const MAX_ITEMS = 50

type DashboardNavigationSource = {
  id: number
  title: string
  state?: string | null
  summary_state?: string | null
  repository?: { slug?: string | null } | null
  paths: { job_path: string }
}

type EpicNavigationSource = {
  id: number
  slug: string
  title: string
  path: string
  state?: string | null
  repository_slug?: string | null
}

export function createDashboardJobNavigationContext({ currentJobId, items, label, sourcePath }: { currentJobId: number; items: DashboardNavigationSource[]; label: string; sourcePath?: string }): JobNavigationContext | null {
  const windowed = boundedWindow(items.map(dashboardNavigationItem), currentJobId)
  if (windowed.length <= 1) return null

  return {
    token: newNavigationToken(),
    kind: "dashboard",
    label,
    items: windowed,
    currentJobId,
    capturedAt: new Date().toISOString(),
    sourcePath
  }
}

export function createEpicJobNavigationContext({ currentJobId, epicId, items, label, sourcePath }: { currentJobId: number; epicId?: number; items: EpicNavigationSource[]; label: string; sourcePath?: string }): JobNavigationContext | null {
  const windowed = boundedWindow(items.map(epicNavigationItem), currentJobId)
  if (windowed.length <= 1) return null

  return {
    token: newNavigationToken(),
    kind: "epic",
    label,
    items: windowed,
    currentJobId,
    capturedAt: new Date().toISOString(),
    sourcePath,
    epicId
  }
}

export function storeJobNavigationContext(context: JobNavigationContext | null) {
  if (!context || !storageAvailable()) return null

  try {
    window.sessionStorage.setItem(storageKey(context.token), JSON.stringify(context))
    return context.token
  } catch {
    return null
  }
}

export function readJobNavigationContext(token: string | null | undefined): JobNavigationContext | null {
  if (!token || !storageAvailable()) return null

  try {
    const raw = window.sessionStorage.getItem(storageKey(token))
    if (!raw) return null
    return parseJobNavigationContext(JSON.parse(raw), token)
  } catch {
    return null
  }
}

export function jobNavigationHref(path: string, prefix: string, token: string | null, currentSearch = "") {
  const href = withRoutePrefix(path, prefix)
  const [pathname, existingSearch = ""] = href.split("?")
  const search = jobNavigationSearch(token, existingSearch || currentSearch)
  return `${pathname}${search}`
}

export function jobNavigationSearch(token: string | null, currentSearch = "") {
  const params = new URLSearchParams(currentSearch)
  const tab = params.get("tab")
  const next = new URLSearchParams()
  if (tab) next.set("tab", tab)
  if (token) next.set("job_nav", token)
  const serialized = next.toString()
  return serialized ? `?${serialized}` : ""
}

export function navigationIndex(context: JobNavigationContext, jobId: number) {
  return context.items.findIndex((item) => item.id === jobId)
}

function dashboardNavigationItem(job: DashboardNavigationSource): JobNavigationItem {
  return {
    id: job.id,
    slug: `JOB-${job.id}`,
    path: job.paths.job_path,
    title: job.title,
    repository: job.repository?.slug ?? null,
    state: job.summary_state ?? job.state ?? null
  }
}

function epicNavigationItem(job: EpicNavigationSource): JobNavigationItem {
  return {
    id: job.id,
    slug: job.slug,
    path: job.path,
    title: job.title || job.slug,
    repository: job.repository_slug ?? null,
    state: job.state ?? null
  }
}

function boundedWindow(items: JobNavigationItem[], currentJobId: number) {
  const unique = items.filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index)
  if (unique.length <= MAX_ITEMS) return unique

  const currentIndex = unique.findIndex((item) => item.id === currentJobId)
  if (currentIndex < 0) return unique.slice(0, MAX_ITEMS)

  const before = Math.floor((MAX_ITEMS - 1) / 2)
  const start = Math.max(0, Math.min(currentIndex - before, unique.length - MAX_ITEMS))
  return unique.slice(start, start + MAX_ITEMS)
}

function parseJobNavigationContext(value: unknown, token: string): JobNavigationContext | null {
  if (!value || typeof value !== "object") return null
  const context = value as Partial<JobNavigationContext>
  if (context.token !== token) return null
  if (context.kind !== "dashboard" && context.kind !== "epic") return null
  if (typeof context.label !== "string" || !Array.isArray(context.items)) return null
  if (typeof context.currentJobId !== "number" || typeof context.capturedAt !== "string") return null

  const items = context.items.filter((item): item is JobNavigationItem => (
    Boolean(item) &&
    typeof item.id === "number" &&
    typeof item.slug === "string" &&
    typeof item.path === "string" &&
    typeof item.title === "string"
  ))
  if (items.length <= 1) return null

  return { ...context, token, items } as JobNavigationContext
}

function newNavigationToken() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID()
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function storageKey(token: string) {
  return `${STORAGE_PREFIX}${token}`
}

function storageAvailable() {
  if (typeof window === "undefined") return false

  try {
    return Boolean(window.sessionStorage)
  } catch {
    return false
  }
}
