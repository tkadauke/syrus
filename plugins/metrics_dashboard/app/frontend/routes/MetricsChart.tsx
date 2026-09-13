import { useId } from "react"
import { useT } from "@app/hooks/useT"
import type { MetricsPanel } from "../api/metricsDashboard"
import {
  formatClock,
  formatDuration,
  formatValue,
  formatWithUnit,
  linePath,
  panelScale,
  tickIndexes,
  xFor,
  yFor
} from "./chartGeometry"

// Picked to stay distinguishable on both themes and for the common kinds of
// colour blindness; index-assigned so a series keeps its colour across renders.
const SERIES_COLORS = [
  "#0d9488", "#c2410c", "#4f46e5", "#b91c1c",
  "#0369a1", "#7c3aed", "#a16207", "#15803d"
]

const PLOT_HEIGHT = 168
const PLOT_WIDTH = 1000
const AXIS_GUTTER = 46

export function MetricsChart({
  panel,
  buckets,
  bucketSeconds,
  hoverIndex,
  onHover,
  title
}: {
  panel: MetricsPanel
  buckets: string[]
  bucketSeconds: number
  hoverIndex: number | null
  onHover: (index: number | null) => void
  title: string
}) {
  const { t } = useT("metrics_dashboard")
  const clipId = useId()
  const scale = panelScale(panel.series)
  const ticks = tickIndexes(buckets.length)
  const gridLines = [ 0, 0.25, 0.5, 0.75, 1 ]

  // The index the pointer is over, mapped from where it landed in the plot.
  // Rounded rather than floored so the crosshair snaps to the nearest bucket
  // instead of always the one to its left.
  function handleMove(event: React.PointerEvent<SVGSVGElement>) {
    const rect = event.currentTarget.getBoundingClientRect()
    const ratio = (event.clientX - rect.left) / rect.width
    const index = Math.round(ratio * (buckets.length - 1))
    onHover(Math.min(Math.max(index, 0), buckets.length - 1))
  }

  const activeIndex = hoverIndex ?? buckets.length - 1

  return (
    <section className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <header className="mb-3 flex items-baseline justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h2>
          <p className="mt-0.5 font-mono text-[11px] text-gray-500 dark:text-gray-400">
            {panel.metric} · {panel.unit}
            {panel.mode === "rate" ? ` · per ${formatDuration(bucketSeconds)}` : ""}
          </p>
        </div>
        <span className="font-mono text-[11px] tabular-nums text-gray-500 dark:text-gray-400">
          {buckets[activeIndex] ? formatClock(buckets[activeIndex]) : ""}
        </span>
      </header>

      {panel.series.length === 0 ? (
        <p
          className="flex items-center justify-center text-sm text-gray-400 dark:text-gray-500"
          style={{ height: PLOT_HEIGHT + 22 }}
        >
          {t("panel_empty")}
        </p>
      ) : (
      <svg
        className="w-full touch-none"
        onPointerLeave={() => onHover(null)}
        onPointerMove={handleMove}
        preserveAspectRatio="none"
        role="img"
        aria-label={title}
        viewBox={`0 0 ${PLOT_WIDTH + AXIS_GUTTER} ${PLOT_HEIGHT + 22}`}
        style={{ height: PLOT_HEIGHT + 22 }}
      >
        <defs>
          <clipPath id={clipId}>
            <rect height={PLOT_HEIGHT} width={PLOT_WIDTH} x={AXIS_GUTTER} y={0} />
          </clipPath>
        </defs>

        {gridLines.map((fraction) => {
          const y = fraction * PLOT_HEIGHT
          const value = scale.max - fraction * (scale.max - scale.min)
          return (
            <g key={fraction}>
              <line
                className="stroke-gray-200 dark:stroke-gray-700"
                strokeDasharray={fraction === 1 ? undefined : "3 4"}
                strokeWidth="1"
                vectorEffect="non-scaling-stroke"
                x1={AXIS_GUTTER}
                x2={AXIS_GUTTER + PLOT_WIDTH}
                y1={y}
                y2={y}
              />
              <text
                className="fill-gray-400 text-[11px] tabular-nums dark:fill-gray-500"
                dominantBaseline="middle"
                textAnchor="end"
                x={AXIS_GUTTER - 6}
                y={y}
              >
                {formatWithUnit(value, panel.unit)}
              </text>
            </g>
          )
        })}

        <g clipPath={`url(#${clipId})`}>
          {panel.series.map((series, index) => (
            <path
              d={linePath(series.values, scale, PLOT_WIDTH, PLOT_HEIGHT, AXIS_GUTTER)}
              fill="none"
              key={series.name}
              stroke={SERIES_COLORS[index % SERIES_COLORS.length]}
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth="1.75"
              vectorEffect="non-scaling-stroke"
            />
          ))}
        </g>

        {hoverIndex !== null && (
          <g>
            <line
              className="stroke-gray-400 dark:stroke-gray-500"
              strokeDasharray="3 3"
              strokeWidth="1"
              vectorEffect="non-scaling-stroke"
              x1={AXIS_GUTTER + xFor(hoverIndex, buckets.length, PLOT_WIDTH)}
              x2={AXIS_GUTTER + xFor(hoverIndex, buckets.length, PLOT_WIDTH)}
              y1={0}
              y2={PLOT_HEIGHT}
            />
            {panel.series.map((series, index) => {
              const value = series.values[hoverIndex]
              if (value === null || value === undefined) return null
              return (
                <circle
                  cx={AXIS_GUTTER + xFor(hoverIndex, buckets.length, PLOT_WIDTH)}
                  cy={yFor(value, scale, PLOT_HEIGHT)}
                  fill={SERIES_COLORS[index % SERIES_COLORS.length]}
                  key={series.name}
                  r="3"
                />
              )
            })}
          </g>
        )}

        {ticks.map((index) => (
          <text
            className="fill-gray-400 text-[11px] tabular-nums dark:fill-gray-500"
            key={index}
            textAnchor={index === 0 ? "start" : index === buckets.length - 1 ? "end" : "middle"}
            x={AXIS_GUTTER + xFor(index, buckets.length, PLOT_WIDTH)}
            y={PLOT_HEIGHT + 16}
          >
            {buckets[index] ? formatClock(buckets[index]) : ""}
          </text>
        ))}
      </svg>
      )}

      <ul className="mt-3 grid gap-x-4 gap-y-1 sm:grid-cols-2">
        {panel.series.map((series, index) => (
          <li className="flex items-center justify-between gap-2 text-xs" key={series.name}>
            <span className="flex min-w-0 items-center gap-1.5">
              <span
                aria-hidden="true"
                className="h-2 w-2 shrink-0 rounded-full"
                style={{ backgroundColor: SERIES_COLORS[index % SERIES_COLORS.length] }}
              />
              <span className="truncate font-mono text-gray-600 dark:text-gray-300" title={series.name}>
                {series.name}
              </span>
            </span>
            <span className="shrink-0 font-mono tabular-nums text-gray-900 dark:text-gray-100">
              {formatWithUnit(series.values[activeIndex] ?? null, panel.unit)}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}

export { SERIES_COLORS, formatValue }
