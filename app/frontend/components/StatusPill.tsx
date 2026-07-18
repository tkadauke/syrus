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
  closed:      "Cecidit — It fell",
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

const CHIP_TONE: Record<PillTone, string> = {
  amber: "chip-warning",
  blue:  "chip-info",
  gray:  "chip-muted",
  green: "chip-success",
  red:   "chip-error",
}

export function TonePill({ children, tone, active = false, title, ariaLabel }: { children: ReactNode; tone: PillTone; active?: boolean; title?: string; ariaLabel?: string }) {
  return (
    <span aria-label={ariaLabel} className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ${CHIP_TONE[tone]}`} data-status-pill="true" title={title}>
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
