import type { ReactNode } from "react"

type PillTone = "red" | "green" | "blue" | "gray" | "amber"

export function StatusPill({ state }: { state: string }) {
  const normalized = state.toLowerCase()
  const tone = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel") ? "red" :
    normalized.includes("success") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed") ? "green" :
      normalized.includes("running") || normalized.includes("queued") ? "blue" : "gray"

  return <TonePill active={normalized === "running"} tone={tone}>{state.replaceAll("_", " ")}</TonePill>
}

export function TonePill({ children, tone, active = false }: { children: ReactNode; tone: PillTone; active?: boolean }) {
  const colors = {
    amber: "bg-amber-50 text-amber-700 ring-amber-200",
    blue: "bg-blue-50 text-blue-700 ring-blue-200",
    gray: "bg-gray-100 text-gray-700 ring-gray-200",
    green: "bg-emerald-50 text-emerald-700 ring-emerald-200",
    red: "bg-red-50 text-red-700 ring-red-200"
  }

  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ${colors[tone]}`} data-status-pill="true">
      {active ? <RunningSpinner /> : null}
      <span>{children}</span>
    </span>
  )
}

function RunningSpinner() {
  return (
    <span
      aria-hidden="true"
      className="h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-blue-200 border-t-blue-700"
      data-running-spinner="true"
    />
  )
}
