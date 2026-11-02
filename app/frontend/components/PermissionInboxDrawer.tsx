import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import { fetchPermissionRequests } from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { PermissionRequestCard } from "./PermissionRequestCard"

export function PermissionInboxDrawer() {
  const { t } = useT("settings")
  const [open, setOpen] = useState(false)
  const query = useQuery({ queryKey: ["permission_requests"], queryFn: fetchPermissionRequests, refetchInterval: 30_000 })
  const pending = (query.data?.requests ?? []).filter((request) => request.state === "pending")

  return <>
    <button aria-expanded={open} aria-label={t("approval_inbox.open_drawer")} className="fixed bottom-5 right-5 z-40 rounded-full bg-brand px-4 py-3 text-sm font-semibold text-on-brand shadow-lg" onClick={() => setOpen((value) => !value)} type="button">
      {t("approval_inbox.approvals")} {pending.length ? <span className="ml-1 rounded-full bg-surface px-2 py-0.5 text-brand">{pending.length}</span> : null}
    </button>
    {open ? <aside aria-label={t("approval_inbox.drawer_title")} className="fixed inset-y-0 right-0 z-50 w-full max-w-md overflow-y-auto border-l border-border bg-surface p-4 shadow-xl">
      <header className="mb-4 flex items-center justify-between gap-3"><h2 className="text-lg font-semibold">{t("approval_inbox.drawer_title")}</h2><button className="text-sm text-text-secondary" onClick={() => setOpen(false)}>{t("approval_inbox.close")}</button></header>
      <div className="space-y-3">{pending.slice(0, 5).map((request) => <PermissionRequestCard compact key={request.id} request={request} />)}</div>
      {!pending.length ? <p className="text-sm text-text-muted">{t("approval_inbox.empty_pending")}</p> : null}
      <Link className="mt-4 inline-block text-sm font-semibold text-brand hover:underline" onClick={() => setOpen(false)} to="/permissions/inbox">{t("approval_inbox.view_all")}</Link>
    </aside> : null}
  </>
}
