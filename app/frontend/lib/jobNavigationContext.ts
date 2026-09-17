import { withRoutePrefix } from "./routing"

export type JobNavigationOwnerBadge = {
  label: string
  kind: string
}

export type JobNavigationItem = {
  id: number
  slug: string
  path: string
  title: string
  repository?: string | null
  state?: string | null
  ownerBadge?: JobNavigationOwnerBadge | null
  updatedAt?: string | null
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
const KNOWN_STATE_PREFIX = "syrus.jobNavigationKnownState."
const MAX_ITEMS = 50

type JobNavigationKnownState = {
  state: string | null
  updatedAt: string | null
}

type DashboardNavigationSource = {
  id: number
  title: string
  state?: string | null
  summary_state?: string | null
  repository?: { slug?: string | null; multiple_members?: boolean } | null
  owner_badge?: JobNavigationOwnerBadge | null
  updated_at?: string | null
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
    const context = parseJobNavigationContext(JSON.parse(raw), token)
    if (!context) return null
    return { ...context, items: context.items.map(overlayKnownJobState) }
  } catch {
    return null
  }
}

// A captured navigation context is a point-in-time snapshot, so its `state`
// goes stale as soon as the job changes elsewhere. Every JobDetailView mount
// records the live state for the job it's actually displaying, and both this
// overlay and `patchJobNavigationContextItem` pull from that per-job record
// so previously-visited (or currently-visited) jobs stay accurate for as
// long as the snapshot itself lives in sessionStorage.
export function recordJobNavigationKnownState(id: number, state: string | null | undefined, updatedAt?: string | null) {
  if (!storageAvailable()) return

  try {
    window.sessionStorage.setItem(knownStateKey(id), JSON.stringify({
      state: state ?? null,
      updatedAt: updatedAt ?? null
    }))
  } catch {
    // Storage can be unavailable (quota, private browsing); the switcher
    // simply keeps showing its last captured state.
  }
}

export function patchJobNavigationContextItem(context: JobNavigationContext | null, id: number, state: string | null | undefined, updatedAt?: string | null): JobNavigationContext | null {
  if (!context) return context

  let changed = false
  const items = context.items.map((item) => {
    if (item.id !== id) return item

    const nextState = state ?? null
    const nextUpdatedAt = updatedAt ?? item.updatedAt ?? null
    if (item.state === nextState && item.updatedAt === nextUpdatedAt) return item

    changed = true
    return { ...item, state: nextState, updatedAt: nextUpdatedAt }
  })

  return changed ? { ...context, items } : context
}

function overlayKnownJobState(item: JobNavigationItem): JobNavigationItem {
  const known = readJobNavigationKnownState(item.id)
  if (!known) return item
  if (known.state === item.state && known.updatedAt === item.updatedAt) return item

  return { ...item, state: known.state, updatedAt: known.updatedAt ?? item.updatedAt }
}

function readJobNavigationKnownState(id: number): JobNavigationKnownState | null {
  if (!storageAvailable()) return null

  try {
    const raw = window.sessionStorage.getItem(knownStateKey(id))
    if (!raw) return null

    const parsed = JSON.parse(raw) as Partial<JobNavigationKnownState>
    if (!parsed || typeof parsed !== "object") return null

    return {
      state: typeof parsed.state === "string" ? parsed.state : null,
      updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : null
    }
  } catch {
    return null
  }
}

function knownStateKey(id: number) {
  return `${KNOWN_STATE_PREFIX}${id}`
}

export function jobNavigationHref(path: string, prefix: string, token: string | null, currentSearch = "", currentPathname = "") {
  const href = withRoutePrefix(path, prefix)
  const [pathname, existingSearch = ""] = href.split("?")
  const targetPathname = currentJobDetailSubroute(currentPathname, prefix) === "source" && !pathname.endsWith("/source")
    ? `${pathname}/source`
    : pathname
  const search = jobNavigationSearch(token, existingSearch || currentSearch)
  return `${targetPathname}${search}`
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
    state: job.summary_state ?? job.state ?? null,
    ownerBadge: job.repository?.multiple_members ? job.owner_badge ?? null : null,
    updatedAt: job.updated_at ?? null
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

function currentJobDetailSubroute(pathname: string, prefix: string) {
  const unprefixed = prefix && pathname.startsWith(prefix) ? pathname.slice(prefix.length) : pathname
  return /^\/jobs\/[^/]+\/source\/?$/.test(unprefixed) ? "source" : null
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
