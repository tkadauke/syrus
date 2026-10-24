import { useEffect } from "react"
import { useLocation } from "react-router-dom"

const IDLE_AFTER_MS = 60_000
const TICK_MS = 1_000

type EngagementRoute = { route_id: "job.show" | "job.review" | "chat.show"; route_params: Record<string, string> }
type Clock = { now: () => number; wallNow: () => number }

export function engagementRoute(pathname: string, search: string): EngagementRoute | null {
  const path = pathname.replace(/^\/app-shell/, "") || "/"
  const job = path.match(/^\/jobs\/([1-9]\d*)\/?$/)
  if (job) {
    return {
      route_id: new URLSearchParams(search).get("tab") === "review" ? "job.review" : "job.show",
      route_params: { job_id: job[1] }
    }
  }

  const chat = path.match(/^\/chats\/([1-9]\d*)\/?$/)
  return chat ? { route_id: "chat.show", route_params: { chat_id: chat[1] } } : null
}

export function startUiEngagementVisit(route: EngagementRoute, clock: Clock = { now: () => performance.now(), wallNow: () => Date.now() }) {
  let startedAt = clock.wallNow()
  let lastTick = clock.now()
  let lastInput = lastTick
  let activeMs = 0
  let visibleMs = 0
  let collecting = true
  let wasVisible = document.visibilityState === "visible"

  const accrue = () => {
    const now = clock.now()
    if (collecting && wasVisible) {
      visibleMs += Math.max(0, now - lastTick)
      const activeUntil = Math.min(now, lastInput + IDLE_AFTER_MS)
      activeMs += Math.max(0, activeUntil - lastTick)
    }
    lastTick = now
  }
  const onInput = () => {
    accrue()
    lastInput = clock.now()
  }
  const flush = () => {
    if (!collecting) return
    accrue()
    collecting = false
    const body = JSON.stringify({
      authenticity_token: document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content,
      ui_engagement_sample: {
        ...route,
        started_at: new Date(startedAt).toISOString(),
        ended_at: new Date(clock.wallNow()).toISOString(),
        active_ms: Math.round(activeMs),
        visible_ms: Math.round(visibleMs)
      }
    })
    navigator.sendBeacon("/api/v1/app/ui_engagement_samples", new Blob([body], { type: "application/json" }))
  }
  const onVisibilityChange = () => {
    accrue()
    wasVisible = document.visibilityState === "visible"
    if (!wasVisible) {
      flush()
    } else {
      startedAt = clock.wallNow()
      lastTick = clock.now()
      lastInput = lastTick
      activeMs = 0
      visibleMs = 0
      collecting = true
    }
  }
  const interval = window.setInterval(accrue, TICK_MS)
  const inputEvents = ["pointerdown", "pointermove", "keydown"] as const
  inputEvents.forEach((event) => window.addEventListener(event, onInput, { passive: true }))
  document.addEventListener("scroll", onInput, { capture: true, passive: true })
  document.addEventListener("visibilitychange", onVisibilityChange)
  window.addEventListener("pagehide", flush)

  return () => {
    flush()
    window.clearInterval(interval)
    inputEvents.forEach((event) => window.removeEventListener(event, onInput))
    document.removeEventListener("scroll", onInput, { capture: true })
    document.removeEventListener("visibilitychange", onVisibilityChange)
    window.removeEventListener("pagehide", flush)
  }
}

export function UiEngagementTelemetry({ enabled }: { enabled: boolean }) {
  const location = useLocation()
  const route = engagementRoute(location.pathname, location.search)

  useEffect(() => {
    if (!enabled || !route) return
    return startUiEngagementVisit(route)
  }, [enabled, route?.route_id, JSON.stringify(route?.route_params)])

  return null
}
