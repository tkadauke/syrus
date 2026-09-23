import { describe, expect, it } from "vitest"
import {
  menuColumns,
  reorderColumnKeys,
  visibleColumnKeys,
  visibleColumns,
  visibleOptionalColumnKeys
} from "./columnOrder"
import type { DataTableColumnDef } from "./types"

type Row = { id: number }

const SELECT: DataTableColumnDef<Row> = { key: "select", label: "Select", pin: "start", renderCell: () => null, required: true }
const TITLE: DataTableColumnDef<Row> = { key: "title", label: "Title", renderCell: (row) => String(row.id) }
const STATE: DataTableColumnDef<Row> = { key: "state", label: "State", renderCell: () => null }
const OWNER: DataTableColumnDef<Row> = { key: "owner", label: "Owner", renderCell: () => null }
const ACTIONS: DataTableColumnDef<Row> = { key: "actions", label: "Actions", pin: "end", renderCell: () => null, required: true }

const COLUMNS = [ SELECT, TITLE, STATE, OWNER, ACTIONS ]

describe("visibleOptionalColumnKeys", () => {
  it("falls back to every optional column with defaultVisible !== false when no order is stored", () => {
    expect(visibleOptionalColumnKeys({ columns: COLUMNS, order: undefined })).toEqual([ "title", "state", "owner" ])
  })

  it("excludes optional columns with defaultVisible: false from the fallback", () => {
    const hidden = { ...OWNER, defaultVisible: false }
    expect(visibleOptionalColumnKeys({ columns: [ TITLE, STATE, hidden ], order: undefined })).toEqual([ "title", "state" ])
  })

  it("filters out required and unknown keys, and de-duplicates", () => {
    expect(visibleOptionalColumnKeys({ columns: COLUMNS, order: [ "owner", "select", "ghost", "owner" ] })).toEqual([ "owner" ])
  })

  it("preserves an explicit empty selection instead of falling back", () => {
    expect(visibleOptionalColumnKeys({ columns: COLUMNS, order: [] })).toEqual([])
  })
})

describe("menuColumns", () => {
  it("never includes required columns", () => {
    const keys = menuColumns({ columns: COLUMNS, order: [ "owner" ] }).map((column) => column.key)
    expect(keys).not.toContain("select")
    expect(keys).not.toContain("actions")
  })

  it("orders checked columns by preference, then appends unchecked columns in definition order", () => {
    const ordered = menuColumns({ columns: COLUMNS, order: [ "owner" ] })
    expect(ordered.map((column) => column.key)).toEqual([ "owner", "title", "state" ])
  })
})

describe("visibleColumns / visibleColumnKeys", () => {
  it("pins required columns to their declared end around the ordered optional columns", () => {
    const keys = visibleColumnKeys({ columns: COLUMNS, order: [ "owner", "title" ] })
    expect(keys).toEqual([ "select", "owner", "title", "actions" ])
  })

  it("drops hidden optional columns from the rendered table entirely", () => {
    const keys = visibleColumnKeys({ columns: COLUMNS, order: [ "owner" ] })
    expect(keys).toEqual([ "select", "owner", "actions" ])
  })

  it("keeps a selection column pinned to the start and an actions column pinned to the end regardless of order", () => {
    const columns = visibleColumns({ columns: COLUMNS, order: [ "state", "owner", "title" ] })
    expect(columns[0].key).toBe("select")
    expect(columns[columns.length - 1].key).toBe("actions")
  })

  it("still renders required columns when every optional column is hidden", () => {
    expect(visibleColumnKeys({ columns: COLUMNS, order: [] })).toEqual([ "select", "actions" ])
  })
})

describe("reorderColumnKeys", () => {
  it("moves the key at the source position to the target position", () => {
    expect(reorderColumnKeys([ "a", "b", "c" ], "c", "b")).toEqual([ "a", "c", "b" ])
    expect(reorderColumnKeys([ "state", "owner" ], "owner", "state")).toEqual([ "owner", "state" ])
  })

  it("no-ops when the source and target keys are identical", () => {
    const order = [ "a", "b" ]
    expect(reorderColumnKeys(order, "a", "a")).toBe(order)
  })

  it("no-ops when either key is missing from the order", () => {
    const order = [ "a", "b" ]
    expect(reorderColumnKeys(order, "a", "ghost")).toBe(order)
    expect(reorderColumnKeys(order, "ghost", "a")).toBe(order)
  })
})
