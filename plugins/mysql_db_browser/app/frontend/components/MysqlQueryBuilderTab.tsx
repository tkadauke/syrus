import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useMemo, useState, type ReactNode } from "react"
import { useLocation } from "react-router-dom"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { fetchMysqlTableDetail, fetchMysqlTables, type MysqlColumn, type MysqlForeignKey } from "../api/mysqlSchema"
import { fetchMysqlQueryBuilderResult, type MysqlBuilderAggregation, type MysqlBuilderJoin, type MysqlBuilderSort, type MysqlQueryBuilderSpec } from "../api/mysqlQuery"
import { MysqlPickerDropdown, type MysqlPickerOption } from "./MysqlPickerDropdown"
import { MysqlResultsGrid } from "./MysqlResultsGrid"
import { MysqlQueryErrorPanel } from "./MysqlQueryResultPanel"

const AGGREGATE_FUNCTIONS: MysqlBuilderAggregation["function"][] = ["count", "sum", "avg", "min", "max"]

function qualify(table: string, column: string) {
  return `${table}.${column}`
}

// Mirrors MysqlDbBrowser::QueryBuilderCompiler#alias_for so the sort step's
// options match the aliases the server will actually generate.
function aggregationAlias(aggregation: MysqlBuilderAggregation): string {
  if (aggregation.alias) return aggregation.alias
  if (aggregation.column === "*") return "row_count"
  return `${aggregation.function}_${aggregation.column.split(".")[1] ?? aggregation.column}`
}

// Given the table currently selected as the join target, resolves which
// side of a (possibly reversed) foreign key row belongs to that table vs.
// the other one - so the join picker can offer both outgoing and incoming
// relationships without the caller worrying about direction.
function joinFromForeignKey(base: string, fk: MysqlForeignKey): MysqlBuilderJoin {
  const baseIsFrom = fk.from_table === base
  const otherTable = baseIsFrom ? fk.to_table : fk.from_table
  const baseColumn = baseIsFrom ? fk.from_column : fk.to_column
  const otherColumn = baseIsFrom ? fk.to_column : fk.from_column
  return { table: otherTable, type: "left", from_column: qualify(base, baseColumn), to_column: qualify(otherTable, otherColumn) }
}

// Metabase-notebook-style step sequence: pick a table, pick columns or an
// aggregate/group-by summary, optionally join another table via a foreign
// key the schema explorer already surfaced, filter (via FilterBar, exactly
// like the Content tab), then sort and limit. Compiles server-side to SQL
// (MysqlDbBrowser::QueryBuilderCompiler) and renders through the same
// results grid as Content/Query.
export function MysqlQueryBuilderTab({ connectionId, database, table }: { connectionId: number; database: string; table: string }) {
  const { t } = useT("mysql_db_browser")
  const location = useLocation()
  const [builderTable, setBuilderTable] = useState(table)
  const [mode, setMode] = useState<"columns" | "summarize">("columns")
  const [columns, setColumns] = useState<string[]>([])
  const [aggregations, setAggregations] = useState<MysqlBuilderAggregation[]>([])
  const [groupBy, setGroupBy] = useState<string[]>([])
  const [join, setJoin] = useState<MysqlBuilderJoin | null>(null)
  const [sort, setSort] = useState<MysqlBuilderSort | null>(null)
  const [limit, setLimit] = useState(100)
  const filterQ = new URLSearchParams(location.search).get("q") ?? undefined

  function selectBuilderTable(next: string) {
    setBuilderTable(next)
    setColumns([])
    setAggregations([])
    setGroupBy([])
    setJoin(null)
    setSort(null)
  }

  const tables = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "tables", database],
    queryFn: () => fetchMysqlTables(connectionId, database)
  })

  const baseDetail = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "table", database, builderTable],
    queryFn: () => fetchMysqlTableDetail(connectionId, database, builderTable)
  })

  const joinDetail = useQuery({
    queryKey: ["mysql_db_browser", "schema", connectionId, "table", database, join?.table],
    queryFn: () => fetchMysqlTableDetail(connectionId, database, join?.table ?? ""),
    enabled: Boolean(join)
  })

  const baseColumns: MysqlColumn[] = baseDetail.data?.columns.available ? baseDetail.data.columns.rows : []
  const joinColumns: MysqlColumn[] = join && joinDetail.data?.columns.available ? joinDetail.data.columns.rows : []
  const foreignKeys: MysqlForeignKey[] = baseDetail.data?.foreign_keys.available ? baseDetail.data.foreign_keys.rows : []
  const relevantForeignKeys = foreignKeys.filter((fk) => fk.from_table === builderTable || fk.to_table === builderTable)

  const columnOptions: MysqlPickerOption[] = [
    ...baseColumns.map((column) => ({ value: qualify(builderTable, column.name), label: qualify(builderTable, column.name) })),
    ...(join ? joinColumns.map((column) => ({ value: qualify(join.table, column.name), label: qualify(join.table, column.name) })) : [])
  ]

  const spec: MysqlQueryBuilderSpec = useMemo(() => {
    const next: MysqlQueryBuilderSpec = { table: builderTable, limit }
    if (mode === "summarize") {
      next.aggregations = aggregations
      next.group_by = groupBy
    } else if (columns.length > 0) {
      next.columns = columns
    }
    if (join) next.join = join
    if (sort) next.sort = sort
    return next
  }, [builderTable, mode, columns, aggregations, groupBy, join, sort, limit])

  const specValid =
    Boolean(builderTable) &&
    (mode !== "summarize" || aggregations.length > 0) &&
    (!join || Boolean(join.table && join.from_column && join.to_column))

  const result = useQuery({
    queryKey: ["mysql_db_browser", "query_builder", connectionId, database, JSON.stringify(spec), filterQ],
    queryFn: () => fetchMysqlQueryBuilderResult(connectionId, database, spec, { q: filterQ }),
    enabled: specValid,
    placeholderData: keepPreviousData
  })

  function toggleColumn(ref: string) {
    setColumns((current) => (current.includes(ref) ? current.filter((c) => c !== ref) : [...current, ref]))
  }

  function toggleGroupBy(ref: string) {
    setGroupBy((current) => (current.includes(ref) ? current.filter((c) => c !== ref) : [...current, ref]))
  }

  function addAggregation() {
    setAggregations((current) => [...current, { function: "count", column: "*" }])
  }

  function updateAggregation(index: number, changes: Partial<MysqlBuilderAggregation>) {
    setAggregations((current) => current.map((aggregation, i) => (i === index ? { ...aggregation, ...changes } : aggregation)))
  }

  function removeAggregation(index: number) {
    setAggregations((current) => current.filter((_, i) => i !== index))
  }

  const sortOptions: MysqlPickerOption[] =
    mode === "summarize"
      ? [
          ...aggregations.map((aggregation) => ({ value: aggregationAlias(aggregation), label: aggregationAlias(aggregation) })),
          ...groupBy.map((ref) => ({ value: ref, label: ref }))
        ]
      : columns.length > 0
        ? columns.map((ref) => ({ value: ref, label: ref }))
        : columnOptions

  return (
    <section aria-label={t("aria_builder_tab")} className="space-y-4 p-4">
      <BuilderStep heading={t("builder_step_table")}>
        <MysqlPickerDropdown
          ariaLabel={t("builder_step_table")}
          onChange={selectBuilderTable}
          options={tables.data?.available ? tables.data.tables.map((row) => ({ value: row.name, label: row.name })) : []}
          placeholder={tables.isPending ? t("builder_loading_tables") : t("builder_step_table")}
          value={builderTable}
        />
      </BuilderStep>

      {baseDetail.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">{t("builder_loading_columns")}</p> : null}
      {baseDetail.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(baseDetail.error, t("builder_error_loading_columns"))}</p> : null}

      {baseDetail.isSuccess ? (
        <>
          <BuilderStep heading={t("builder_step_mode")}>
            <div className="flex gap-2">
              <ModeButton active={mode === "columns"} onClick={() => setMode("columns")}>{t("builder_mode_columns")}</ModeButton>
              <ModeButton active={mode === "summarize"} onClick={() => setMode("summarize")}>{t("builder_mode_summarize")}</ModeButton>
            </div>
          </BuilderStep>

          {mode === "columns" ? (
            <BuilderStep heading={t("builder_step_columns")}>
              <p className="mb-1 text-xs text-gray-500 dark:text-gray-400">{t("builder_columns_hint")}</p>
              <ColumnChecklist onToggle={toggleColumn} options={columnOptions} selected={columns} />
            </BuilderStep>
          ) : (
            <>
              <BuilderStep heading={t("builder_step_aggregations")}>
                <div className="space-y-2">
                  {aggregations.map((aggregation, index) => (
                    <div className="flex flex-wrap items-center gap-2" key={index}>
                      <MysqlPickerDropdown
                        ariaLabel={t("builder_aggregation_function_label")}
                        onChange={(value) =>
                          updateAggregation(index, {
                            function: value as MysqlBuilderAggregation["function"],
                            column: value === "count" ? aggregation.column : aggregation.column === "*" ? "" : aggregation.column
                          })
                        }
                        options={AGGREGATE_FUNCTIONS.map((fn) => ({ value: fn, label: t(`builder_function_${fn}`) }))}
                        placeholder={t("builder_aggregation_function_label")}
                        value={aggregation.function}
                      />
                      <MysqlPickerDropdown
                        ariaLabel={t("builder_aggregation_column_label")}
                        onChange={(value) => updateAggregation(index, { column: value })}
                        options={
                          aggregation.function === "count"
                            ? [{ value: "*", label: t("builder_aggregation_all_rows") }, ...columnOptions]
                            : columnOptions
                        }
                        placeholder={t("builder_aggregation_column_label")}
                        value={aggregation.column || null}
                      />
                      <input
                        className="w-32 rounded border border-gray-300 bg-white px-2 py-1 text-xs text-gray-700 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200"
                        onChange={(event) => updateAggregation(index, { alias: event.target.value || undefined })}
                        placeholder={aggregationAlias(aggregation)}
                        type="text"
                        value={aggregation.alias ?? ""}
                      />
                      <button
                        className="text-xs text-red-700 hover:underline dark:text-red-300"
                        onClick={() => removeAggregation(index)}
                        type="button"
                      >
                        {t("builder_remove_aggregation")}
                      </button>
                    </div>
                  ))}
                  <button
                    className="rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
                    onClick={addAggregation}
                    type="button"
                  >
                    {t("builder_add_aggregation")}
                  </button>
                </div>
              </BuilderStep>

              <BuilderStep heading={t("builder_step_group_by")}>
                <ColumnChecklist onToggle={toggleGroupBy} options={columnOptions} selected={groupBy} />
              </BuilderStep>
            </>
          )}

          <BuilderStep heading={t("builder_step_join")}>
            <div className="flex flex-wrap items-center gap-2">
              <MysqlPickerDropdown
                ariaLabel={t("builder_step_join")}
                onChange={(value) => {
                  if (!value) {
                    setJoin(null)
                    return
                  }
                  const fk = relevantForeignKeys[Number(value)]
                  if (fk) setJoin(joinFromForeignKey(builderTable, fk))
                }}
                options={[
                  { value: "", label: t("builder_join_none") },
                  ...relevantForeignKeys.map((fk, index) => ({ value: String(index), label: `${fk.from_table}.${fk.from_column} → ${fk.to_table}.${fk.to_column}` }))
                ]}
                placeholder={t("builder_join_none")}
                value={join ? String(relevantForeignKeys.findIndex((fk) => joinFromForeignKey(builderTable, fk).table === join.table && joinFromForeignKey(builderTable, fk).from_column === join.from_column && joinFromForeignKey(builderTable, fk).to_column === join.to_column)) : ""}
              />
              {relevantForeignKeys.length === 0 ? <p className="text-xs text-gray-500 dark:text-gray-400">{t("builder_no_foreign_keys")}</p> : null}
              {join ? (
                <>
                  <ModeButton active={join.type === "left"} onClick={() => setJoin({ ...join, type: "left" })}>{t("builder_join_type_left")}</ModeButton>
                  <ModeButton active={join.type === "inner"} onClick={() => setJoin({ ...join, type: "inner" })}>{t("builder_join_type_inner")}</ModeButton>
                  <button className="text-xs text-red-700 hover:underline dark:text-red-300" onClick={() => setJoin(null)} type="button">
                    {t("builder_remove_join")}
                  </button>
                </>
              ) : null}
            </div>
          </BuilderStep>

          <BuilderStep heading={t("builder_step_filter")}>
            <FilterBar
              filter={result.data?.filter ?? null}
              filterSchema={result.data?.filter_schema ?? []}
              pathname={location.pathname}
              search={location.search}
            />
          </BuilderStep>

          <BuilderStep heading={t("builder_step_sort")}>
            <div className="flex items-center gap-2">
              <MysqlPickerDropdown
                ariaLabel={t("builder_step_sort")}
                onChange={(value) => setSort(value ? { column: value, direction: sort?.direction ?? "asc" } : null)}
                options={[{ value: "", label: t("builder_sort_none") }, ...sortOptions]}
                placeholder={t("builder_sort_none")}
                value={sort?.column ?? ""}
              />
              {sort ? (
                <>
                  <ModeButton active={sort.direction === "asc"} onClick={() => setSort({ ...sort, direction: "asc" })}>{t("builder_sort_direction_asc")}</ModeButton>
                  <ModeButton active={sort.direction === "desc"} onClick={() => setSort({ ...sort, direction: "desc" })}>{t("builder_sort_direction_desc")}</ModeButton>
                </>
              ) : null}
            </div>
          </BuilderStep>

          <BuilderStep heading={t("builder_step_limit")}>
            <input
              className="w-24 rounded border border-gray-300 bg-white px-2 py-1 text-xs text-gray-700 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200"
              max={500}
              min={1}
              onChange={(event) => setLimit(Math.max(1, Math.min(500, Number(event.target.value) || 1)))}
              type="number"
              value={limit}
            />
          </BuilderStep>

          {result.data?.statement ? (
            <div>
              <h4 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("builder_sql_heading")}</h4>
              <pre className="mt-1 overflow-x-auto rounded border border-gray-200 bg-gray-50 p-2 text-xs text-gray-700 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-300">
                {result.data.statement}
              </pre>
            </div>
          ) : null}

          {result.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(result.error, t("query_error_fallback"))}</p> : null}
          {result.data && !result.data.available ? <MysqlQueryErrorPanel error={result.data.error} /> : null}
          {result.data?.available ? (
            <MysqlResultsGrid columns={result.data.columns} rows={result.data.rows} />
          ) : null}
        </>
      ) : null}
    </section>
  )
}

function BuilderStep({ children, heading }: { children: ReactNode; heading: string }) {
  return (
    <div>
      <h4 className="mb-1 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{heading}</h4>
      {children}
    </div>
  )
}

function ModeButton({ active, children, onClick }: { active: boolean; children: ReactNode; onClick: () => void }) {
  return (
    <button
      aria-pressed={active}
      className={`rounded border px-2.5 py-1 text-xs font-medium ${
        active
          ? "border-brand bg-brand/10 text-brand dark:text-brand-emphasis"
          : "border-gray-300 text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
      }`}
      onClick={onClick}
      type="button"
    >
      {children}
    </button>
  )
}

function ColumnChecklist({ onToggle, options, selected }: { onToggle: (ref: string) => void; options: MysqlPickerOption[]; selected: string[] }) {
  const { t } = useT("mysql_db_browser")

  if (options.length === 0) {
    return <p className="text-xs text-gray-500 dark:text-gray-400">{t("builder_loading_columns")}</p>
  }

  return (
    <div className="flex flex-wrap gap-x-4 gap-y-1">
      {options.map((option) => (
        <label className="flex items-center gap-1.5 text-xs text-gray-700 dark:text-gray-300" key={option.value}>
          <input
            checked={selected.includes(option.value)}
            className="rounded border-gray-300 dark:border-gray-600"
            onChange={() => onToggle(option.value)}
            type="checkbox"
          />
          <span className="font-mono">{option.label}</span>
        </label>
      ))}
    </div>
  )
}
