import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { AdminEventFilterBar, AdminEventLogTable, adminEventLinkClass } from "./AdminEventLogPanel"

function dataTransfer() {
  return { dropEffect: "", effectAllowed: "", getData: vi.fn(), setData: vi.fn() }
}

beforeEach(() => {
  window.localStorage.clear()
})

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{location.search}</output>
}

describe("AdminEventFilterBar", () => {
  it("renders dashboard-style filter chips from URL params and defaults", () => {
    render(
      <MemoryRouter>
        <AdminEventFilterBar
          clearLabel="Clear"
          fields={[
            { name: "query", label: "Search", placeholder: "message or path" },
            { name: "since", label: "Since", defaultValue: "24h", placeholder: "24h" },
            { name: "id", label: "ID", inputMode: "numeric" },
            { name: "revision_scope", label: "Revision", defaultValue: "current", options: [
              { value: "current", label: "Current SHA" },
              { value: "all", label: "All SHAs" }
            ] }
          ]}
          search="?query=n.map&revision_scope=all"
          searchLabel="Search"
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("button", { name: "Search is n.map" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Since is 24h" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revision is All SHAs" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Clear filters" })).toBeInTheDocument()
  })

  it("builds clear links that remove admin filter params", () => {
    render(
      <MemoryRouter>
        <AdminEventFilterBar
          clearLabel="Clear"
          fields={[{ name: "query", label: "Search" }]}
          search="?query=boom&sort=time"
          searchLabel="Search"
        />
      </MemoryRouter>
    )

    // Clearing keeps an explicit (empty) `q` rather than dropping it, so a
    // later request can tell "user cleared every filter" apart from "no
    // filter was ever requested" and the backend won't re-apply its own
    // defaults on top of the just-cleared state.
    expect(screen.getByRole("link", { name: "Clear filters" })).toHaveAttribute("href", "/?sort=time&q=eyJhbmQiOltdfQ")
  })

  it("keeps an explicit empty `q` after removing the last chip, instead of dropping it", () => {
    // Regression test: removing the only remaining default-bearing chip
    // (per_page/since/revision_scope) used to drop `q` from the URL
    // entirely, which the admin backend_exceptions/browser_errors routes
    // then read as "no filter was ever requested" and re-applied their
    // default chips — so the just-removed chip reappeared immediately.
    render(
      <MemoryRouter>
        <AdminEventFilterBar
          clearLabel="Clear"
          fields={[{ name: "per_page", label: "Per page", defaultValue: "50" }]}
          filter={{ and: [{ field: "per_page", op: "is", value: "50" }] }}
          filterSchema={[{ field: "per_page", label: "Per page", bucket: "text", operators: ["is"] }]}
          search="?q=eyJhbmQiOlt7ImZpZWxkIjoicGVyX3BhZ2UiLCJvcCI6ImlzIiwidmFsdWUiOiI1MCJ9XX0"
          searchLabel="Search"
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Remove Per page filter" }))

    expect(screen.queryByRole("button", { name: "Per page is 50" })).not.toBeInTheDocument()
    expect(screen.getByTestId("location")).toHaveTextContent("q=eyJhbmQiOltdfQ")
  })
})

describe("AdminEventLogTable", () => {
  it("uses semantic brand tokens for event links", () => {
    const className = adminEventLinkClass()

    expect(className).toContain("text-brand")
    expect(className).not.toMatch(/\b(?:text|bg|border)-blue-/)
  })

  it("renders sortable columns and expandable detail rows", () => {
    const onNavigate = vi.fn()

    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", sort: "time", className: "px-4 py-2", render: (row: { id: number; message: string }) => row.id },
          { key: "message", header: "Message", className: "px-4 py-2", render: (row: { id: number; message: string }, state) => (
            <button onClick={state.toggleExpanded} type="button">{state.expanded ? "Hide" : row.message}</button>
          ) }
        ]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7, message: "Show details" }]}
        search="?sort=time&direction=desc"
        storageKey="syrus.test.admin_event_log.sort_and_expand"
        onNavigate={onNavigate}
        renderExpanded={(row) => <div>Details for {row.id}</div>}
      />
    )

    const table = screen.getByRole("table")
    expect(table.parentElement).toHaveAttribute("data-data-table-overflow-wrapper", "true")

    fireEvent.click(screen.getByRole("button", { name: /Time/ }))
    expect(onNavigate).toHaveBeenCalledTimes(1)
    expect((onNavigate.mock.calls[0][0] as URLSearchParams).toString()).toBe("sort=time&direction=asc")

    fireEvent.click(screen.getByRole("button", { name: "Show details" }))
    expect(screen.getByText("Details for 7")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Hide" })).toBeInTheDocument()
  })

  it("hides an optional column from both the header and body cells via the column picker", () => {
    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", sort: "time", className: "px-4 py-2", render: (row: { id: number; owner: string }) => row.id },
          { key: "owner", header: "Owner", className: "px-4 py-2", render: (row: { id: number; owner: string }) => row.owner }
        ]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7, owner: "Alice" }]}
        storageKey="syrus.test.admin_event_log.column_picker"
      />
    )

    expect(screen.getByRole("columnheader", { name: "Owner" })).toBeInTheDocument()
    expect(screen.getByText("Alice")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Owner"))

    expect(screen.queryByRole("columnheader", { name: "Owner" })).not.toBeInTheDocument()
    expect(screen.queryByText("Alice")).not.toBeInTheDocument()
  })

  it("keeps the expanded detail row's colSpan aligned with visible columns after a header drag reorder and a hidden column", () => {
    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", className: "px-4 py-2", render: (row: { id: number; message: string; owner: string }) => row.id },
          { key: "owner", header: "Owner", className: "px-4 py-2", render: (row: { id: number; message: string; owner: string }) => row.owner },
          { key: "message", header: "Message", className: "px-4 py-2", render: (row: { id: number; message: string; owner: string }, state) => (
            <button onClick={state.toggleExpanded} type="button">{state.expanded ? "Hide" : row.message}</button>
          ) }
        ]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7, message: "Show details", owner: "Alice" }]}
        storageKey="syrus.test.admin_event_log.reorder_colspan"
        renderExpanded={(row) => <div>Details for {row.id}</div>}
      />
    )

    const timeHeader = screen.getByRole("columnheader", { name: "Time" })
    const ownerHeader = screen.getByRole("columnheader", { name: "Owner" })
    const transfer = dataTransfer()

    fireEvent.dragStart(timeHeader, { dataTransfer: transfer })
    fireEvent.dragOver(ownerHeader, { dataTransfer: transfer })
    fireEvent.drop(ownerHeader, { dataTransfer: transfer })

    expect(screen.getAllByRole("columnheader").map((cell) => cell.textContent)).toEqual([ "Owner", "Time", "Message" ])
    const firstRowCells = within(screen.getAllByRole("row")[1]).getAllByRole("cell").map((cell) => cell.textContent)
    expect(firstRowCells[0]).toBe("Alice")

    // Hiding a column drops the expanded row's colSpan to match the new
    // visible column count instead of staying pinned at the original total.
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(screen.getByLabelText("Owner"))

    fireEvent.click(screen.getByRole("button", { name: "Show details" }))
    const detailCell = screen.getByText("Details for 7").closest("td")!
    expect(detailCell).toHaveAttribute("colspan", "2")
  })

  it("pins required columns to their declared end instead of always start-pinning them", () => {
    // Regression test: a required column defaults to start-pinning, which
    // used to silently reorder every migrated table whose required column
    // wasn't already declared first (e.g. an "actions" column with the only
    // expand toggle jumping from last to second). "summary" here is neither
    // the first nor the last declared column, so it demonstrates the default
    // start-pin behavior explicitly; "actions" shows the `pin: "end"` escape
    // hatch keeping a required column in its declared trailing position.
    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", className: "px-4 py-2", render: (row: { id: number }) => row.id },
          { key: "summary", header: "Summary", required: true, className: "px-4 py-2", render: (row: { id: number }) => `Row ${row.id}` },
          { key: "owner", header: "Owner", className: "px-4 py-2", render: () => "Alice" },
          { key: "actions", header: "Actions", required: true, pin: "end", className: "px-4 py-2", render: () => <button type="button">Open</button> }
        ]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7 }]}
        storageKey="syrus.test.admin_event_log.required_pin"
      />
    )

    expect(screen.getAllByRole("columnheader").map((cell) => cell.textContent)).toEqual([ "Summary", "Time", "Owner", "Actions" ])

    // Required columns never appear in the picker -- only "time" and "owner" do.
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    expect(screen.getAllByRole("checkbox")).toHaveLength(2)
  })
})
