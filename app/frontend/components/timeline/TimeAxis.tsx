import type { ScaleTime } from "d3-scale"

// `width` is the caller's chart coordinate width (its own CHART_WIDTH
// constant) -- this component has no opinion on chart layout, only on
// rendering ticks across whatever width the caller's scale expects.
export function TimeAxis({ scale, width }: { scale: ScaleTime<number, number>; width: number }) {
  const ticks = scale.ticks(6)
  return (
    <svg aria-hidden="true" className="h-6 w-full" preserveAspectRatio="none" viewBox={`0 0 ${width} 24`}>
      {ticks.map((tick) => (
        <text fill="currentColor" fontSize="9" key={tick.toISOString()} textAnchor="middle" x={scale(tick)} y="16">
          {tick.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
        </text>
      ))}
    </svg>
  )
}
