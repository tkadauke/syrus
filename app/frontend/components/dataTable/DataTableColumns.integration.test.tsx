import { fireEvent, render, screen, within } from "@testing-library/react"
import { useState } from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DataTable } from "../ui"
import { DataTableColumnCells, DataTableColumnHeaderRow } from "./DataTableColumnHeaderRow"
import { DataTableColumnMenu } from "./DataTableColumnMenu"
import { useLocalStorageColumnPreferences } from "./columnPersistence"
import type { DataTableColumnDef } from "./types"

// A minimal harness wiring the whole primitive together -- localStorage
// persistence, the picker menu, the draggable header row, and matching body
// cells -- the way a real DataTable surface would. Exercises the pieces as a
// caller actually composes them, not just in isolation.
type JobRow = { id: number; name: string; owner: string; state: string }

const ROWS: JobRow[] = [
  { id: 1, name: "Fix flaky spec", owner: "Alice", state: "Running" },
  { id: 2, name: "Add index", owner: "Bob", state: "Queued" }
]

function buildColumns(onSelect: (id: number) => void): DataTableColumnDef<JobRow>[] {
  return [
    { key: "select", label: "Select", pin: "start", renderCell: (row) => <input aria-label={`Select ${row.name}`} onChange={() => onSelect(row.id)} type="checkbox" />, required: true },
    { key: "name", label: "Job", renderCell: (row) => row.name, sortKey: "name" },
    { key: "state", label: "State", renderCell: (row) => row.state },
    { key: "owner", label: "Owner", renderCell: (row) => row.owner },
    { key: "actions", label: "Actions", pin: "end", renderCell: (row) => <button type="button">Open {row.id}</button>, required: true }
  ]
}

function Harness({ onSelect = () => {}, onSort = () => {} }: { onSelect?: (id: number) => void; onSort?: (key: string) => void }) {
  const columns = buildColumns(onSelect)
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: "syrus.test.jobs.columns" })
  const [ sortColumn, setSortColumn ] = useState<string | null>(null)

  return (
    <div>
      <DataTableColumnMenu
        columns={columns}
        downLabel="Down"
        menuId="jobs-columns-menu"
        moveDownLabel={(label) => `Move ${label} down`}
        moveUpLabel={(label) => `Move ${label} up`}
        onChange={preferences.onChange}
        order={preferences.order}
        triggerAriaLabel="Columns"
        upLabel="Up"
        visibleLabel="Visible columns"
      />
      <DataTable.Root aria-label="Jobs">
        <DataTable.Header>
          <DataTableColumnHeaderRow
            columns={columns}
            onReorder={preferences.onChange}
            onSort={(key) => {
              setSortColumn(key)
              onSort(key)
            }}
            order={preferences.order}
            sortColumn={sortColumn}
          />
        </DataTable.Header>
        <DataTable.Body>
          {ROWS.map((row) => (
            <DataTable.Row key={row.id}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={row} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </div>
  )
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

beforeEach(() => {
  window.localStorage.clear()
})

describe("DataTable column primitive integration", () => {
  it("renders required selection/action columns pinned around the default optional columns", () => {
    render(<Harness />)

    const headers = screen.getAllByRole("columnheader").map((cell) => cell.textContent)
    expect(headers[0]).toBe("Select")
    expect(headers[headers.length - 1]).toBe("Actions")
    expect(within(screen.getByRole("table")).getByLabelText("Select Fix flaky spec")).toBeInTheDocument()
    expect(within(screen.getByRole("table")).getByRole("button", { name: "Open 1" })).toBeInTheDocument()
  })

  it("hiding a column via the menu removes it from both the header row and every body row's cells", () => {
    render(<Harness />)

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("State"))

    expect(screen.queryByRole("columnheader", { name: "State" })).not.toBeInTheDocument()
    expect(screen.queryByText("Running")).not.toBeInTheDocument()
    expect(screen.queryByText("Queued")).not.toBeInTheDocument()
  })

  it("dragging a header reorders both the header row and every body row's cells together, and persists across remount", () => {
    const { unmount } = render(<Harness />)

    const nameHeader = screen.getByRole("columnheader", { name: /Job/ })
    const ownerHeader = screen.getByRole("columnheader", { name: "Owner" })
    const transfer = dataTransfer()

    fireEvent.dragStart(nameHeader, { dataTransfer: transfer })
    fireEvent.dragOver(ownerHeader, { dataTransfer: transfer })
    fireEvent.drop(ownerHeader, { dataTransfer: transfer })

    const headers = screen.getAllByRole("columnheader").map((cell) => cell.textContent)
    expect(headers).toEqual([ "Select", "State", "Owner", "Job-", "Actions" ])

    const rows = screen.getAllByRole("row").slice(1)
    const firstRowCells = within(rows[0]).getAllByRole("cell").map((cell) => cell.textContent)
    expect(firstRowCells[1]).toBe("Running")
    expect(firstRowCells[2]).toBe("Alice")
    expect(firstRowCells[3]).toBe("Fix flaky spec")

    unmount()
    render(<Harness />)
    const headersAfterRemount = screen.getAllByRole("columnheader").map((cell) => cell.textContent)
    expect(headersAfterRemount).toEqual([ "Select", "State", "Owner", "Job-", "Actions" ])
  })

  it("keeps sortable-header clicks working after wiring drag reordering on top", () => {
    let sortedBy: string | null = null
    render(<Harness onSort={(key) => { sortedBy = key }} />)

    fireEvent.click(screen.getByRole("button", { name: /Job/ }))
    expect(sortedBy).toBe("name")
  })
})
