import { useMutation } from "@tanstack/react-query"
import { useState, type FormEvent } from "react"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { executeMysqlQuery } from "../api/mysqlQuery"
import { MysqlQueryResultPanel } from "./MysqlQueryResultPanel"

// Raw SQL editor running through the same guardrailed execution endpoint as
// the Content tab. A manual "Run" action (useMutation), not a declarative
// query - re-running the same statement should always hit the server again.
export function MysqlQueryTab({ connectionId }: { connectionId: number }) {
  const { t } = useT("mysql_db_browser")
  const [sql, setSql] = useState("")
  const run = useMutation({ mutationFn: (statement: string) => executeMysqlQuery(connectionId, statement) })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (sql.trim()) run.mutate(sql)
  }

  return (
    <section aria-label={t("aria_query_tab")} className="space-y-3">
      <form onSubmit={submit}>
        <label className="sr-only" htmlFor="mysql-query-sql">{t("query_sql_label")}</label>
        <textarea
          className="block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 font-mono text-sm text-gray-900 dark:text-gray-100"
          id="mysql-query-sql"
          onChange={(event) => setSql(event.target.value)}
          placeholder={t("query_sql_placeholder")}
          rows={8}
          value={sql}
        />
        <div className="mt-2 flex items-center gap-3">
          <button
            className="rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-500 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={run.isPending || !sql.trim()}
            type="submit"
          >
            {run.isPending ? t("query_running") : t("query_run")}
          </button>
          <p className="text-xs text-gray-500 dark:text-gray-400">{t("query_read_only_hint")}</p>
        </div>
      </form>

      {run.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(run.error, t("query_error_fallback"))}</p> : null}
      {run.data ? <MysqlQueryResultPanel result={run.data} /> : null}
    </section>
  )
}
