import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DataTableColumnMenu } from "./DataTableColumnMenu"
import type { DataTableColumnDef } from "./types"

type Row = { id: number }

const SELECT: DataTableColumnDef<Row> = { key: "select", label: "Select", pin: "start", renderCell: () => null, required: true }
const STATE: DataTableColumnDef<Row> = { key: "state", label: "State", renderCell: () => null }
const OWNER: DataTableColumnDef<Row> = { key: "owner", label: "Owner", renderCell: () => null }
const UPDATED: DataTableColumnDef<Row> = { key: "updated_at", label: "Updated", renderCell: () => null }
const ACTIONS: DataTableColumnDef<Row> = { key: "actions", label: "Actions", pin: "end", renderCell: () => null, required: true }

const COLUMNS = [ SELECT, STATE, OWNER, UPDATED, ACTIONS ]

function renderMenu(onChange = vi.fn(), overrides: Partial<Parameters<typeof DataTableColumnMenu>[0]> = {}) {
  render(
    <DataTableColumnMenu
      columns={COLUMNS}
      downLabel="Down"
      menuId="test-columns-menu"
      moveDownLabel={(label) => `Move ${label} down`}
      moveUpLabel={(label) => `Move ${label} up`}
      onChange={onChange}
      order={[ "state", "owner" ]}
      triggerAriaLabel="Columns"
      upLabel="Up"
      visibleLabel="Visible columns"
      {...overrides}
    />
  )
  return onChange
}

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

describe("DataTableColumnMenu", () => {
  it("never lists required columns as checkbox options", () => {
    renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    expect(screen.queryByLabelText("Select")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Actions")).not.toBeInTheDocument()
    expect(screen.getAllByRole("checkbox")).toHaveLength(3)
  })

  it("lists checked columns first in preference order, then unchecked columns", () => {
    renderMenu(vi.fn(), { order: [ "owner", "state" ] })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    const labels = screen.getAllByRole("checkbox").map((checkbox) => checkbox.closest("label")?.textContent)
    expect(labels).toEqual([ "Owner", "State", "Updated" ])
  })

  it("calls onChange with the column appended when checking an unchecked column", () => {
    const onChange = renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Updated"))

    expect(onChange).toHaveBeenCalledWith([ "state", "owner", "updated_at" ])
  })

  it("calls onChange with the column removed when unchecking a checked column", () => {
    const onChange = renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("State"))

    expect(onChange).toHaveBeenCalledWith([ "owner" ])
  })

  it("moves a checked column up via the keyboard-accessible button", () => {
    const onChange = renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Move Owner up"))

    expect(onChange).toHaveBeenCalledWith([ "owner", "state" ])
  })

  it("disables move controls for unchecked columns", () => {
    renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    expect(screen.getByLabelText("Move Updated up")).toBeDisabled()
    expect(screen.getByLabelText("Move Updated down")).toBeDisabled()
  })

  it("disables all controls while pending", () => {
    renderMenu(vi.fn(), { pending: true })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    expect(screen.getByLabelText("State")).toBeDisabled()
    expect(screen.getByLabelText("Move Owner up")).toBeDisabled()
  })

  it("reorders live while dragging a checked row over another checked row, and commits once on drop", () => {
    const onChange = renderMenu(vi.fn(), { order: [ "state", "owner" ] })
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    const stateRow = screen.getByLabelText("State").closest("label")!.parentElement!
    const ownerRow = screen.getByLabelText("Owner").closest("label")!.parentElement!
    const transfer = dataTransfer()

    fireEvent.dragStart(stateRow, { dataTransfer: transfer })
    fireEvent.dragOver(ownerRow, { dataTransfer: transfer })

    // Live reorder is visible immediately, but nothing is persisted yet.
    expect(screen.getAllByRole("checkbox").map((checkbox) => checkbox.closest("label")?.textContent)).toEqual([ "Owner", "State", "Updated" ])
    expect(onChange).not.toHaveBeenCalled()

    fireEvent.drop(ownerRow, { dataTransfer: transfer })
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenCalledWith([ "owner", "state" ])
  })

  it("does not attach drag handlers to unchecked rows", () => {
    renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    const updatedRow = screen.getByLabelText("Updated").closest("label")!.parentElement!
    expect(updatedRow).not.toHaveAttribute("draggable")
  })
})
