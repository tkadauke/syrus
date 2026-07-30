import type { ErdTable, SchemaErdPayload } from "../../api/jobs"

// Renders a Rails schema ERD as a set of table boxes with column lists
// and a textual foreign-key summary below each table. One box per table,
// stacked vertically; FK arrows are listed as text rather than SVG lines
// to keep the implementation portable across rendering contexts.
export function ErdDiagramRenderer({ payload }: { payload: SchemaErdPayload }) {
  const { tables } = payload
  if (!tables || tables.length === 0) {
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
  const hasFks = table.foreign_keys && table.foreign_keys.length > 0

  return (
    <div className="min-w-[200px] rounded border border-gray-300 bg-white text-sm shadow-sm">
      <div className="rounded-t bg-terracotta-700 px-3 py-1.5 font-mono font-semibold text-white">
        {table.name}
      </div>
      <table className="w-full border-collapse">
        <tbody>
          {table.columns.map((col, i) => {
            const isFkSource = table.foreign_keys?.some((fk) => fk.from_column === col.name)
            return (
              <tr key={col.name} className={i % 2 === 0 ? "bg-white" : "bg-gray-50"}>
                <td className="px-3 py-0.5 font-mono text-gray-800">
                  {col.name}
                  {isFkSource && (
                    <span className="ml-1 text-terracotta-600" title="foreign key">
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
          {table.foreign_keys!.map((fk) => (
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
      {table.indexes && table.indexes.length > 0 && (
        <div className="border-t border-gray-100 px-3 py-1 text-xs text-gray-400">
          {table.indexes.map((idx) => (
            <div key={idx.name}>
              {idx.unique ? "unique " : ""}idx: {idx.columns.join(", ")}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
