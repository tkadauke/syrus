import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ColumnVisibilityMenu, orderedOptionalColumns, visibleColumnKeys, visibleOptionalColumnKeys } from "./ColumnVisibilityMenu"

const REQUIRED = [ { key: "title", title: "Title" } ]
const OPTIONAL = [
  { key: "state", title: "State" },
  { key: "owner", title: "Owner" },
  { key: "updated_at", title: "Updated" }
]

function renderMenu(onChange = vi.fn(), overrides: Partial<Parameters<typeof ColumnVisibilityMenu>[0]> = {}) {
  render(
    <ColumnVisibilityMenu
      downLabel="Down"
      menuId="test-columns-menu"
      moveDownLabel={(title) => `Move ${title} down`}
      moveUpLabel={(title) => `Move ${title} up`}
      onChange={onChange}
      optionalColumns={OPTIONAL}
      triggerAriaLabel="Columns"
      upLabel="Up"
      visibleColumns={[ "state", "owner" ]}
      visibleLabel="Visible columns"
      {...overrides}
    />
  )
  return onChange
}

describe("ColumnVisibilityMenu", () => {
  it("lists checked columns first (in preference order), then unchecked columns", () => {
    renderMenu(vi.fn(), { visibleColumns: [ "owner", "state" ] })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    const labels = screen.getAllByRole("checkbox").map((checkbox) => checkbox.closest("label")?.textContent)
    expect(labels).toEqual([ "Owner", "State", "Updated" ])
    expect(screen.getByLabelText("Owner")).toBeChecked()
    expect(screen.getByLabelText("State")).toBeChecked()
    expect(screen.getByLabelText("Updated")).not.toBeChecked()
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

  it("moves a checked column up or down within the visible order", () => {
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

  it("no-ops (without calling onChange) when moving a boundary column further out of range", () => {
    const onChange = renderMenu()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Move State up"))
    fireEvent.click(screen.getByLabelText("Move Owner down"))

    expect(onChange).not.toHaveBeenCalled()
  })

  it("disables all controls while pending", () => {
    renderMenu(vi.fn(), { pending: true })

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))

    expect(screen.getByLabelText("State")).toBeDisabled()
    expect(screen.getByLabelText("Move Owner up")).toBeDisabled()
  })
})

describe("visibleOptionalColumnKeys", () => {
  it("falls back to every optional column when no preference is stored", () => {
    expect(visibleOptionalColumnKeys({ optionalColumns: OPTIONAL, visibleColumns: undefined })).toEqual([ "state", "owner", "updated_at" ])
  })

  it("filters out unknown columns and de-duplicates", () => {
    expect(visibleOptionalColumnKeys({ optionalColumns: OPTIONAL, visibleColumns: [ "owner", "ghost", "owner", "state" ] })).toEqual([ "owner", "state" ])
  })

  it("preserves an explicit empty selection instead of falling back", () => {
    expect(visibleOptionalColumnKeys({ optionalColumns: OPTIONAL, visibleColumns: [] })).toEqual([])
  })
})

describe("orderedOptionalColumns", () => {
  it("orders checked columns by preference, then appends unchecked columns in definition order", () => {
    const ordered = orderedOptionalColumns({ optionalColumns: OPTIONAL, visibleColumns: [ "owner" ] })
    expect(ordered.map((column) => column.key)).toEqual([ "owner", "state", "updated_at" ])
  })
})

describe("visibleColumnKeys", () => {
  it("prefixes required columns and filters/dedupes the rest", () => {
    expect(visibleColumnKeys({ requiredColumns: REQUIRED, optionalColumns: OPTIONAL, visibleColumns: [ "owner", "ghost" ] })).toEqual([ "title", "owner" ])
  })

  it("drops unknown optional keys, keeping the required-column prefix", () => {
    expect(visibleColumnKeys({ requiredColumns: REQUIRED, optionalColumns: OPTIONAL, visibleColumns: [ "ghost" ] })).toEqual([ "title" ])
  })
})
