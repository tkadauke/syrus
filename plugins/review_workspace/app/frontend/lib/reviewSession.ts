// Same-tab Review session store. "Defer for this session" is a local
// presentation choice, never server state: deferred Job IDs are kept per Review
// session (identified through route state) in sessionStorage so they survive
// remounts, query refetches, and same-tab reloads, while separate tabs and
// separate sessions stay isolated. When storage is unavailable the store
// degrades to in-memory state for the lifetime of the page.
import { useCallback, useMemo, useState } from "react"

export const REVIEW_SESSION_STORAGE_KEY = "syrus.review_workspace.sessions"
export const REVIEW_SESSION_STORE_VERSION = 1
export const REVIEW_SESSION_MAX_SESSIONS = 10
export const REVIEW_SESSION_MAX_IDS = 500
export const REVIEW_SESSION_TTL_MS = 12 * 60 * 60 * 1000

type SessionRecord = { ids: number[]; touchedAt: number }
type SessionStore = { version: number; sessions: Record<string, SessionRecord> }

const emptyStore = (): SessionStore => ({ version: REVIEW_SESSION_STORE_VERSION, sessions: {} })
let memoryStore: SessionStore = emptyStore()
// Once sessionStorage throws, this page keeps using the in-memory copy.
let storageUnavailable = false

function sanitize(raw: unknown): SessionStore {
  if (!raw || typeof raw !== "object") return emptyStore()
  const candidate = raw as Partial<SessionStore>
  if (candidate.version !== REVIEW_SESSION_STORE_VERSION || !candidate.sessions || typeof candidate.sessions !== "object") return emptyStore()
  const sessions: Record<string, SessionRecord> = {}
  for (const [id, record] of Object.entries(candidate.sessions)) {
    if (!record || !Array.isArray(record.ids) || typeof record.touchedAt !== "number") continue
    sessions[id] = { ids: record.ids.filter((value) => Number.isInteger(value)), touchedAt: record.touchedAt }
  }
  return { version: REVIEW_SESSION_STORE_VERSION, sessions }
}

function readStore(): SessionStore {
  if (storageUnavailable) return memoryStore
  try {
    const raw = window.sessionStorage.getItem(REVIEW_SESSION_STORAGE_KEY)
    return raw === null ? emptyStore() : sanitize(JSON.parse(raw))
  } catch (error) {
    // handled-error-expected: sessionStorage may be unavailable; fall back to in-memory state.
    if (error instanceof SyntaxError) return emptyStore()
    storageUnavailable = true
    return memoryStore
  }
}

function writeStore(store: SessionStore, keep?: string) {
  const now = Date.now()
  const entries = Object.entries(store.sessions)
    .filter(([id, record]) => id === keep || now - record.touchedAt < REVIEW_SESSION_TTL_MS)
    .sort(([, a], [, b]) => b.touchedAt - a.touchedAt)
    .slice(0, REVIEW_SESSION_MAX_SESSIONS)
  const bounded: SessionStore = { version: REVIEW_SESSION_STORE_VERSION, sessions: Object.fromEntries(entries) }
  if (keep && store.sessions[keep] && !bounded.sessions[keep]) bounded.sessions[keep] = store.sessions[keep]
  memoryStore = bounded
  try {
    window.sessionStorage.setItem(REVIEW_SESSION_STORAGE_KEY, JSON.stringify(bounded))
  } catch {
    // handled-error-expected: storage unavailable or full; the in-memory copy above keeps this page working.
    storageUnavailable = true
  }
}

export function resetReviewSessionStoreForTests() {
  memoryStore = emptyStore()
  storageUnavailable = false
}

export function createReviewSessionId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID()
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

export function readDeferredJobIds(sessionId: string): number[] {
  const record = readStore().sessions[sessionId]
  if (!record || Date.now() - record.touchedAt >= REVIEW_SESSION_TTL_MS) return []
  return record.ids
}

export function deferJobInSession(sessionId: string, jobId: number) {
  const store = readStore()
  const current = readDeferredJobIds(sessionId)
  if (current.includes(jobId)) return
  const ids = [...current, jobId].slice(-REVIEW_SESSION_MAX_IDS)
  writeStore({ ...store, sessions: { ...store.sessions, [sessionId]: { ids, touchedAt: Date.now() } } }, sessionId)
}

export function clearReviewSession(sessionId: string) {
  const store = readStore()
  if (!store.sessions[sessionId]) return
  const { [sessionId]: _removed, ...rest } = store.sessions
  writeStore({ ...store, sessions: rest })
}

// Drops deferred IDs that are no longer eligible. Returns true when anything changed.
export function pruneSessionDeferrals(sessionId: string, eligibleJobIds: number[]) {
  const current = readDeferredJobIds(sessionId)
  const eligible = new Set(eligibleJobIds)
  const ids = current.filter((id) => eligible.has(id))
  if (ids.length === current.length) return false
  const store = readStore()
  if (ids.length === 0) clearReviewSession(sessionId)
  else writeStore({ ...store, sessions: { ...store.sessions, [sessionId]: { ids, touchedAt: Date.now() } } }, sessionId)
  return true
}

export function useReviewSessionDeferrals(sessionId: string) {
  const [version, setVersion] = useState(0)
  const deferred = useMemo(() => new Set(readDeferredJobIds(sessionId)), [sessionId, version])
  const defer = useCallback(
    (jobId: number) => {
      deferJobInSession(sessionId, jobId)
      setVersion((current) => current + 1)
    },
    [sessionId]
  )
  const prune = useCallback(
    (eligibleJobIds: number[]) => {
      if (pruneSessionDeferrals(sessionId, eligibleJobIds)) setVersion((current) => current + 1)
    },
    [sessionId]
  )
  const clear = useCallback(() => clearReviewSession(sessionId), [sessionId])
  return { deferred, defer, prune, clear }
}
