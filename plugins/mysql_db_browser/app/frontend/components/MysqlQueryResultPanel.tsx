import { useT } from "@app/hooks/useT"
import { MysqlResultsGrid, type MysqlGridSort } from "./MysqlResultsGrid"
import type { MysqlQueryErrorPayload, MysqlQueryResult } from "../api/mysqlQuery"

// Shared success/error rendering for a QueryExecutor payload - used by the
// raw Query tab and the Live-diagnostics tab, both of which just run a SQL
// string and show what came back.
export function MysqlQueryResultPanel({ result, sort, onSort }: { result: MysqlQueryResult; sort?: MysqlGridSort | null; onSort?: (column: string) => void }) {
  const { t } = useT("mysql_db_browser")

  if (!result.available) {
    return <MysqlQueryErrorPanel error={result.error} />
  }

  return (
    <div className="space-y-2">
      <p className="text-xs text-gray-500 dark:text-gray-400">
        {result.read_only
          ? t("query_meta_read", { count: result.row_count, ms: result.duration_ms })
          : t("query_meta_write", { count: result.affected_rows ?? 0, ms: result.duration_ms })}
        {result.truncated ? ` · ${t("query_truncated")}` : ""}
      </p>
      <MysqlResultsGrid columns={result.columns} onSort={onSort} rows={result.rows} sort={sort} />
    </div>
  )
}

export function MysqlQueryErrorPanel({ error }: { error?: MysqlQueryErrorPayload }) {
  const { t } = useT("mysql_db_browser")

  return (
    <div className="space-y-2 rounded border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">
      <p className="font-medium">{error?.message || t("query_error_fallback")}</p>
      {error?.hint ? <p>{error.hint}</p> : null}
    </div>
  )
}
