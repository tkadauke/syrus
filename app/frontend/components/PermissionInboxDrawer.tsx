import { useQuery } from "@tanstack/react-query"
import { useEffect, useRef, useState } from "react"
import { Link } from "react-router-dom"
import { fetchPermissionRequests } from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { withRoutePrefix } from "../lib/routing"
import { PermissionRequestCard } from "./PermissionRequestCard"

const CONTROL_CLASS = "relative inline-flex h-9 w-9 items-center justify-center rounded hover:bg-surface-subtle"
const HALO_CLASS =
  "pointer-events-none absolute inset-0 rounded-full bg-warning/30 motion-safe:animate-approval-waiting-halo motion-reduce:ring-2 motion-reduce:ring-warning-border"
const BADGE_CLASS = "absolute -right-1 -top-1 min-w-5 rounded-full bg-warning px-1.5 py-0.5 text-center text-2xs font-semibold leading-none text-surface"
const NEWLY_BLOCKED_PING_MS = 1_000

export function PermissionInboxDrawer({ onNavigate, prefix = "" }: { onNavigate?: () => void; prefix?: string }) {
  const { t } = useT("settings")
  const [open, setOpen] = useState(false)
  const [announcement, setAnnouncement] = useState("")
  const previousBlockedCount = useRef<number | null>(null)
  const clearAnnouncementTimeout = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const query = useQuery({ queryKey: ["permission_requests", 1], queryFn: () => fetchPermissionRequests(1), refetchInterval: 30_000 })
  const pending = (query.data?.requests ?? []).filter((request) => request.state === "pending")
  const pendingCount = query.data?.summary?.pending_count ?? pending.length
  const blockedCount = query.data?.summary?.blocked_agent_count ?? pending.filter((request) => request.checkpoint_state === "waiting").length
  const badge = pendingCount > 9 ? "9+" : String(pendingCount)
  const label = blockedCount
    ? t("approval_inbox.aria_blocked", { pending: pendingCount, blocked: blockedCount })
    : pendingCount
      ? t("approval_inbox.aria_pending", { count: pendingCount })
      : t("approval_inbox.open_drawer")

  useEffect(() => {
    if (previousBlockedCount.current != null && blockedCount > previousBlockedCount.current) {
      clearTimeout(clearAnnouncementTimeout.current)
      setAnnouncement(t("approval_inbox.newly_blocked", { count: blockedCount - previousBlockedCount.current }))
      clearAnnouncementTimeout.current = setTimeout(() => setAnnouncement(""), NEWLY_BLOCKED_PING_MS)
    } else if (previousBlockedCount.current != null && blockedCount < previousBlockedCount.current) {
      clearTimeout(clearAnnouncementTimeout.current)
      setAnnouncement("")
    }
    previousBlockedCount.current = blockedCount
  }, [blockedCount, t])

  useEffect(() => () => clearTimeout(clearAnnouncementTimeout.current), [])

  return (
    <div className="relative">
      <button
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={label}
        className={`${CONTROL_CLASS} ${blockedCount ? "text-warning-text" : "text-text-secondary hover:text-brand-emphasis"}`}
        data-blocked={blockedCount > 0 ? "true" : "false"}
        onClick={() => setOpen((value) => !value)}
        type="button"
      >
        {blockedCount ? <span aria-hidden="true" className={HALO_CLASS} data-testid="approval-waiting-halo" /> : null}
        {announcement ? (
          <span
            aria-hidden="true"
            className="pointer-events-none absolute inset-0 rounded-full ring-2 ring-warning-border motion-safe:animate-ping"
            data-testid="approval-newly-blocked-ping"
          />
        ) : null}
        <ShieldIcon />
        {pendingCount ? <span className={BADGE_CLASS}>{badge}</span> : null}
      </button>
      <span aria-live="assertive" className="sr-only">
        {announcement}
      </span>
      {open ? (
        <aside
          aria-label={t("approval_inbox.drawer_title")}
          className="fixed inset-y-0 right-0 z-40 w-full max-w-md overflow-y-auto border-l border-border bg-surface p-4 shadow-xl"
        >
          <header className="mb-4 flex items-center justify-between gap-3">
            <h2 className="text-lg font-semibold">{t("approval_inbox.drawer_title")}</h2>
            <button className="text-sm text-text-secondary" onClick={() => setOpen(false)} type="button">
              {t("approval_inbox.close")}
            </button>
          </header>
          <div className="space-y-3">
            {pending.slice(0, 5).map((request) => (
              <PermissionRequestCard key={request.id} request={request} />
            ))}
          </div>
          {!pendingCount ? <p className="text-sm text-text-muted">{t("approval_inbox.empty_pending")}</p> : null}
          <Link
            className="mt-4 inline-block text-sm font-semibold text-brand hover:underline"
            onClick={() => {
              setOpen(false)
              onNavigate?.()
            }}
            to={withRoutePrefix("/permissions/inbox", prefix)}
          >
            {t("approval_inbox.view_all")}
          </Link>
        </aside>
      ) : null}
    </div>
  )
}

function ShieldIcon() {
  return (
    <svg aria-hidden="true" className="relative h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M12 3.25 19 6v5.25c0 4.25-2.8 7.75-7 9.5-4.2-1.75-7-5.25-7-9.5V6l7-2.75Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.8" />
      <path d="M12 8v4.25M12 15.5h.01" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
    </svg>
  )
}
