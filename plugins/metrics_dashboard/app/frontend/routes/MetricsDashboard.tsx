import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useSearchParams } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchMetricsDashboard, type MetricsPanel, type MetricsSeries } from "../api/metricsDashboard"

const DEFAULT_WINDOW = "6h"

export function MetricsDashboardRoute() {
  const { t } = useT("metrics_dashboard")
  usePageTitle(t("heading"))
  const [ searchParams, setSearchParams ] = useSearchParams()
  const window = searchParams.get("window") || DEFAULT_WINDOW

  const dashboard = useQuery({
    queryKey: [ "metrics_dashboard", window ],
    queryFn: () => fetchMetricsDashboard(window),
    placeholderData: keepPreviousData,
    refetchInterval: 60_000
  })

  if (dashboard.isPending) {
    return <main className="p-6 text-sm text-gray-500">{t("loading")}</main>
  }
  if (dashboard.isError) {
    return <main className="p-6 text-sm text-red-700">{errorMessage(dashboard.error, t("error"))}</main>
  }

  const payload = dashboard.data

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-[90rem] space-y-4 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-gray-200 pb-4 dark:border-gray-700">
        <div>
          <h1 className="text-lg font-semibold">{t("heading")}</h1>
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("subheading")}</p>
        </div>
        <div className="flex items-center gap-2">
          {payload.windows.map((option) => (
            <button
              className={`rounded border px-3 py-1 text-sm ${
                option === payload.window
                  ? "border-brand bg-brand/10 text-brand"
                  : "border-gray-300 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
              }`}
              key={option}
              onClick={() => setSearchParams({ window: option })}
              type="button"
            >
              {option}
            </button>
          ))}
        </div>
      </header>

      <RecordingNotice lastRecordedAt={payload.last_recorded_at} recording={payload.recording} />

      <div className="grid gap-4 lg:grid-cols-2">
        {payload.panels.map((panel) => <Panel key={panel.key} panel={panel} />)}
      </div>
    </main>
  )
}

// A dashboard that silently shows nothing is worse than one that says why. The
// recorder only runs while the plugin is enabled, so "no data" has two very
// different causes and the operator needs to know which.
function RecordingNotice({ recording, lastRecordedAt }: { recording: boolean; lastRecordedAt: string | null }) {
  const { t } = useT("metrics_dashboard")
  if (recording) return null

  return (
    <div className="rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-900/60 dark:bg-amber-950/30 dark:text-amber-100">
      {lastRecordedAt
        ? t("stale_notice", { at: new Date(lastRecordedAt).toLocaleString() })
        : t("no_data_notice")}
    </div>
  )
}

function Panel({ panel }: { panel: MetricsPanel }) {
  const { t } = useT("metrics_dashboard")
  const hasData = panel.series.some((series) => series.points.length > 0)

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <header className="mb-3">
        <h2 className="text-sm font-semibold">{t(`panels.${panel.key}`)}</h2>
        <p className="mt-0.5 font-mono text-[11px] text-gray-500 dark:text-gray-400">
          {panel.metric} · {panel.unit}
        </p>
      </header>
      {hasData
        ? <Sparklines panel={panel} />
        : <p className="text-sm text-gray-500 dark:text-gray-400">{t("panel_empty")}</p>}
    </section>
  )
}

function Sparklines({ panel }: { panel: MetricsPanel }) {
  return (
    <ul className="space-y-2">
      {panel.series.map((series) => (
        <li className="grid grid-cols-[8rem_1fr_5rem] items-center gap-2" key={series.name}>
          <span className="truncate font-mono text-xs" title={series.name}>{series.name}</span>
          <Sparkline series={series} />
          <span className="text-right font-mono text-xs tabular-nums">{formatLatest(series)}</span>
        </li>
      ))}
    </ul>
  )
}

/**
 * Each series is scaled to its own range, not to a shared zero-anchored one.
 *
 * The first version shared one scale across a panel so the lines would be
 * comparable, which made every chart unreadable: `cleanup` at 4 and `polling`
 * at 24,124 share an axis, so everything but the largest series flattens
 * against the floor. Anchoring at zero then flattened the largest one too --
 * polling climbing 21,614 -> 24,124 is a 10% move, about three pixels of a
 * 28-pixel chart, so the queue backing up by 40 minutes looked like a
 * horizontal line.
 *
 * Magnitude is already carried by the number printed beside the line. The line
 * only has to show shape, which is what a sparkline is for.
 */
export function sparklinePoints(values: number[], width = 200, height = 28) {
  if (values.length === 0) return ""

  const min = Math.min(...values)
  const max = Math.max(...values)
  const span = max - min

  // A genuinely flat series draws down the middle rather than along an edge,
  // so "steady" reads as steady instead of as pinned at a limit.
  const y = (value: number) => (span === 0 ? height / 2 : height - ((value - min) / span) * height)
  const step = values.length > 1 ? width / (values.length - 1) : width

  return values.map((value, index) => `${(index * step).toFixed(1)},${y(value).toFixed(1)}`).join(" ")
}

function Sparkline({ series }: { series: MetricsSeries }) {
  if (series.points.length === 0) return <span />

  const width = 200
  const height = 28
  const points = sparklinePoints(series.points.map(([ , value ]) => value), width, height)

  return (
    <svg
      aria-hidden="true"
      className="h-7 w-full"
      preserveAspectRatio="none"
      viewBox={`0 0 ${width} ${height}`}
    >
      <polyline
        fill="none"
        points={points}
        stroke="currentColor"
        strokeWidth="1.5"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  )
}

function formatLatest(series: MetricsSeries) {
  const last = series.points.at(-1)
  if (!last) return "—"

  const value = last[1]
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}

export default MetricsDashboardRoute
