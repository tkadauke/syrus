import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { AdminEventFilterBar, AdminEventLogTable } from "./AdminEventLogPanel"

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
        onNavigate={onNavigate}
        renderExpanded={(row) => <div>Details for {row.id}</div>}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: /Time/ }))
    expect(onNavigate).toHaveBeenCalledTimes(1)
    expect((onNavigate.mock.calls[0][0] as URLSearchParams).toString()).toBe("sort=time&direction=asc")

    fireEvent.click(screen.getByRole("button", { name: "Show details" }))
    expect(screen.getByText("Details for 7")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Hide" })).toBeInTheDocument()
  })
})
