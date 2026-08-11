import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { fetchAdminTailscaleStatus, type AdminTailscaleStatus } from "../api/adminTailscale"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { CopyableSlug } from "@app/components/CopyableSlug"

type ConnectionState = "connected" | "connecting" | "not_configured"

export function AdminTailscale() {
  const { t } = useT("tailscale")
  usePageTitle(t("page_title"))
  const status = useQuery({
    queryKey: [ "admin", "tailscale", "status" ],
    queryFn: fetchAdminTailscaleStatus
  })

  return (
    <main aria-label={t("aria")} className="mx-auto max-w-3xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("heading")}</h1>
      </header>

      {status.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {status.isError ? <PanelMessage tone="error">{errorMessage(status.error, t("error_load"))}</PanelMessage> : null}
      {status.isSuccess ? <StatusView payload={status.data} /> : null}
    </main>
  )
}

export default AdminTailscale

function StatusView({ payload }: { payload: AdminTailscaleStatus }) {
  const { t } = useT("tailscale")
  const state = connectionState(payload)

  return (
    <div className="space-y-6">
      <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <div className="flex items-center justify-between gap-4">
          <div>
            <h2 className="text-sm font-medium text-gray-500 dark:text-gray-400">{t("status_heading")}</h2>
            <div className="mt-2"><StatusBadge state={state} /></div>
          </div>
          {payload.tailscale_url ? (
            <div className="text-right">
              <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("ts_net_url")}</p>
              <CopyableSlug className="mt-1 text-sm" slug={payload.tailscale_url} />
            </div>
          ) : null}
        </div>

        {state === "connected" ? (
          <p className="mt-4 rounded border border-gray-200 bg-gray-50 p-3 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
            {t("mobile_tip")}
          </p>
        ) : null}
      </section>

      <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-sm font-medium text-gray-500 dark:text-gray-400">{t("checklist_heading")}</h2>
        <ul className="mt-3 space-y-2">
          <ChecklistItem done={payload.auth_key_present} label={t("checklist_auth_key")} />
          <ChecklistItem done={payload.net_admin_capable} label={t("checklist_net_admin")} />
          <ChecklistItem done={payload.daemon_running} label={t("checklist_daemon")} />
        </ul>
      </section>
    </div>
  )
}

function connectionState(payload: AdminTailscaleStatus): ConnectionState {
  if (payload.connected) return "connected"
  if (payload.daemon_running) return "connecting"
  return "not_configured"
}

function StatusBadge({ state }: { state: ConnectionState }) {
  const { t } = useT("tailscale")
  const toneClass = state === "connected"
    ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200"
    : state === "connecting"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"
  const label = state === "connected" ? t("status_connected") : state === "connecting" ? t("status_connecting") : t("status_not_configured")

  return <span className={`inline-flex items-center rounded-full border px-3 py-1 text-sm font-medium ${toneClass}`}>{label}</span>
}

function ChecklistItem({ done, label }: { done: boolean; label: string }) {
  return (
    <li className="flex items-center gap-2 text-sm">
      <ChecklistIcon done={done} />
      <span className={done ? "text-gray-700 dark:text-gray-200" : "text-gray-500 dark:text-gray-400"}>{label}</span>
    </li>
  )
}

function ChecklistIcon({ done }: { done: boolean }) {
  if (done) {
    return (
      <svg aria-hidden="true" className="h-4 w-4 flex-shrink-0 text-emerald-600 dark:text-emerald-400" fill="none" viewBox="0 0 20 20">
        <path d="M4 10.5l3.5 3.5L16 6" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
      </svg>
    )
  }

  return (
    <svg aria-hidden="true" className="h-4 w-4 flex-shrink-0 text-gray-300 dark:text-gray-600" fill="none" viewBox="0 0 20 20">
      <circle cx="10" cy="10" r="7" stroke="currentColor" strokeWidth="2" />
    </svg>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`rounded border p-4 text-sm ${tone === "error" ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300" : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"}`}>{children}</div>
}
