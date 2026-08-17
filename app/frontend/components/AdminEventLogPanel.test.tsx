import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { AdminEventFilterBar } from "./AdminEventLogPanel"

describe("AdminEventFilterBar", () => {
  it("renders compact filter chips from URL params and submits non-empty values", () => {
    const onNavigate = vi.fn()

    render(
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
        onNavigate={onNavigate}
      />
    )

    expect(screen.getByText("Search is")).toBeInTheDocument()
    expect(screen.getByText("Revision is")).toBeInTheDocument()
    expect(screen.getByDisplayValue("n.map")).toBeInTheDocument()
    expect(screen.getByDisplayValue("24h")).toBeInTheDocument()
    expect(screen.getByDisplayValue("All SHAs")).toBeInTheDocument()

    fireEvent.change(screen.getByDisplayValue("n.map"), { target: { value: "  TypeError  " } })
    fireEvent.change(screen.getByDisplayValue("24h"), { target: { value: "" } })
    fireEvent.change(screen.getByDisplayValue("All SHAs"), { target: { value: "current" } })
    fireEvent.click(screen.getByRole("button", { name: "Search" }))

    expect(onNavigate).toHaveBeenCalledTimes(1)
    const params = onNavigate.mock.calls[0][0] as URLSearchParams
    expect(params.toString()).toBe("query=TypeError&revision_scope=current")
  })

  it("clears all filter params", () => {
    const onNavigate = vi.fn()

    render(
      <AdminEventFilterBar
        clearLabel="Clear"
        fields={[{ name: "query", label: "Search" }]}
        search="?query=boom"
        searchLabel="Search"
        onNavigate={onNavigate}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Clear" }))

    expect(onNavigate).toHaveBeenCalledTimes(1)
    expect((onNavigate.mock.calls[0][0] as URLSearchParams).toString()).toBe("")
  })
})
