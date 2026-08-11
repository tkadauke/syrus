import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { SchemaErdPayload } from "../../api/artifacts"
import { ErdDiagramRenderer } from "./ErdDiagramRenderer"

const usersTable: SchemaErdPayload["tables"][0] = {
  name: "users",
  columns: [
    { name: "id",         type: "integer" },
    { name: "email",      type: "string" },
    { name: "account_id", type: "integer" }
  ],
  indexes: [
    { name: "index_users_on_email", columns: ["email"], unique: true }
  ],
  foreign_keys: [
    { from_column: "account_id", to_table: "accounts", to_column: "id" }
  ]
}

const accountsTable: SchemaErdPayload["tables"][0] = {
  name: "accounts",
  columns: [
    { name: "id",   type: "integer" },
    { name: "name", type: "string" }
  ],
  indexes: [],
  foreign_keys: []
}

describe("ErdDiagramRenderer", () => {
  it("renders a table box for each table in the payload", () => {
    render(<ErdDiagramRenderer payload={{ tables: [usersTable, accountsTable] }} />)

    expect(screen.getByText("users")).toBeInTheDocument()
    expect(screen.getByText("accounts")).toBeInTheDocument()
  })

  it("renders all column names and types", () => {
    render(<ErdDiagramRenderer payload={{ tables: [usersTable] }} />)

    expect(screen.getAllByText("id").length).toBeGreaterThan(0)
    expect(screen.getAllByText("email").length).toBeGreaterThan(0)
    // account_id appears in both the column row and the FK reference section
    expect(screen.getAllByText("account_id").length).toBeGreaterThan(0)
    expect(screen.getAllByText("integer")).toHaveLength(2)
    expect(screen.getAllByText("string").length).toBeGreaterThan(0)
  })

  it("renders an FK arrow indicator on the FK source column", () => {
    const { container } = render(<ErdDiagramRenderer payload={{ tables: [usersTable] }} />)

    // account_id appears in both the column list and the FK reference section;
    // the indicator ↗ only appears in the column-list td.
    const tds = Array.from(container.querySelectorAll("td"))
    const accountIdTd = tds.find((td) => td.textContent?.includes("account_id") && td.textContent?.includes("↗"))
    expect(accountIdTd).not.toBeUndefined()
  })

  it("does not render FK indicators on non-FK columns", () => {
    const { container } = render(<ErdDiagramRenderer payload={{ tables: [usersTable] }} />)

    const tds = Array.from(container.querySelectorAll("td"))
    const emailTd = tds.find((td) => td.textContent?.trim() === "email")
    expect(emailTd).not.toBeUndefined()
    expect(emailTd!.textContent).not.toContain("↗")
  })

  it("renders FK references with to_table and to_column", () => {
    render(<ErdDiagramRenderer payload={{ tables: [usersTable] }} />)

    expect(screen.getByText(/accounts\.id/)).toBeInTheDocument()
  })

  it("renders index information", () => {
    render(<ErdDiagramRenderer payload={{ tables: [usersTable] }} />)

    expect(screen.getByText(/unique.*idx.*email|idx.*email.*unique/i)).toBeInTheDocument()
  })

  it("renders an empty-state message when there are no tables", () => {
    render(<ErdDiagramRenderer payload={{ tables: [] }} />)

    expect(screen.getByText(/no tables found/i)).toBeInTheDocument()
  })

  it("handles tables with no foreign keys or indexes", () => {
    const simple: SchemaErdPayload = {
      tables: [{ name: "things", columns: [{ name: "id", type: "integer" }] }]
    }
    render(<ErdDiagramRenderer payload={simple} />)

    expect(screen.getByText("things")).toBeInTheDocument()
    expect(screen.getByText("id")).toBeInTheDocument()
  })
})
