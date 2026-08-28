import type { ScaleTime } from "d3-scale"
import { CHART_WIDTH } from "./constants"

export function TimeAxis({ scale }: { scale: ScaleTime<number, number> }) {
  const ticks = scale.ticks(6)
  return (
    <svg aria-hidden="true" className="h-6 w-full" preserveAspectRatio="none" viewBox={`0 0 ${CHART_WIDTH} 24`}>
      {ticks.map((tick) => (
        <text fill="currentColor" fontSize="9" key={tick.toISOString()} textAnchor="middle" x={scale(tick)} y="16">
          {tick.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
        </text>
      ))}
    </svg>
  )
}
