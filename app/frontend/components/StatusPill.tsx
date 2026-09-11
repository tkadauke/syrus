import type { ReactNode } from "react"
import { useT } from "../hooks/useT"
import { Pill, TONE_CHIP_CLASSES } from "./ui/Pill"

export type PillTone = "red" | "green" | "blue" | "gray" | "amber"

// Shared tone → Tailwind class-string map, so call sites that can't render a
// full TonePill (e.g. a react-router Link, or a composite pill with nested
// interactive children) can still reuse the same status colors instead of
// hand-rolling their own bg/text/ring literals.
export const PILL_TONE_CLASSES: Record<PillTone, string> = {
  amber: TONE_CHIP_CLASSES.warning,
  blue: TONE_CHIP_CLASSES.info,
  gray: TONE_CHIP_CLASSES.neutral,
  green: TONE_CHIP_CLASSES.success,
  red: TONE_CHIP_CLASSES.danger
}

// Higher-contrast tone → class-string map for bordered notice banners (a
// system-message/alert box, not a small inline pill) — same tone vocabulary
// as PILL_TONE_CLASSES, bolder text/background weights for banner readability.
export type BannerTone = "success" | "warning" | "error" | "neutral"

export const BANNER_TONE_CLASSES: Record<BannerTone, string> = {
  success: "border-success-border bg-success-surface text-success-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  error: "border-danger-border bg-danger-surface text-danger-text",
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text"
}

const STATE_LATIN: Record<string, string> = {
  // Job states
  backlog:     "In tabulario — In the register",
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
  succeeded:   "Successit — It has succeeded",
  success:     "Successit — It has succeeded",
  failed:      "Defecit — It has failed",
  cancelled:   "Intermissum est — It has been interrupted",
  skipped:     "Praetermissum est — It has been skipped",
  invalid:     "Invalidum — Invalid",
  // Merge state
  unmergeable: "Bellum Civile — Civil war between branches",
  mergeable:   "Concordia — Harmony",
}

export function StatusPill({ state }: { state: string }) {
  const { t } = useT()
  const normalized = state.toLowerCase()
  const tone = normalized.includes("fail") || normalized.includes("invalid") || normalized.includes("cancel") ? "red" :
    normalized.includes("success") || normalized.includes("succeed") || normalized.includes("approved") || normalized.includes("merged") || normalized.includes("closed") ? "green" :
      normalized.includes("running") || normalized.includes("queued") ? "blue" :
        normalized.includes("backlog") || normalized.includes("paused") ? "amber" : "gray"

  // Translated label with a humanized fallback for states not in the locale.
  const label = t(`status.${normalized}`, { defaultValue: state.replaceAll("_", " ") })

  return (
    <TonePill active={normalized === "running"} tone={tone} title={STATE_LATIN[normalized]}>
      {label}
    </TonePill>
  )
}

export function TonePill({ children, tone, active = false, title, ariaLabel, wrap = false }: { children: ReactNode; tone: PillTone; active?: boolean; title?: string; ariaLabel?: string; wrap?: boolean }) {
  const wrappingClasses = wrap ? "max-w-full flex-wrap whitespace-normal break-words text-left" : "whitespace-nowrap"
  const semanticTone = tone === "red" ? "danger" : tone === "green" ? "success" : tone === "blue" ? "info" : tone === "amber" ? "warning" : "neutral"

  return (
    <Pill active={active} aria-label={ariaLabel} className={`capitalize ${wrappingClasses}`} data-status-pill="true" title={title} tone={semanticTone}>
      {children}
    </Pill>
  )
}
