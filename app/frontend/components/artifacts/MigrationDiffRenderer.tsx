import type { MigrationDiffPayload } from "../../api/jobs"

// Renders a Rails migration diff as a two-column before/after table.
// Added columns are highlighted green, removed columns red, modified amber.
export function MigrationDiffRenderer({ payload }: { payload: MigrationDiffPayload }) {
  const { migration_name, before, after, changes } = payload

  const changeMap = new Map(changes.map((c) => [c.column.name, c.type]))

  return (
    <div className="space-y-3">
      <div className="font-mono text-sm font-semibold text-gray-700">{migration_name}</div>
      <div className="grid grid-cols-2 gap-4">
        <ColumnTable title="Before" tableName={before.table_name} columns={before.columns} changeMap={changeMap} side="before" />
        <ColumnTable title="After" tableName={after.table_name} columns={after.columns} changeMap={changeMap} side="after" />
      </div>
      {changes.length > 0 && (
        <div className="space-y-1">
          <div className="text-xs font-semibold uppercase tracking-wide text-gray-500">Changes</div>
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

function ColumnTable({
  title,
  tableName,
  columns,
  changeMap,
  side
}: {
  title: string
  tableName: string
  columns: Array<{ name: string; type: string }>
  changeMap: Map<string, string>
  side: "before" | "after"
}) {
  return (
    <div className="rounded border border-gray-200 text-sm">
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
                <td className="px-3 py-0.5 font-mono">{col.name}</td>
                <td className="px-3 py-0.5 text-right font-mono text-xs text-gray-500">{col.type}</td>
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
  if (changeType === "added" && side === "after") return "bg-emerald-50"
  if (changeType === "removed" && side === "before") return "bg-red-50"
  if (changeType === "modified") return "bg-amber-50"
  return base
}

function ChangePill({ type }: { type: string }) {
  if (type === "added") {
    return <span className="rounded bg-emerald-100 px-1.5 py-0.5 text-xs font-semibold text-emerald-700">added</span>
  }
  if (type === "removed") {
    return <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-semibold text-red-700">removed</span>
  }
  return <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-semibold text-amber-700">modified</span>
}
