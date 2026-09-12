import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DataTable } from "@app/components/ui"

describe("DataTable", () => {
  it("renders semantic table structure inside the overflow wrapper", () => {
    render(
      <DataTable.Root aria-label="Jobs" data-testid="jobs-table">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>Job</DataTable.HeadCell>
            <DataTable.HeadCell>Status</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          <DataTable.Row>
            <DataTable.Cell>JOB-1</DataTable.Cell>
            <DataTable.Cell>Running</DataTable.Cell>
          </DataTable.Row>
        </DataTable.Body>
      </DataTable.Root>
    )

    const table = screen.getByRole("table", { name: "Jobs" })
    expect(table).toHaveAttribute("data-testid", "jobs-table")
    expect(table.parentElement).toHaveAttribute("data-data-table-overflow-wrapper", "true")
    expect(table.parentElement?.className).toContain("overflow-x-auto")
    expect(screen.getByRole("columnheader", { name: "Job" })).toHaveAttribute("scope", "col")
    expect(screen.getByRole("cell", { name: "Running" }).className).toContain("text-text-primary")
  })

  it("supports compact density, checkbox columns, interactive rows, and group headers", () => {
    render(
      <DataTable.Root aria-label="Grouped jobs" density="compact">
        <DataTable.Body>
          <DataTable.Row groupHeader>
            <DataTable.HeadCell colSpan={2} scope="rowgroup">Blocked</DataTable.HeadCell>
          </DataTable.Row>
          <DataTable.Row interactive data-testid="job-row">
            <DataTable.Cell checkbox><input aria-label="Select JOB-1" type="checkbox" /></DataTable.Cell>
            <DataTable.Cell>JOB-1</DataTable.Cell>
          </DataTable.Row>
        </DataTable.Body>
      </DataTable.Root>
    )

    expect(screen.getByRole("table").className).toContain("[--data-table-cell-py:0.5rem]")
    expect(screen.getByRole("row", { name: "Blocked" })).toHaveAttribute("data-data-table-group-header", "true")
    expect(screen.getByTestId("job-row")).toHaveAttribute("data-data-table-interactive", "true")
    expect(screen.getByLabelText("Select JOB-1").closest("td")?.className).toContain("w-10")
    expect(screen.getByRole("cell", { name: "JOB-1" }).className).toContain("text-xs")
  })

  it("renders sortable header affordances with aria-sort and click passthrough", () => {
    const onSort = vi.fn()
    render(
      <DataTable.Root aria-label="Jobs">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell onSort={onSort} sortDirection="ascending">Created</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
      </DataTable.Root>
    )

    const header = screen.getByRole("columnheader", { name: /Created/ })
    expect(header).toHaveAttribute("aria-sort", "ascending")
    expect(header.textContent).toContain("^")
    expect(screen.getByRole("button", { name: "Created" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Created/ }))
    expect(onSort).toHaveBeenCalled()
  })

  it("keeps inactive sortable headers semantic without adding a button when no sort handler is present", () => {
    render(
      <DataTable.Root aria-label="Jobs">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell sortable sortDirection="none">Status</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
      </DataTable.Root>
    )

    const header = screen.getByRole("columnheader", { name: /Status/ })
    expect(header).toHaveAttribute("aria-sort", "none")
    expect(header).toHaveAttribute("scope", "col")
    expect(screen.queryByRole("button", { name: /Status/ })).not.toBeInTheDocument()
  })

  it("renders empty states as a table row with configurable colspan and passthrough props", () => {
    render(
      <DataTable.Root aria-label="Jobs">
        <DataTable.Body>
          <DataTable.Empty className="custom-empty" colSpan={3} data-testid="empty-jobs">
            No jobs match this filter.
          </DataTable.Empty>
        </DataTable.Body>
      </DataTable.Root>
    )

    const empty = screen.getByTestId("empty-jobs")
    expect(empty).toHaveAttribute("colspan", "3")
    expect(empty.className).toContain("text-text-muted")
    expect(empty.className).toContain("custom-empty")
    expect(screen.getByRole("cell", { name: "No jobs match this filter." })).toBeInTheDocument()
  })
})
