import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { MigrationDiffPayload } from "@app/api/artifacts"
import { MigrationDiffRenderer } from "./MigrationDiffRenderer"

const migrationPayload: MigrationDiffPayload = {
  migration_name: "AddEmailToUsers",
  before: {
    table_name: "users",
    columns: [
      { name: "id",         type: "integer" },
      { name: "legacy_key", type: "string"  },
      { name: "status",     type: "string"  }
    ]
  },
  after: {
    table_name: "users",
    columns: [
      { name: "id",     type: "integer" },
      { name: "email",  type: "string"  },
      { name: "status", type: "integer" }
    ]
  },
  changes: [
    { type: "added",    column: { name: "email",      type: "string"  } },
    { type: "removed",  column: { name: "legacy_key", type: "string"  } },
    { type: "modified", column: { name: "status",     type: "integer" } }
  ]
}

describe("MigrationDiffRenderer", () => {
  it("renders the migration name", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(screen.getByText("AddEmailToUsers")).toBeInTheDocument()
  })

  it("renders Before and After section headers", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(screen.getByText(/Before/)).toBeInTheDocument()
    expect(screen.getByText(/After/)).toBeInTheDocument()
  })

  it("shows the table name in both panels", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(screen.getAllByText(/users/)).toHaveLength(2)
  })

  it("renders added columns with a green 'added' pill", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    const addedPills = screen.getAllByText("added")
    expect(addedPills.length).toBeGreaterThan(0)
    expect(addedPills[0]).toHaveClass("bg-success-surface")
  })

  it("renders removed columns with a red 'removed' pill", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    const removedPills = screen.getAllByText("removed")
    expect(removedPills.length).toBeGreaterThan(0)
    expect(removedPills[0]).toHaveClass("bg-danger-surface")
  })

  it("renders modified columns with an amber 'modified' pill", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    const modifiedPills = screen.getAllByText("modified")
    expect(modifiedPills.length).toBeGreaterThan(0)
    expect(modifiedPills[0]).toHaveClass("bg-warning-surface")
  })

  it("highlights the added row in the After column with green background", () => {
    const { container } = render(<MigrationDiffRenderer payload={migrationPayload} />)

    // email row in After table should have emerald highlight
    const rows = container.querySelectorAll("tr.bg-success-bg")
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].textContent).toContain("email")
  })

  it("highlights the removed row in the Before column with red background", () => {
    const { container } = render(<MigrationDiffRenderer payload={migrationPayload} />)

    const rows = container.querySelectorAll("tr.bg-danger-bg")
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].textContent).toContain("legacy_key")
  })

  it("lists all change entries in the changes section", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(screen.getAllByText("email").length).toBeGreaterThan(0)
    expect(screen.getAllByText("legacy_key").length).toBeGreaterThan(0)
    expect(screen.getAllByText("status").length).toBeGreaterThan(0)
  })

  it("keeps the before/after tables wide enough to scroll on narrow screens", () => {
    const { container } = render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(container.firstElementChild).toHaveClass("w-max", "min-w-full")
    expect(container.querySelector(".grid")).toHaveClass("w-max", "min-w-full", "grid-cols-[minmax(22rem,1fr)_minmax(22rem,1fr)]")
    expect(screen.getAllByText("legacy_key")[0]).toHaveClass("whitespace-nowrap")
  })

  it("renders correctly with no changes", () => {
    const noChanges: MigrationDiffPayload = {
      ...migrationPayload,
      changes: []
    }
    render(<MigrationDiffRenderer payload={noChanges} />)

    expect(screen.getByText("AddEmailToUsers")).toBeInTheDocument()
    expect(screen.queryByText("added")).not.toBeInTheDocument()
  })

  it("does not crash on a legacy change entry with no column object (regression)", () => {
    // Older workflow runs (pre commit 02a622a8f) persisted change summaries
    // shaped like { op: "create_table", table: "widgets" } with no `column`
    // key at all, which threw "undefined is not an object (evaluating
    // 'e.column.name')" and took down the whole Job detail route.
    const legacyPayload = {
      ...migrationPayload,
      changes: [
        { op: "create_table", table: "widgets" },
        { type: "added", column: { name: "email", type: "string" } }
      ]
    } as unknown as MigrationDiffPayload

    render(<MigrationDiffRenderer payload={legacyPayload} />)

    expect(screen.getByText("AddEmailToUsers")).toBeInTheDocument()
    expect(screen.getAllByText("email").length).toBeGreaterThan(0)
  })

  it("does not crash when before/after or changes are missing entirely", () => {
    const minimalPayload = {
      migration_name: "SomeMigration"
    } as unknown as MigrationDiffPayload

    render(<MigrationDiffRenderer payload={minimalPayload} />)

    expect(screen.getByText("SomeMigration")).toBeInTheDocument()
  })

  it("renders database catalogs and makes an absent-before table explicit", () => {
    render(<MigrationDiffRenderer payload={{ migration_name: "CreateWidgets", status: "success", before: { tables: [] }, after: { tables: [{ name: "widgets", columns: [{ name: "account_id", type: "bigint", sql_type: "bigint", nullable: false }], indexes: [{ name: "index_widgets_on_account_id", columns: ["account_id"], unique: true }], foreign_keys: [{ from_column: "account_id", to_table: "accounts", to_column: "id" }], check_constraints: [{ name: "account_positive", expression: "account_id > 0" }] }] } }} />)
    expect(screen.getByText("Absent")).toBeInTheDocument()
    expect(screen.getByText("account_id")).toBeInTheDocument()
    expect(screen.getByText(/index_widgets_on_account_id/)).toHaveTextContent("UNIQUE")
    expect(screen.getByText(/account_id → accounts.id/)).toBeInTheDocument()
    expect(screen.getByText(/account_positive:/)).toBeInTheDocument()
  })

  it("renders no-schema-change, cumulative fallback, and generation-error outcomes", () => {
    const { rerender } = render(<MigrationDiffRenderer payload={{ migration_name: "Backfill", status: "no_schema_changes" }} />)
    expect(screen.getByText("No schema changes")).toBeInTheDocument()
    rerender(<MigrationDiffRenderer payload={{ migration_name: "Fallback", status: "cumulative_fallback", cumulative: true, message: "Attribution unavailable", before: { tables: [] }, after: { tables: [] } }} />)
    expect(screen.getByText("Cumulative schema diff")).toBeInTheDocument()
    rerender(<MigrationDiffRenderer payload={{ migration_name: "Broken", status: "error", stage: "execution", message: "boom" }} />)
    expect(screen.getByRole("alert")).toHaveTextContent("execution: boom")
  })
})
