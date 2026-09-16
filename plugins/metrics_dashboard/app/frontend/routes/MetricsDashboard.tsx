import { useState } from "react"
import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useSearchParams } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchMetricsDashboard } from "../api/metricsDashboard"
import { MetricsChart } from "./MetricsChart"

const DEFAULT_WINDOW = "6h"
const TAB_PARAM = "tab"

export function MetricsDashboardRoute() {
  const { t } = useT("metrics_dashboard")
  usePageTitle(t("heading"))
  const [ searchParams, setSearchParams ] = useSearchParams()
  const window = searchParams.get("window") || DEFAULT_WINDOW
  const requestedTab = searchParams.get(TAB_PARAM)

  // Lifted to the page, not held per chart: hovering one chart has to move the
  // crosshair in all of them, which is the whole point of serving every panel
  // on one bucket grid. Index i is the same instant everywhere. The window
  // selector lives at the page level for the same reason -- both must keep
  // working the same way regardless of which tab is active.
  const [ hoverIndex, setHoverIndex ] = useState<number | null>(null)

  const dashboard = useQuery({
    queryKey: [ "metrics_dashboard", window ],
    queryFn: () => fetchMetricsDashboard(window),
    placeholderData: keepPreviousData,
    refetchInterval: 60_000
  })

  // Merges into whatever is already in the URL rather than replacing it, so
  // switching the window doesn't drop the active tab and switching the tab
  // doesn't drop the window.
  function updateParam(key: string, value: string) {
    setSearchParams((previous) => {
      const next = new URLSearchParams(previous)
      next.set(key, value)
      return next
    })
  }

  if (dashboard.isPending) {
    return <main className="p-6 text-sm text-gray-500">{t("loading")}</main>
  }
  if (dashboard.isError) {
    return <main className="p-6 text-sm text-red-700">{errorMessage(dashboard.error, t("error"))}</main>
  }

  const payload = dashboard.data
  const activeTab = requestedTab && payload.categories.includes(requestedTab) ? requestedTab : payload.categories[0]
  const visiblePanels = payload.panels.filter((panel) => panel.category === activeTab)

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-[100rem] space-y-5 p-6">
      <header className="flex flex-wrap items-end justify-between gap-3 border-b border-gray-200 pb-4 dark:border-gray-700">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-gray-900 dark:text-gray-100">
            {t("heading")}
          </h1>
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("subheading")}</p>
        </div>
        <div className="flex items-center gap-1 rounded-lg border border-gray-200 bg-gray-50 p-1 dark:border-gray-700 dark:bg-gray-800">
          {payload.windows.map((option) => (
            <button
              aria-pressed={option === payload.window}
              className={`rounded px-3 py-1 text-sm font-medium transition ${
                option === payload.window
                  ? "bg-white text-gray-900 shadow-sm dark:bg-gray-900 dark:text-gray-100"
                  : "text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"
              }`}
              key={option}
              onClick={() => {
                setHoverIndex(null)
                updateParam("window", option)
              }}
              type="button"
            >
              {option}
            </button>
          ))}
        </div>
      </header>

      <RecordingNotice lastRecordedAt={payload.last_recorded_at} recording={payload.recording} />

      <nav aria-label={t("tabs_aria")} className="flex flex-wrap gap-1 border-b border-gray-200 dark:border-gray-700" role="tablist">
        {payload.categories.map((category) => (
          <button
            aria-selected={category === activeTab}
            className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium ${
              category === activeTab
                ? "border-brand text-brand dark:text-brand-emphasis"
                : "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900 dark:text-gray-400 dark:hover:border-gray-500 dark:hover:text-gray-100"
            }`}
            key={category}
            onClick={() => {
              setHoverIndex(null)
              updateParam(TAB_PARAM, category)
            }}
            role="tab"
            type="button"
          >
            {t(`tabs.${category}`)}
          </button>
        ))}
      </nav>

      <div className="grid gap-5 2xl:grid-cols-2" role="tabpanel">
        {visiblePanels.map((panel) => (
          <MetricsChart
            bucketSeconds={payload.bucket_seconds}
            buckets={payload.buckets}
            hoverIndex={hoverIndex}
            key={panel.key}
            onHover={setHoverIndex}
            panel={panel}
            title={t(`panels.${panel.key}`)}
          />
        ))}
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
    <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-900/60 dark:bg-amber-950/30 dark:text-amber-100">
      {lastRecordedAt
        ? t("stale_notice", { at: new Date(lastRecordedAt).toLocaleString() })
        : t("no_data_notice")}
    </div>
  )
}

export default MetricsDashboardRoute
