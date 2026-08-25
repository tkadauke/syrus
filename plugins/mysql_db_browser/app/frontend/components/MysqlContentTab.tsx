import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { useLocation } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { fetchMysqlTableContent } from "../api/mysqlQuery"
import { MysqlResultsGrid, type MysqlGridSort } from "./MysqlResultsGrid"
import { MysqlQueryErrorPanel } from "./MysqlQueryResultPanel"

const PER_PAGE = 50

// Grid-first default view for a selected table. Filtering reuses FilterBar
// verbatim (URL-driven `q` param, like every other FilterBar consumer);
// the filterSchema it renders from comes straight from the content
// response, which derives it from the table's introspected columns
// (MysqlDbBrowser::FilterSchemaBuilder) - no bespoke filter-chip UI here.
export function MysqlContentTab({ connectionId, database, table }: { connectionId: number; database: string; table: string }) {
  const { t } = useT("mysql_db_browser")
  const location = useLocation()
  const [sort, setSort] = useState<MysqlGridSort | null>(null)
  const [page, setPage] = useState(1)
  const filterQ = new URLSearchParams(location.search).get("q") ?? undefined

  const content = useQuery({
    queryKey: ["mysql_db_browser", "content", connectionId, database, table, filterQ, sort?.column, sort?.direction, page],
    queryFn: () => fetchMysqlTableContent(connectionId, database, table, {
      q: filterQ,
      sort_by: sort?.column,
      sort_dir: sort?.direction,
      page,
      per_page: PER_PAGE
    }),
    placeholderData: keepPreviousData
  })

  function onSort(column: string) {
    setPage(1)
    setSort((current) => (current?.column === column ? { column, direction: current.direction === "asc" ? "desc" : "asc" } : { column, direction: "asc" }))
  }

  return (
    <section aria-label={t("aria_content_tab")} className="space-y-3 p-4">
      <FilterBar
        filter={content.data?.filter ?? null}
        filterSchema={content.data?.filter_schema ?? []}
        onFilterApplied={() => setPage(1)}
        pathname={location.pathname}
        search={location.search}
      />

      {content.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">{t("content_loading")}</p> : null}
      {content.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(content.error, t("content_error_fallback"))}</p> : null}
      {content.data && !content.data.available ? <MysqlQueryErrorPanel error={content.data.error} /> : null}
      {content.data?.available ? (
        <>
          <MysqlResultsGrid columns={content.data.columns} onSort={onSort} rows={content.data.rows} sort={sort} />
          <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
            <span>{t("content_page", { page })}</span>
            <div className="flex gap-2">
              <button
                className={`rounded border px-3 py-1 ${page <= 1 ? "border-gray-200 text-gray-300 dark:border-gray-800 dark:text-gray-700" : "border-gray-300 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"}`}
                disabled={page <= 1}
                onClick={() => setPage((current) => Math.max(1, current - 1))}
                type="button"
              >
                {t("content_prev")}
              </button>
              <button
                className={`rounded border px-3 py-1 ${!content.data.has_more ? "border-gray-200 text-gray-300 dark:border-gray-800 dark:text-gray-700" : "border-gray-300 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"}`}
                disabled={!content.data.has_more}
                onClick={() => setPage((current) => current + 1)}
                type="button"
              >
                {t("content_next")}
              </button>
            </div>
          </div>
        </>
      ) : null}
    </section>
  )
}
