import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { useT } from "../hooks/useT"
import { fetchRepositoryCoverageTrend, type CoverageTrendPoint } from "../api/repositories"

type CoverageSparklineProps = {
  repositoryId: number
}

const SPARKLINE_W = 200
const SPARKLINE_H = 40
const SPARKLINE_PADDING = 2

export function CoverageSparkline({ repositoryId }: CoverageSparklineProps) {
  const { t } = useT("settings")
  const trend = useQuery({
    queryKey: ["repositories", String(repositoryId), "coverage_trend"],
    queryFn: () => fetchRepositoryCoverageTrend(repositoryId),
    staleTime: 5 * 60 * 1000
  })

  if (trend.isPending || trend.isError) return null

  const points = (trend.data.points ?? []).filter((p) => p.lines_pct != null)
  if (points.length < 2) return null

  return (
    <div data-testid="coverage-sparkline">
      <h3 className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("repository.coverage_trend_label")}</h3>
      <SparklineChart points={points} />
    </div>
  )
}

function SparklineChart({ points }: { points: CoverageTrendPoint[] }) {
  const { t } = useT("settings")
  const [tooltip, setTooltip] = useState<{ point: CoverageTrendPoint; x: number; y: number } | null>(null)

  const values = points.map((p) => p.lines_pct as number)
  const min = Math.max(0, Math.min(...values) - 5)
  const max = Math.min(100, Math.max(...values) + 5)
  const range = max - min || 1

  function toSvgX(index: number) {
    return SPARKLINE_PADDING + (index / (points.length - 1)) * (SPARKLINE_W - 2 * SPARKLINE_PADDING)
  }

  function toSvgY(pct: number) {
    return SPARKLINE_H - SPARKLINE_PADDING - ((pct - min) / range) * (SPARKLINE_H - 2 * SPARKLINE_PADDING)
  }

  const pathD = points.map((p, i) => {
    const x = toSvgX(i)
    const y = toSvgY(p.lines_pct as number)
    return `${i === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)}`
  }).join(" ")

  const lastPoint = points.at(-1)
  const lastPct = lastPoint?.lines_pct

  return (
    <div className="relative">
      <div className="flex items-center gap-2">
        <svg
          aria-label={t("repository.coverage_trend_aria")}
          className="overflow-visible"
          height={SPARKLINE_H}
          role="img"
          viewBox={`0 0 ${SPARKLINE_W} ${SPARKLINE_H}`}
          width={SPARKLINE_W}
          onMouseLeave={() => setTooltip(null)}
        >
          <path
            className="fill-none stroke-blue-500 dark:stroke-blue-400"
            d={pathD}
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth="1.5"
          />
          {points.map((p, i) => {
            const x = toSvgX(i)
            const y = toSvgY(p.lines_pct as number)
            return (
              <circle
                className="cursor-crosshair fill-blue-500 dark:fill-blue-400"
                cx={x}
                cy={y}
                key={`${p.date}-${i}`}
                r={3}
                onMouseEnter={() => setTooltip({ point: p, x, y })}
              />
            )
          })}
        </svg>
        {lastPct != null ? (
          <span className="text-xs font-medium text-blue-700 dark:text-blue-300">{lastPct.toFixed(1)}%</span>
        ) : null}
      </div>

      {tooltip ? (
        <div
          className="pointer-events-none absolute z-10 rounded border border-gray-200 bg-white px-2 py-1.5 text-xs shadow-sm dark:border-gray-700 dark:bg-gray-900"
          style={{ left: tooltip.x + 8, top: tooltip.y - 8 }}
        >
          <div className="font-medium text-gray-900 dark:text-gray-100">{tooltip.point.date}</div>
          <div className="text-gray-600 dark:text-gray-300">
            {t("repository.coverage_trend_lines")}: {tooltip.point.lines_pct != null ? `${tooltip.point.lines_pct.toFixed(1)}%` : "—"}
          </div>
          {tooltip.point.branches_pct != null ? (
            <div className="text-gray-600 dark:text-gray-300">
              {t("repository.coverage_trend_branches")}: {tooltip.point.branches_pct.toFixed(1)}%
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
