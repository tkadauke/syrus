import type { ScaleTime } from "d3-scale"
import { useT } from "../../hooks/useT"
import { timezoneOffsetLabel } from "../../lib/relativeTime"

// `width` is the caller's chart coordinate width (its own CHART_WIDTH
// constant) -- this component has no opinion on chart layout, only on
// rendering ticks across whatever width the caller's scale expects.
export function TimeAxis({ scale, width }: { scale: ScaleTime<number, number>; width: number }) {
  const { t } = useT("common")
  const ticks = scale.ticks(6)
  const offset = timezoneOffsetLabel()
  return (
    <svg aria-hidden="true" className="h-6 w-full" preserveAspectRatio="none" viewBox={`0 0 ${width} 24`}>
      {ticks.map((tick) => (
        <text fill="currentColor" fontSize="9" key={tick.toISOString()} textAnchor="middle" x={scale(tick)} y="16">
          {tick.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
        </text>
      ))}
      {offset ? (
        <text fill="currentColor" fontSize="8" opacity="0.6" textAnchor="end" x={width} y="8">
          <title>{t("timeline_axis.timezone_hint", { offset })}</title>
          {offset}
        </text>
      ) : null}
    </svg>
  )
}
