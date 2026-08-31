import type { ErdTable, SchemaErdPayload } from "../../api/artifacts"

// Renders a Rails schema ERD as a set of table boxes with column lists
// and a textual foreign-key summary below each table. One box per table,
// stacked vertically; FK arrows are listed as text rather than SVG lines
// to keep the implementation portable across rendering contexts.
export function ErdDiagramRenderer({ payload }: { payload: SchemaErdPayload }) {
  const tables = Array.isArray(payload?.tables) ? payload.tables : []
  if (tables.length === 0) {
    return <p className="text-sm text-gray-500 italic">No tables found in schema.</p>
  }

  return (
    <div className="flex flex-wrap gap-4">
      {tables.map((table) => (
        <ErdTableBox key={table.name} table={table} />
      ))}
    </div>
  )
}

function ErdTableBox({ table }: { table: ErdTable }) {
  const columns = Array.isArray(table.columns) ? table.columns : []
  const foreignKeys = Array.isArray(table.foreign_keys) ? table.foreign_keys : []
  const indexes = Array.isArray(table.indexes) ? table.indexes : []
  const hasFks = foreignKeys.length > 0

  return (
    <div className="min-w-[200px] rounded border border-gray-300 bg-white text-sm shadow-sm">
      <div className="rounded-t bg-brand-emphasis px-3 py-1.5 font-mono font-semibold text-white">
        {table.name}
      </div>
      <table className="w-full border-collapse">
        <tbody>
          {columns.map((col, i) => {
            const isFkSource = foreignKeys.some((fk) => fk.from_column === col.name)
            return (
              <tr key={col.name} className={i % 2 === 0 ? "bg-white" : "bg-gray-50"}>
                <td className="px-3 py-0.5 font-mono text-gray-800">
                  {col.name}
                  {isFkSource && (
                    <span className="ml-1 text-brand" title="foreign key">
                      ↗
                    </span>
                  )}
                </td>
                <td className="px-3 py-0.5 text-right font-mono text-xs text-gray-500">{col.type}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {hasFks && (
        <div className="border-t border-gray-200 px-3 py-1.5">
          {foreignKeys.map((fk) => (
            <div key={fk.from_column} className="text-xs text-gray-500">
              <span className="font-mono text-gray-700">{fk.from_column}</span>
              {" → "}
              <span className="font-mono text-gray-700">
                {fk.to_table}.{fk.to_column}
              </span>
            </div>
          ))}
        </div>
      )}
      {indexes.length > 0 && (
        <div className="border-t border-gray-100 px-3 py-1 text-xs text-gray-400">
          {indexes.map((idx, i) => {
            const indexColumns = Array.isArray(idx.columns) ? idx.columns : []
            const indexLabel = indexColumns.length > 0 ? indexColumns.join(", ") : (idx.name ?? "unknown")
            return (
              <div key={idx.name ?? i}>
                {idx.unique ? "unique " : ""}idx: {indexLabel}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
