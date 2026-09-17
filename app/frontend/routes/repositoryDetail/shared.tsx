// Shared RepositoryDetail primitives extracted from RepositoryDetail.tsx:
// the state-filter class helper and relative-time formatter reused across
// the overview, issues, and health sections. The status pill and panel
// message that used to live here were bare pass-throughs to TonePill/
// PanelMessage from the design system; callers now import those directly.

export function stateFilterClass(active: boolean) {
  return `rounded border px-3 py-1.5 text-sm font-medium ${active ? "border-brand bg-brand text-on-brand" : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"}`
}
export function buttonClass(tone: "green" | "blue" | "amber" | "gray", extra = "") {
  const colors = {
    amber: "bg-amber-600 text-white hover:bg-amber-500 dark:hover:bg-amber-500",
    blue: "border border-transparent bg-brand text-on-brand hover:opacity-90 focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-60",
    gray: "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700",
    green: "bg-emerald-600 text-white hover:bg-emerald-500 dark:hover:bg-emerald-500"
  }
  return `rounded px-3 py-1.5 text-sm font-medium ${colors[tone]} ${extra}`.trim()
}

export function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

export type RepositoryDetailQueryKey = readonly ["repositories", string, "detail", string]
