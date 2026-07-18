import type { ReactNode } from "react"
import { useT } from "../../hooks/useT"
import { TonePill } from "../../components/StatusPill"


// Shared RepositoryDetail primitives extracted from RepositoryDetail.tsx:
// the status pill, panel message, state-filter class helper, and relative-
// time formatter reused across the overview, issues, and health sections.

export function StatusPill({ children, tone }: { children: ReactNode; tone: "green" | "gray" | "blue" | "red" | "amber" }) {
  const { t } = useT("settings")
  return <TonePill tone={tone}>{children}</TonePill>
}

export function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "warning" }) {
  return <div className={`banner-${tone} p-4 text-sm`}>{children}</div>
}

export function stateFilterClass(active: boolean) {
  return `rounded border px-3 py-1.5 text-sm font-medium ${active ? "border-blue-600 bg-blue-600 text-white" : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"}`
}
export function buttonClass(tone: "green" | "blue" | "amber" | "gray", extra = "") {
  const colors = {
    amber: "bg-amber-600 text-white hover:bg-amber-500 dark:hover:bg-amber-500",
    blue: "bg-blue-600 text-white hover:bg-blue-500 dark:hover:bg-blue-500",
    gray: "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700",
    green: "bg-emerald-600 text-white hover:bg-emerald-500 dark:hover:bg-emerald-500"
  }
  return `rounded px-3 py-1.5 text-sm font-medium ${colors[tone]} ${extra}`.trim()
}

export function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

export type RepositoryDetailQueryKey = readonly ["repositories", string, "detail", string]
