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
  const { t } = useT("settings")
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400",
    warning: "border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

export function stateFilterClass(active: boolean) {
  return `rounded border px-3 py-1.5 text-sm font-medium ${active ? "border-brand bg-brand text-on-brand" : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"}`
}
export function buttonClass(tone: "green" | "blue" | "amber" | "gray", extra = "") {
  const colors = {
    amber: "bg-amber-600 text-white hover:bg-amber-500 dark:hover:bg-amber-500",
    blue: "bg-brand text-on-brand hover:opacity-90",
    gray: "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700",
    green: "bg-emerald-600 text-white hover:bg-emerald-500 dark:hover:bg-emerald-500"
  }
  return `rounded px-3 py-1.5 text-sm font-medium ${colors[tone]} ${extra}`.trim()
}

export function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

export type RepositoryDetailQueryKey = readonly ["repositories", string, "detail", string]
