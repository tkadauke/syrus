import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { AdminEventFilterBar, AdminEventLogTable, AdminEventPageShell, adminEventLinkClass } from "./AdminEventLogPanel"
import { Page } from "./ui/Page"

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
            {
              name: "revision_scope",
              label: "Revision",
              defaultValue: "current",
              options: [
                { value: "current", label: "Current SHA" },
                { value: "all", label: "All SHAs" }
              ]
            }
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
        <AdminEventFilterBar clearLabel="Clear" fields={[{ name: "query", label: "Search" }]} search="?query=boom&sort=time" searchLabel="Search" />
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

  it("restores the mobile gutter when rendered inside a responsive Page.Root", () => {
    render(
      <MemoryRouter>
        <Page.Root gutter="responsive">
          <AdminEventFilterBar clearLabel="Clear" fields={[{ name: "query", label: "Search" }]} search="" searchLabel="Search" />
        </Page.Root>
      </MemoryRouter>
    )

    const addFilterButton = screen.getByRole("button", { name: "+ Add filter" })
    const filterBarRoot = addFilterButton.closest("div")?.parentElement
    expect(filterBarRoot?.className).toContain("mx-4 sm:mx-0")
  })

  it("is a no-op outside any Page.Root, or inside one with the default gutter", () => {
    render(
      <MemoryRouter>
        <AdminEventFilterBar clearLabel="Clear" fields={[{ name: "query", label: "Search" }]} search="" searchLabel="Search" />
      </MemoryRouter>
    )

    const addFilterButton = screen.getByRole("button", { name: "+ Add filter" })
    const filterBarRoot = addFilterButton.closest("div")?.parentElement
    expect(filterBarRoot?.className).not.toContain("mx-4 sm:mx-0")
  })
})

describe("AdminEventPageShell", () => {
  function renderShell(children = <div>Table content</div>) {
    return render(
      <MemoryRouter>
        <AdminEventPageShell actions={<button type="button">Refresh</button>} ariaLabel="Backend exceptions" eyebrow="Admin" title="Backend Exceptions">
          {children}
        </AdminEventPageShell>
      </MemoryRouter>
    )
  }

  it("uses the responsive gutter primitive on the page container", () => {
    renderShell()

    const main = screen.getByRole("main", { name: "Backend exceptions" })
    expect(main.className).toContain("max-w-[96rem]")
    expect(main.className).toContain("px-0")
    expect(main.className).toContain("sm:px-[var(--space-page-x)]")
  })

  it("restores the mobile gutter on the header but lets children run flush", () => {
    renderShell(<div data-testid="table-content">Table content</div>)

    const heading = screen.getByRole("heading", { name: "Backend Exceptions" })
    const header = heading.closest("header")
    expect(header?.className).toContain("px-4 sm:px-0")

    const content = screen.getByTestId("table-content")
    expect(content.className).not.toContain("px-4 sm:px-0")
  })

  it("renders the eyebrow, title, and actions in the header", () => {
    renderShell()

    expect(screen.getByText("Admin")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Backend Exceptions" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument()
  })

  it("uses the same page title treatment as the queue page", () => {
    renderShell()

    expect(screen.getByRole("heading", { name: "Backend Exceptions" }).className).toContain("text-[length:var(--text-page-title)]")
  })

  it("supports a short page description above the filter/table content", () => {
    render(
      <MemoryRouter>
        <AdminEventPageShell ariaLabel="Activity" description="Operational context" eyebrow="Admin" title="Workflow events">
          <div>Filter bar</div>
        </AdminEventPageShell>
      </MemoryRouter>
    )

    const description = screen.getByText("Operational context")
    const filterBar = screen.getByText("Filter bar")
    expect(description.compareDocumentPosition(filterBar) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
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
          {
            key: "message",
            header: "Message",
            className: "px-4 py-2",
            render: (row: { id: number; message: string }, state) => (
              <button onClick={state.toggleExpanded} type="button">
                {state.expanded ? "Hide" : row.message}
              </button>
            )
          }
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

  it("uses a caller-provided default sort for the active header indicator", () => {
    render(
      <AdminEventLogTable
        columns={[
          { key: "requested", header: "Requested", sort: "requested", className: "px-4 py-2", render: (row: { id: number }) => row.id },
          { key: "kind", header: "Kind", sort: "kind", className: "px-4 py-2", render: () => "initial" }
        ]}
        defaultSort={{ column: "requested", direction: "desc" }}
        getRowKey={(row) => row.id}
        rows={[{ id: 7 }]}
        storageKey="syrus.test.admin_event_log.default_sort"
      />
    )

    const requestedHeader = screen.getByRole("columnheader", { name: /Requested/ })
    const kindHeader = screen.getByRole("columnheader", { name: /Kind/ })
    expect(requestedHeader).toHaveAttribute("aria-sort", "descending")
    expect(requestedHeader.querySelector("[data-sort-indicator]")).toHaveAttribute("data-sort-direction", "descending")
    expect(kindHeader).toHaveAttribute("aria-sort", "none")
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

  it("renders shared table panel chrome with top pagination, column selector, and footer pagination", () => {
    const onNavigate = vi.fn()

    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", className: "px-4 py-2", render: (row: { id: number }) => row.id },
          { key: "owner", header: "Owner", className: "px-4 py-2", render: () => "Alice" }
        ]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7 }]}
        search="?q=active&page=2"
        storageKey="syrus.test.admin_event_log.panel"
        onNavigate={onNavigate}
        panel={{
          summary: "Showing 26-50 of 80 items",
          pagination: {
            ariaLabel: "Test pagination",
            label: "Page 2 of 4",
            nextLabel: "Next",
            onNavigate,
            pagination: { page: 2, has_next_page: true, has_previous_page: true, next_page: 3, previous_page: 1, total_pages: 4 },
            previousLabel: "Previous",
            search: "?q=active&page=2"
          }
        }}
      />
    )

    const panel = screen.getByText("Showing 26-50 of 80 items").closest("section")
    expect(panel?.className).toContain("bg-white")
    expect(panel?.className).toContain("border")

    const topHeader = screen.getByText("Showing 26-50 of 80 items").parentElement?.parentElement
    expect(within(topHeader as HTMLElement).getByRole("button", { name: "Previous" })).toBeInTheDocument()
    expect(within(topHeader as HTMLElement).getByRole("button", { name: "Next" })).toBeInTheDocument()
    expect(within(topHeader as HTMLElement).getByRole("button", { name: "Columns" })).toBeInTheDocument()

    const footer = screen.getByRole("navigation", { name: "Test pagination" })
    expect(within(footer).getByText("Page 2 of 4")).toBeInTheDocument()
    expect(within(footer).getByRole("button", { name: "Previous" })).toBeInTheDocument()
    expect(within(footer).getByRole("button", { name: "Next" })).toBeInTheDocument()

    fireEvent.click(within(topHeader as HTMLElement).getByRole("button", { name: "Next" }))
    expect((onNavigate.mock.calls[0][0] as URLSearchParams).toString()).toBe("q=active&page=3")
  })

  it("omits top and bottom pagination controls when there is only one page", () => {
    render(
      <AdminEventLogTable
        columns={[{ key: "time", header: "Time", className: "px-4 py-2", render: (row: { id: number }) => row.id }]}
        getRowKey={(row) => row.id}
        rows={[{ id: 7 }]}
        storageKey="syrus.test.admin_event_log.single_page_panel"
        panel={{
          summary: "Showing 1-1 of 1 items",
          pagination: {
            ariaLabel: "Test pagination",
            label: "Page 1 of 1",
            nextLabel: "Next",
            onNavigate: vi.fn(),
            pagination: { page: 1, has_next_page: false, has_previous_page: false, total_pages: 1 },
            previousLabel: "Previous",
            search: ""
          }
        }}
      />
    )

    expect(screen.getByText("Showing 1-1 of 1 items")).toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Test pagination" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Previous" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Columns" })).toBeInTheDocument()
  })

  it("keeps the expanded detail row's colSpan aligned with visible columns after a header drag reorder and a hidden column", () => {
    render(
      <AdminEventLogTable
        columns={[
          { key: "time", header: "Time", className: "px-4 py-2", render: (row: { id: number; message: string; owner: string }) => row.id },
          { key: "owner", header: "Owner", className: "px-4 py-2", render: (row: { id: number; message: string; owner: string }) => row.owner },
          {
            key: "message",
            header: "Message",
            className: "px-4 py-2",
            render: (row: { id: number; message: string; owner: string }, state) => (
              <button onClick={state.toggleExpanded} type="button">
                {state.expanded ? "Hide" : row.message}
              </button>
            )
          }
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

    expect(screen.getAllByRole("columnheader").map((cell) => cell.textContent)).toEqual(["Owner", "Time", "Message"])
    const firstRowCells = within(screen.getAllByRole("row")[1])
      .getAllByRole("cell")
      .map((cell) => cell.textContent)
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

    expect(screen.getAllByRole("columnheader").map((cell) => cell.textContent)).toEqual(["Summary", "Time", "Owner", "Actions"])

    // Required columns never appear in the picker -- only "time" and "owner" do.
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    expect(screen.getAllByRole("checkbox")).toHaveLength(2)
  })
})
