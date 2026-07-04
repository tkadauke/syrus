import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { JobOwnerFilterChip } from "./Dashboard"
import type { DashboardPayload } from "../api/dashboard"

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

function makePayload(scope: string, ownerId: number | null = null): DashboardPayload {
  return {
    subject: "job",
    view: "list",
    ownership: { scope, owner_id: ownerId, team_user_count: 3, badges_visible: false },
    controls: {
      ownership_scopes: [
        { value: "mine", label: "Mine" },
        { value: "team", label: "Team" },
        { value: "claimable", label: "Claimable" },
        { value: "user", label: "User" }
      ],
      owners: [
        { id: 1, label: "Alice", current: true },
        { id: 2, label: "Bob", current: false }
      ],
      views: ["list"],
      sort_columns: [],
      sort_directions: [],
      columns: { required: [], optional: [] },
      kanban_lanes: [],
      filter_schema: [],
      filter_suggestions: []
    }
  } as unknown as DashboardPayload
}

function renderChip(payload: DashboardPayload, search = "") {
  render(
    <MemoryRouter initialEntries={[`/dashboard/jobs${search}`]}>
      <JobOwnerFilterChip payload={payload} pathname="/dashboard/jobs" search={search} />
      <LocationProbe />
    </MemoryRouter>
  )
}

describe("JobOwnerFilterChip", () => {
  it("renders chip with current scope label", () => {
    renderChip(makePayload("mine"))
    expect(screen.getByRole("button", { name: /Owner is Mine/i })).toBeInTheDocument()
  })

  it("shows Team as default scope without a reset button", () => {
    renderChip(makePayload("team"))
    expect(screen.getByRole("button", { name: /Owner is Team/i })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Reset Owner filter" })).toBeNull()
  })

  it("shows reset button for non-default scopes", () => {
    renderChip(makePayload("mine"))
    expect(screen.getByRole("link", { name: "Reset Owner filter" })).toBeInTheDocument()
  })

  it("reset link points to URL without ownership_scope", () => {
    renderChip(makePayload("mine"), "?ownership_scope=mine")
    const resetLink = screen.getByRole("link", { name: "Reset Owner filter" })
    expect(resetLink.getAttribute("href")).toBe("/dashboard/jobs")
  })

  it("opens scope menu on chip click", () => {
    renderChip(makePayload("mine"))
    expect(screen.queryByRole("menu")).toBeNull()
    fireEvent.click(screen.getByRole("button", { name: /Owner is Mine/i }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Mine" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Team" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Claimable" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "User" })).toBeInTheDocument()
  })

  it("scope menu items link to correct URLs", () => {
    renderChip(makePayload("team"))
    fireEvent.click(screen.getByRole("button", { name: /Owner is Team/i }))

    const mineLink = screen.getByRole("menuitem", { name: "Mine" })
    expect(mineLink.getAttribute("href")).toBe("/dashboard/jobs?ownership_scope=mine")

    const teamLink = screen.getByRole("menuitem", { name: "Team" })
    expect(teamLink.getAttribute("href")).toBe("/dashboard/jobs")
  })

  it("shows user picker when scope is user", () => {
    renderChip(makePayload("user", 1))
    fireEvent.click(screen.getByRole("button"))
    expect(screen.getByLabelText("Specific owner")).toBeInTheDocument()
  })

  it("displays the selected user name in chip when scope is user", () => {
    renderChip(makePayload("user", 2))
    expect(screen.getByRole("button", { name: /Owner is Bob/i })).toBeInTheDocument()
  })

  it("shows reset button when scope is claimable", () => {
    renderChip(makePayload("claimable"))
    expect(screen.getByRole("link", { name: "Reset Owner filter" })).toBeInTheDocument()
  })
})
