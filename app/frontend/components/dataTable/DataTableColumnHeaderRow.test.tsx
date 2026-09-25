import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DataTable } from "../ui"
import { DataTableColumnCells, DataTableColumnHeaderRow } from "./DataTableColumnHeaderRow"
import type { DataTableColumnDef } from "./types"

type Row = { id: number; name: string }

const ROW: Row = { id: 1, name: "syrus" }

const SELECT: DataTableColumnDef<Row> = {
  key: "select",
  label: "Select",
  pin: "start",
  renderCell: (row) => <input aria-label={`Select ${row.name}`} type="checkbox" />,
  required: true
}
const NAME: DataTableColumnDef<Row> = { key: "name", label: "Name", renderCell: (row) => row.name, sortKey: "name" }
const STATUS: DataTableColumnDef<Row> = { key: "status", label: "Status", renderCell: () => "Running" }
const OWNER: DataTableColumnDef<Row> = { key: "owner", label: "Owner", renderCell: () => "Alice" }
const ACTIONS: DataTableColumnDef<Row> = {
  key: "actions",
  label: "Actions",
  pin: "end",
  renderCell: () => <button type="button">Retry</button>,
  required: true
}

const COLUMNS = [ SELECT, NAME, STATUS, OWNER, ACTIONS ]

function renderTable(overrides: Partial<Parameters<typeof DataTableColumnHeaderRow>[0]> = {}) {
  const onSort = vi.fn()
  const onReorder = vi.fn()
  render(
    <DataTable.Root aria-label="Jobs">
      <DataTable.Header>
        <DataTableColumnHeaderRow columns={COLUMNS} onReorder={onReorder} onSort={onSort} order={[ "name", "status", "owner" ]} {...overrides} />
      </DataTable.Header>
      <DataTable.Body>
        <DataTable.Row>
          <DataTableColumnCells columns={COLUMNS} order={overrides.order ?? [ "name", "status", "owner" ]} row={ROW} />
        </DataTable.Row>
      </DataTable.Body>
    </DataTable.Root>
  )
  return { onReorder, onSort }
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

function headerLabels() {
  return screen.getAllByRole("columnheader").map((cell) => cell.textContent)
}

describe("DataTableColumnHeaderRow / DataTableColumnCells", () => {
  it("renders required columns pinned to their declared end regardless of order", () => {
    renderTable()

    const headers = headerLabels()
    expect(headers[0]).toBe("Select")
    expect(headers[headers.length - 1]).toBe("Actions")
  })

  it("renders action/selection column cells alongside the header, driven by the same column set", () => {
    renderTable()

    expect(screen.getByLabelText("Select syrus")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument()
  })

  it("preserves sortable-header click behavior", () => {
    const { onSort } = renderTable()

    fireEvent.click(screen.getByRole("button", { name: /Name/ }))
    expect(onSort).toHaveBeenCalledWith("name")
  })

  it("marks the active ascending sortable column", () => {
    renderTable({ sortColumn: "name", sortDirection: "ascending" })

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    expect(nameHeader).toHaveAttribute("aria-sort", "ascending")
    expect(nameHeader.querySelector("[data-sort-indicator]")).toHaveAttribute("data-sort-direction", "ascending")
  })

  it("marks the active descending sortable column", () => {
    renderTable({ sortColumn: "name", sortDirection: "descending" })

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    expect(nameHeader).toHaveAttribute("aria-sort", "descending")
    expect(nameHeader.querySelector("[data-sort-indicator]")).toHaveAttribute("data-sort-direction", "descending")
  })

  it("renders unsorted sortable and non-sortable columns distinctly", () => {
    renderTable()

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    const statusHeader = screen.getByRole("columnheader", { name: "Status" })

    expect(nameHeader).toHaveAttribute("aria-sort", "none")
    expect(nameHeader.querySelector("[data-sort-indicator]")).toHaveAttribute("data-sort-direction", "none")
    expect(statusHeader).not.toHaveAttribute("aria-sort")
    expect(statusHeader.querySelector("[data-sort-indicator]")).not.toBeInTheDocument()
  })

  it("does not attach drag handlers to a required column's header", () => {
    renderTable()

    const selectHeader = screen.getByRole("columnheader", { name: "Select" })
    const actionsHeader = screen.getByRole("columnheader", { name: "Actions" })
    expect(selectHeader).not.toHaveAttribute("draggable")
    expect(actionsHeader).not.toHaveAttribute("draggable")
  })

  it("reorders the whole column, not just the header label, when a header is dragged over another header", () => {
    renderTable()

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    const ownerHeader = screen.getByRole("columnheader", { name: "Owner" })
    const transfer = dataTransfer()

    fireEvent.dragStart(nameHeader, { dataTransfer: transfer })
    fireEvent.dragOver(ownerHeader, { dataTransfer: transfer })

    expect(headerLabels()).toEqual([ "Select", "Status", "Owner", "Name", "Actions" ])
  })

  it("commits the reorder once on drop and updates both header and body cell order", () => {
    const { onReorder } = renderTable()

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    const ownerHeader = screen.getByRole("columnheader", { name: "Owner" })
    const transfer = dataTransfer()

    fireEvent.dragStart(nameHeader, { dataTransfer: transfer })
    fireEvent.dragOver(ownerHeader, { dataTransfer: transfer })
    expect(onReorder).not.toHaveBeenCalled()

    fireEvent.drop(ownerHeader, { dataTransfer: transfer })
    expect(onReorder).toHaveBeenCalledTimes(1)
    expect(onReorder).toHaveBeenCalledWith([ "status", "owner", "name" ])
  })

  it("dragging a sortable header does not trigger a sort", () => {
    const { onSort } = renderTable()

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    const statusHeader = screen.getByRole("columnheader", { name: "Status" })
    const transfer = dataTransfer()

    fireEvent.dragStart(nameHeader, { dataTransfer: transfer })
    fireEvent.dragOver(statusHeader, { dataTransfer: transfer })
    fireEvent.drop(statusHeader, { dataTransfer: transfer })

    expect(onSort).not.toHaveBeenCalled()
  })

  it("disables dragging entirely when reorderDisabled is set", () => {
    renderTable({ reorderDisabled: true })

    const nameHeader = screen.getByRole("columnheader", { name: /Name/ })
    expect(nameHeader).not.toHaveAttribute("draggable")
  })
})
