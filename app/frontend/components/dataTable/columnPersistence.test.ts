import { act, renderHook } from "@testing-library/react"
import { beforeEach, describe, expect, it } from "vitest"
import {
  readLocalStorageColumnOrder,
  useLocalStorageColumnPreferences,
  writeLocalStorageColumnOrder
} from "./columnPersistence"
import type { DataTableColumnDef } from "./types"

type Row = { id: number }

const SELECT: DataTableColumnDef<Row> = { key: "select", label: "Select", pin: "start", renderCell: () => null, required: true }
const STATE: DataTableColumnDef<Row> = { key: "state", label: "State", renderCell: () => null }
const OWNER: DataTableColumnDef<Row> = { key: "owner", label: "Owner", renderCell: () => null }
const HIDDEN_BY_DEFAULT: DataTableColumnDef<Row> = { key: "notes", label: "Notes", defaultVisible: false, renderCell: () => null }

const COLUMNS = [ SELECT, STATE, OWNER, HIDDEN_BY_DEFAULT ]
const STORAGE_KEY = "syrus.test.columns"

beforeEach(() => {
  window.localStorage.clear()
})

describe("readLocalStorageColumnOrder", () => {
  it("falls back to the default-visible optional columns when nothing is stored", () => {
    expect(readLocalStorageColumnOrder(STORAGE_KEY, COLUMNS)).toEqual([ "state", "owner" ])
  })

  it("returns the stored order, dropping unknown and required keys", () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify([ "owner", "select", "ghost" ]))
    expect(readLocalStorageColumnOrder(STORAGE_KEY, COLUMNS)).toEqual([ "owner" ])
  })

  it("preserves an explicit empty selection instead of falling back", () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify([]))
    expect(readLocalStorageColumnOrder(STORAGE_KEY, COLUMNS)).toEqual([])
  })

  it("falls back on malformed JSON", () => {
    window.localStorage.setItem(STORAGE_KEY, "{not json")
    expect(readLocalStorageColumnOrder(STORAGE_KEY, COLUMNS)).toEqual([ "state", "owner" ])
  })
})

describe("writeLocalStorageColumnOrder / readLocalStorageColumnOrder round-trip", () => {
  it("persists whatever order is written", () => {
    writeLocalStorageColumnOrder(STORAGE_KEY, [ "owner", "notes" ])
    expect(readLocalStorageColumnOrder(STORAGE_KEY, COLUMNS)).toEqual([ "owner", "notes" ])
  })
})

describe("useLocalStorageColumnPreferences", () => {
  it("initializes order from localStorage and persists changes through onChange", () => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify([ "owner" ]))
    const { result } = renderHook(() => useLocalStorageColumnPreferences({ columns: COLUMNS, storageKey: STORAGE_KEY }))

    expect(result.current.order).toEqual([ "owner" ])

    act(() => {
      result.current.onChange([ "owner", "state" ])
    })

    expect(result.current.order).toEqual([ "owner", "state" ])
    expect(JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "[]")).toEqual([ "owner", "state" ])
  })
})
