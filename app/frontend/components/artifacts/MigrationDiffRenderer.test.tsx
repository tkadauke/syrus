import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { MigrationDiffPayload } from "../../api/artifacts"
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
    expect(addedPills[0]).toHaveClass("bg-emerald-100")
  })

  it("renders removed columns with a red 'removed' pill", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    const removedPills = screen.getAllByText("removed")
    expect(removedPills.length).toBeGreaterThan(0)
    expect(removedPills[0]).toHaveClass("bg-red-100")
  })

  it("renders modified columns with an amber 'modified' pill", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    const modifiedPills = screen.getAllByText("modified")
    expect(modifiedPills.length).toBeGreaterThan(0)
    expect(modifiedPills[0]).toHaveClass("bg-amber-100")
  })

  it("highlights the added row in the After column with green background", () => {
    const { container } = render(<MigrationDiffRenderer payload={migrationPayload} />)

    // email row in After table should have emerald highlight
    const rows = container.querySelectorAll("tr.bg-emerald-50")
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].textContent).toContain("email")
  })

  it("highlights the removed row in the Before column with red background", () => {
    const { container } = render(<MigrationDiffRenderer payload={migrationPayload} />)

    const rows = container.querySelectorAll("tr.bg-red-50")
    expect(rows.length).toBeGreaterThan(0)
    expect(rows[0].textContent).toContain("legacy_key")
  })

  it("lists all change entries in the changes section", () => {
    render(<MigrationDiffRenderer payload={migrationPayload} />)

    expect(screen.getAllByText("email").length).toBeGreaterThan(0)
    expect(screen.getAllByText("legacy_key").length).toBeGreaterThan(0)
    expect(screen.getAllByText("status").length).toBeGreaterThan(0)
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
})
