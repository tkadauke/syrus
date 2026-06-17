import type { ReactNode } from "react"

type PillTone = "red" | "green" | "blue" | "gray" | "amber"

export function StatusPill({ state }: { state: string }) {
  const normalized = state.toLowerCase()
  const tone = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel") ? "red" :
    normalized.includes("success") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed") ? "green" :
      normalized.includes("running") || normalized.includes("queued") ? "blue" : "gray"

  return <TonePill active={normalized === "running"} tone={tone}>{state.replaceAll("_", " ")}</TonePill>
}

export function TonePill({ children, tone, active = false, title, ariaLabel }: { children: ReactNode; tone: PillTone; active?: boolean; title?: string; ariaLabel?: string }) {
  const colors = {
    amber: "bg-amber-50 dark:bg-amber-950/40 text-amber-700 dark:text-amber-300 ring-amber-200 dark:ring-amber-800",
    blue: "bg-blue-50 dark:bg-blue-950/40 text-blue-700 dark:text-blue-300 ring-blue-200 dark:ring-blue-800",
    gray: "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 ring-gray-200 dark:ring-gray-700",
    green: "bg-emerald-50 dark:bg-emerald-950/40 text-emerald-700 dark:text-emerald-300 ring-emerald-200 dark:ring-emerald-800",
    red: "bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300 ring-red-200 dark:ring-red-800"
  }

  return (
    <span aria-label={ariaLabel} className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ${colors[tone]}`} data-status-pill="true" title={title}>
      {active ? <RunningSpinner /> : null}
      <span>{children}</span>
    </span>
  )
}

function RunningSpinner() {
  return (
    <span
      aria-hidden="true"
      className="h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-blue-200 dark:border-blue-800 border-t-blue-700"
      data-running-spinner="true"
    />
  )
}
