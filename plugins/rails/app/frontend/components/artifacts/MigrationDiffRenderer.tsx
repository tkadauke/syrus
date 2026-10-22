import type { ErdTable, MigrationDiffChange, MigrationDiffPayload } from "@app/api/artifacts"
import { useT } from "@app/hooks/useT"

// Renders a Rails migration diff as a two-column before/after table.
// Added columns are highlighted green, removed columns red, modified amber.
//
// payload comes from an agent-submitted typed artifact (submit_artifact
// accepts arbitrary JSON — see SyrusMcp::SubmitArtifactTool), so it isn't
// guaranteed to match MigrationDiffPayload at runtime: older workflow runs
// persisted a change-summary shape without a `column` object at all. Filter
// those out instead of letting `.column.name` throw and take down the whole
// route (see commit "Fix migration diff artifact crashing the Job detail
// page" for the same lesson applied to the backend side).
function hasColumn(change: MigrationDiffChange): change is MigrationDiffChange & { column: { name: string; type: string } } {
  return !!change.column && typeof change.column.name === "string"
}

export function MigrationDiffRenderer({ payload }: { payload: MigrationDiffPayload }) {
  const { t } = useT("syrus_rails")
  const { migration_name, before, after, changes: rawChanges } = payload
  const changes = (rawChanges ?? []).filter(hasColumn)
  const beforeColumns = before?.columns ?? []
  const afterColumns = after?.columns ?? []

  const changeMap = new Map(changes.map((c) => [c.column.name, c.type]))

  if (payload.status === "error") {
    return <Outcome tone="error" title={t("migration_error")} message={`${payload.stage ? `${payload.stage}: ` : ""}${payload.message ?? t("unknown")}`} />
  }
  if (payload.status === "no_schema_changes") {
    return <Outcome tone="neutral" title={t("migration_no_schema_changes")} message={payload.message} />
  }

  const beforeTables = before?.tables
  const afterTables = after?.tables
  if (before?.structure || after?.structure) {
    return (
      <div className="space-y-3">
        <div className="font-mono text-sm font-semibold text-text-primary">{migration_name}</div>
        {payload.cumulative && <Outcome tone="warning" title={t("migration_cumulative")} message={payload.message} />}
        <div className="grid min-w-[44rem] grid-cols-2 gap-4">
          <StructureStatements title={t("migration_removed_structure")} statements={before?.structure ?? []} />
          <StructureStatements title={t("migration_added_structure")} statements={after?.structure ?? []} />
        </div>
      </div>
    )
  }
  if (beforeTables || afterTables) {
    const names = Array.from(new Set([...(beforeTables ?? []).map((table) => table.name), ...(afterTables ?? []).map((table) => table.name)])).sort()
    return (
      <div className="min-w-full space-y-3">
        <div className="font-mono text-sm font-semibold text-gray-700">{migration_name}</div>
        {payload.cumulative && <Outcome tone="warning" title={t("migration_cumulative")} message={payload.message} />}
        {names.map((name) => (
          <div key={name} className="grid min-w-[44rem] grid-cols-2 gap-4">
            <CatalogTable title={t("migration_before")} table={beforeTables?.find((table) => table.name === name)} name={name} />
            <CatalogTable title={t("migration_after")} table={afterTables?.find((table) => table.name === name)} name={name} />
          </div>
        ))}
      </div>
    )
  }

  return (
    <div className="w-max min-w-full space-y-3">
      <div className="font-mono text-sm font-semibold text-gray-700">{migration_name}</div>
      <div className="grid w-max min-w-full grid-cols-[minmax(22rem,1fr)_minmax(22rem,1fr)] gap-4">
        <ColumnTable title={t("migration_before")} tableName={before?.table_name} columns={beforeColumns} changeMap={changeMap} side="before" />
        <ColumnTable title={t("migration_after")} tableName={after?.table_name} columns={afterColumns} changeMap={changeMap} side="after" />
      </div>
      {changes.length > 0 && (
        <div className="space-y-1">
          <div className="text-xs font-semibold uppercase tracking-wide text-gray-500">{t("migration_changes")}</div>
          <ul className="space-y-0.5">
            {changes.map((change) => (
              <li key={`${change.type}-${change.column.name}`} className="flex items-center gap-2 text-sm">
                <ChangePill type={change.type} />
                <span className="font-mono text-gray-800">{change.column.name}</span>
                <span className="text-xs text-gray-500">{change.column.type}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

function StructureStatements({ title, statements }: { title: string; statements: string[] }) {
  const { t } = useT("syrus_rails")
  return (
    <div className="rounded border border-border">
      <div className="bg-surface-raised px-3 py-1.5 text-xs font-semibold uppercase text-text-secondary">{title}</div>
      <div className="space-y-2 p-3">
        {statements.length === 0 ? (
          <div className="text-sm italic text-text-secondary">{t("migration_no_structure_statements")}</div>
        ) : (
          statements.map((statement, index) => (
            <pre key={index} className="whitespace-pre-wrap break-words text-xs text-text-secondary">
              {statement};
            </pre>
          ))
        )}
      </div>
    </div>
  )
}

function Outcome({ tone, title, message }: { tone: "error" | "warning" | "neutral"; title: string; message?: string }) {
  const colors =
    tone === "error"
      ? "border-danger bg-danger-surface text-danger-text"
      : tone === "warning"
        ? "border-warning bg-warning-surface text-warning-text"
        : "border-border bg-surface-subtle text-text-secondary"
  return (
    <div role={tone === "error" ? "alert" : "status"} className={`rounded border px-3 py-2 ${colors}`}>
      <div className="font-semibold">{title}</div>
      {message && <div className="mt-1 text-sm">{message}</div>}
    </div>
  )
}

function CatalogTable({ title, table, name }: { title: string; table?: ErdTable; name: string }) {
  const { t } = useT("syrus_rails")
  return (
    <div className="rounded border border-border text-sm">
      <div className="bg-surface-raised px-3 py-1.5">
        <span className="text-xs font-semibold uppercase text-text-secondary">{title} — </span>
        <span className="font-mono">{name}</span>
      </div>
      {table ? (
        <div className="divide-y divide-border">
          {table.columns.map((column) => (
            <div key={column.name} className="flex justify-between gap-3 px-3 py-1 font-mono">
              <span>{column.name}</span>
              <span className="text-right text-xs text-text-secondary">
                {column.sql_type ?? column.type}
                {column.nullable === false ? " · NOT NULL" : ""}
                {column.default != null ? ` · default ${String(column.default)}` : ""}
              </span>
            </div>
          ))}
          {table.indexes?.map((index) => (
            <div key={`index-${index.name}`} className="px-3 py-1 text-xs text-text-secondary">
              {t("migration_index")}:{" "}
              <span className="font-mono">
                {index.name ?? index.columns.join("_")} ({index.columns.join(", ")}){index.unique ? " UNIQUE" : ""}
              </span>
            </div>
          ))}
          {table.foreign_keys?.map((key) => (
            <div key={`fk-${key.from_column}-${key.to_table}`} className="px-3 py-1 text-xs text-text-secondary">
              {t("foreign_key")}:{" "}
              <span className="font-mono">
                {key.from_column} → {key.to_table}.{key.to_column}
              </span>
            </div>
          ))}
          {table.check_constraints?.map((check, index) => (
            <div key={`check-${check.name ?? index}`} className="px-3 py-1 text-xs text-text-secondary">
              {t("migration_check")}:{" "}
              <span className="font-mono">
                {check.name ? `${check.name}: ` : ""}
                {check.expression}
              </span>
            </div>
          ))}
        </div>
      ) : (
        <div className="px-3 py-3 text-sm italic text-text-secondary">{t("migration_absent")}</div>
      )}
    </div>
  )
}

function ColumnTable({
  title,
  tableName,
  columns,
  changeMap,
  side
}: {
  title: string
  tableName: string | undefined
  columns: Array<{ name: string; type: string }>
  changeMap: Map<string, string>
  side: "before" | "after"
}) {
  return (
    <div className="min-w-0 rounded border border-gray-200 text-sm">
      <div className="rounded-t bg-gray-100 px-3 py-1.5">
        <span className="text-xs font-semibold uppercase tracking-wide text-gray-500">{title} — </span>
        <span className="font-mono text-gray-700">{tableName}</span>
      </div>
      <table className="w-full border-collapse">
        <tbody>
          {columns.map((col, i) => {
            const changeType = changeMap.get(col.name)
            const rowClass = rowHighlight(changeType, side, i)
            return (
              <tr key={col.name} className={rowClass}>
                <td className="whitespace-nowrap px-3 py-0.5 font-mono">{col.name}</td>
                <td className="whitespace-nowrap px-3 py-0.5 text-right font-mono text-xs text-text-secondary">{col.type}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function rowHighlight(changeType: string | undefined, side: "before" | "after", index: number): string {
  const base = index % 2 === 0 ? "bg-white" : "bg-gray-50"
  if (!changeType) return base
  if (changeType === "added" && side === "after") return "bg-success-bg"
  if (changeType === "removed" && side === "before") return "bg-danger-bg"
  if (changeType === "modified") return "bg-warning-bg"
  return base
}

function ChangePill({ type }: { type: string }) {
  const { t } = useT("syrus_rails")
  if (type === "added") {
    return <span className="rounded bg-success-surface px-1.5 py-0.5 text-xs font-semibold text-success-text">{t("change_added")}</span>
  }
  if (type === "removed") {
    return <span className="rounded bg-danger-surface px-1.5 py-0.5 text-xs font-semibold text-danger-text">{t("change_removed")}</span>
  }
  return <span className="rounded bg-warning-surface px-1.5 py-0.5 text-xs font-semibold text-warning-text">{t("change_modified")}</span>
}
