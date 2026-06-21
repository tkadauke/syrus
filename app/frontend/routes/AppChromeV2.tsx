import { useQuery, useQueryClient } from "@tanstack/react-query"
import { type ReactNode, useState } from "react"
import { Link, Outlet, useLocation } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { patchJson } from "../api/client"

export function AppChromeV2({ children, initialBootstrap }: { children?: ReactNode; initialBootstrap: BootstrapPayload | null }) {
  const location = useLocation()
  const queryClient = useQueryClient()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const shouldLoadChromeBootstrap = initialBootstrap != null
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: shouldLoadChromeBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const data = bootstrap.data ?? initialBootstrap
  const user = data?.current_user
  const [switching, setSwitching] = useState(false)

  function switchToClassicUi() {
    setSwitching(true)
    void patchJson<{ layout_version: "v1" | "v2" }>("/api/v1/app/layout_version", { layout_version: "v1" }).then((payload) => {
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapLayoutVersion(current ?? data, payload.layout_version))
    }).finally(() => {
      setSwitching(false)
    })
  }

  return (
    <div className="flex h-screen overflow-hidden bg-gray-50 text-gray-900 dark:bg-gray-900 dark:text-white">
      <aside className="flex w-[240px] shrink-0 flex-col border-r border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
        <div className="border-b border-gray-200 px-4 py-4 dark:border-gray-800">
          <Link className="text-lg font-semibold text-gray-900 dark:text-white" to={prefix || "/"}>Syrus</Link>
        </div>
        <nav aria-label="Primary" className="flex flex-1 flex-col gap-1 px-3 py-4 text-sm">
          <Link className={sidebarLinkClass(location.pathname === "/" || location.pathname.includes("/dashboard"))} to={`${prefix}/dashboard/jobs?view=list`}>Dashboard</Link>
          <Link className={sidebarLinkClass(location.pathname.includes("/insights/spending"))} to={`${prefix}/insights/spending`}>Spending</Link>
          <Link className={sidebarLinkClass(location.pathname.includes("/repositories"))} to={`${prefix}/repositories`}>Repositories</Link>
          <Link className={sidebarLinkClass(location.pathname.includes("/scheduled_tasks"))} to={`${prefix}/scheduled_tasks`}>Schedules</Link>
        </nav>
        <div className="border-t border-gray-200 p-3 dark:border-gray-800">
          <button
            className="w-full rounded border border-gray-300 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-60 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
            disabled={!user || switching}
            onClick={switchToClassicUi}
            type="button"
          >
            Switch to classic UI
          </button>
        </div>
      </aside>
      <main className="flex-1 overflow-auto">
        {children ?? <Outlet />}
      </main>
    </div>
  )
}

function updateBootstrapLayoutVersion(payload: BootstrapPayload | undefined | null, layoutVersion: "v1" | "v2") {
  if (!payload?.current_user) return undefined

  return {
    ...payload,
    current_user: {
      ...payload.current_user,
      layout_version: layoutVersion
    }
  }
}

function sidebarLinkClass(active: boolean) {
  return `rounded px-3 py-2 font-medium ${active ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-950" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`
}
