import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { executeMysqlQuery } from "../api/mysqlQuery"
import { MysqlQueryResultPanel } from "./MysqlQueryResultPanel"

// Generalizes AdminMysql.tsx's process-list/global-status/slow-log views
// (built for Syrus's own database) to any registered connection. Each is
// just a plain SELECT against a system table/schema the schema explorer
// already treats as browsable - so this is the Query tab with a canned
// statement and 10s auto-refresh, not bespoke controller/service code.
const CANNED_QUERIES = [
  { id: "process_list", labelKey: "live_process_list", sql: "SELECT * FROM information_schema.PROCESSLIST ORDER BY TIME DESC" },
  { id: "global_status", labelKey: "live_global_status", sql: "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status ORDER BY VARIABLE_NAME" },
  { id: "slow_log", labelKey: "live_slow_log", sql: "SELECT * FROM mysql.slow_log ORDER BY start_time DESC LIMIT 50" }
] as const

export function MysqlLiveTab({ connectionId }: { connectionId: number }) {
  const { t } = useT("mysql_db_browser")
  const [selectedId, setSelectedId] = useState<(typeof CANNED_QUERIES)[number]["id"]>(CANNED_QUERIES[0].id)
  const canned = CANNED_QUERIES.find((query) => query.id === selectedId) ?? CANNED_QUERIES[0]
  const live = useQuery({
    queryKey: ["mysql_db_browser", "live", connectionId, selectedId],
    queryFn: () => executeMysqlQuery(connectionId, canned.sql),
    refetchInterval: 10_000
  })

  return (
    <section aria-label={t("aria_live_tab")} className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap gap-2" role="tablist">
          {CANNED_QUERIES.map((query) => (
            <button
              aria-selected={query.id === selectedId}
              className={`rounded border px-3 py-1.5 text-sm font-medium ${
                query.id === selectedId
                  ? "border-brand bg-brand/10 text-brand dark:border-brand/70 dark:text-brand-emphasis"
                  : "border-gray-300 text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              }`}
              key={query.id}
              onClick={() => setSelectedId(query.id)}
              role="tab"
              type="button"
            >
              {t(query.labelKey)}
            </button>
          ))}
        </div>
        <p className="text-xs text-gray-500 dark:text-gray-400">{t("live_auto_refresh")}</p>
      </div>

      {live.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">{t("query_running")}</p> : null}
      {live.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(live.error, t("query_error_fallback"))}</p> : null}
      {live.data ? <MysqlQueryResultPanel result={live.data} /> : null}
    </section>
  )
}
