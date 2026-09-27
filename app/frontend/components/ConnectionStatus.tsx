import { useEffect, useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { useT } from "../hooks/useT"
import { type ConnectionEvent, useConnectionContext } from "../lib/connectionContext"
import { withRoutePrefix } from "../lib/routing"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { Button } from "./Button"
import { noticeAnimationClass } from "./noticeStyles"
import { RelativeTimestamp } from "./RelativeTimestamp"
import { surfaceClasses } from "./ui"

export function ConnectionStatusButton({ prefix, onNavigate }: { prefix: string; onNavigate?: () => void }) {
  const { t } = useT("nav")
  const connection = useConnectionContext()
  const [open, setOpen] = useState(false)
  const isMobile = useMediaQuery("(max-width: 767px)")
  const panelRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const label = t(`connection_status.${connection.status}.title`)

  if (isMobile) {
    return (
      <Link
        aria-label={label}
        className={statusButtonClass()}
        onClick={() => {
          setOpen(false)
          onNavigate?.()
        }}
        to={withRoutePrefix("/connection", prefix)}
      >
        <ConnectionIcon />
        <StatusDot status={connection.status} />
      </Link>
    )
  }

  return (
    <div className="relative" ref={panelRef}>
      <button
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={label}
        className={statusButtonClass()}
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <ConnectionIcon />
        <StatusDot status={connection.status} />
      </button>
      {open ? (
        <div className={`absolute left-0 top-full z-30 mt-2 w-80 rounded border border-border bg-surface shadow-lg ${noticeAnimationClass()}`}>
          <ConnectionStatusPanel />
        </div>
      ) : null}
    </div>
  )
}

export function ConnectionStatusRoute() {
  const { t } = useT("nav")
  const navigate = useNavigate()

  return (
    <main aria-label={t("connection_status.route_title")} className="min-h-full bg-surface-inset p-4 sm:p-6">
      <div className="mx-auto max-w-3xl">
        <Button className="mb-4" onClick={() => navigate(-1)} variant="secondary">
          <BackIcon />
          <span>{t("connection_status.back")}</span>
        </Button>
        <section className={surfaceClasses("panel", "none")}>
          <ConnectionStatusPanel />
        </section>
      </div>
    </main>
  )
}

function ConnectionStatusPanel() {
  const { t } = useT("nav")
  const { events, status } = useConnectionContext()

  return (
    <div>
      <div className="border-b border-border px-4 py-3">
        <div className="flex items-center gap-2">
          <span aria-hidden="true" className={`h-2.5 w-2.5 rounded-full ${dotClass(status)}`} />
          <h1 className="text-sm font-semibold text-text-primary">{t(`connection_status.${status}.title`)}</h1>
        </div>
        <p className="mt-1 text-sm text-text-secondary">{t(`connection_status.${status}.body`)}</p>
      </div>
      <div className="px-4 py-3">
        <h2 className="text-xs font-semibold uppercase text-text-secondary">{t("connection_status.recent_events")}</h2>
        {events.length > 0 ? (
          <div className="mt-2 divide-y divide-border">
            {events.map((event) => (
              <ConnectionEventRow event={event} key={event.id} />
            ))}
          </div>
        ) : (
          <p className="mt-3 text-sm text-text-secondary">{t("connection_status.no_events")}</p>
        )}
      </div>
    </div>
  )
}

function ConnectionEventRow({ event }: { event: ConnectionEvent }) {
  const { t } = useT("nav")

  return (
    <div className="flex items-center gap-3 py-2 text-sm">
      <span aria-hidden="true" className={`h-2 w-2 shrink-0 rounded-full ${eventDotClass(event.kind)}`} />
      <span className="min-w-0 flex-1 text-text-primary">{t(`connection_status.events.${event.kind}`)}</span>
      <RelativeTimestamp className="shrink-0 text-xs text-text-secondary" value={new Date(event.at).toISOString()} />
    </div>
  )
}

function StatusDot({ status }: { status: "connected" | "reconnecting" }) {
  return <span aria-hidden="true" className={`absolute right-1.5 top-1.5 h-2.5 w-2.5 rounded-full ring-2 ring-surface ${dotClass(status)}`} />
}

function statusButtonClass() {
  return "relative inline-flex h-9 w-9 items-center justify-center rounded text-text-secondary hover:bg-surface-raised hover:text-brand-emphasis"
}

function dotClass(status: "connected" | "reconnecting") {
  return status === "connected" ? "bg-green-500" : "bg-amber-500"
}

function eventDotClass(kind: ConnectionEvent["kind"]) {
  return kind === "connected" || kind === "reconnected" ? "bg-green-500" : "bg-amber-500"
}

function ConnectionIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M7.25 14.25a6.75 6.75 0 0 1 9.5 0M4.75 11.25a10.25 10.25 0 0 1 14.5 0M10.25 17.25a2.5 2.5 0 0 1 3.5 0M12 20h.01" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function BackIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M15.25 5.75 9 12l6.25 6.25" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function useMediaQuery(query: string) {
  const [matches, setMatches] = useState(() => {
    if (typeof window.matchMedia !== "function") return false
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    setMatches(media.matches)

    function handleChange(event: MediaQueryListEvent) {
      setMatches(event.matches)
    }

    media.addEventListener("change", handleChange)
    return () => media.removeEventListener("change", handleChange)
  }, [query])

  return matches
}
