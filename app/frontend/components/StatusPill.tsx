import type { ReactNode } from "react"
import { useT } from "../hooks/useT"

type PillTone = "red" | "green" | "blue" | "gray" | "amber"

const STATE_LATIN: Record<string, string> = {
  // Job states
  triaging:    "Auspicia consuluntur — The omens are being consulted",
  queued:      "In acie stat — It stands in the battle line",
  open:        "Agitur — It is being done",
  implemented: "Factum est — It is done",
  approved:    "Probatum est — It is proven",
  landing:     "Propinquat — It draws near",
  merged:      "In annales scriptum — Written in the annals",
  closed:           "Cecidit — It fell",
  no_change_needed: "Iam factum est — It was already done",
  // Run / step states
  running:     "Currit — It runs",
  success:     "Successit — It has succeeded",
  failed:      "Defecit — It has failed",
  cancelled:   "Intermissum est — It has been interrupted",
  invalid:     "Invalidum — Invalid",
  // Merge state
  unmergeable: "Bellum Civile — Civil war between branches",
  mergeable:   "Concordia — Harmony",
}

export function StatusPill({ state }: { state: string }) {
  const { t } = useT()
  const normalized = state.toLowerCase()
  const tone = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel") ? "red" :
    normalized.includes("success") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed") ? "green" :
      normalized.includes("running") || normalized.includes("queued") ? "blue" : "gray"

  // Translated label with a humanized fallback for states not in the locale.
  const label = t(`status.${normalized}`, { defaultValue: state.replaceAll("_", " ") })

  return (
    <TonePill active={normalized === "running"} tone={tone} title={STATE_LATIN[normalized]}>
      {label}
    </TonePill>
  )
}

export function TonePill({ children, tone, active = false, title, ariaLabel }: { children: ReactNode; tone: PillTone; active?: boolean; title?: string; ariaLabel?: string }) {
  const colors = {
    amber: "bg-amber-50 text-amber-700 ring-amber-200 dark:bg-amber-950/50 dark:text-amber-200 dark:ring-amber-800",
    blue: "bg-blue-50 text-blue-700 ring-blue-200 dark:bg-blue-950/50 dark:text-blue-200 dark:ring-blue-800",
    gray: "bg-gray-100 text-gray-700 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700",
    green: "bg-emerald-50 text-emerald-700 ring-emerald-200 dark:bg-emerald-950/50 dark:text-emerald-200 dark:ring-emerald-800",
    red: "bg-red-50 text-red-700 ring-red-200 dark:bg-red-950/50 dark:text-red-200 dark:ring-red-800"
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
      className="h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-blue-200 border-t-blue-700 dark:border-blue-800 dark:border-t-blue-200"
      data-running-spinner="true"
    />
  )
}
