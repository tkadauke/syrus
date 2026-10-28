import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, expect, it, vi } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardFilterBar } from "./Dashboard"

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

afterEach(() => {
  vi.restoreAllMocks()
})

it("keeps built-in SmartFolder navigation when its preset is removed", async () => {
  vi.spyOn(window, "fetch").mockResolvedValue(new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }))
  const payload = {
    subject: "job",
    active_smart_folder_id: 7,
    filter: { and: [ { field: "smart_folder_preset", op: "is", value: "inbox" } ] },
    smart_folders: [
      { id: 7, name: "Inbox", kind: "builtin", subject_type: "job", filter: {}, position: 0, visibility: "always", count: 1, active: true }
    ],
    controls: {
      filter_schema: [
        {
          field: "smart_folder_preset",
          label: "Preset",
          bucket: "preset",
          operators: [ "is" ],
          values: [ { value: "inbox", label: "Inbox" } ]
        }
      ],
      filter_suggestions: []
    }
  } as unknown as DashboardPayload

  render(
    <MemoryRouter initialEntries={[ "/dashboard/jobs?smart_folder_id=7" ]}>
      <DashboardFilterBar payload={payload} pathname="/dashboard/jobs" search="?smart_folder_id=7" />
      <LocationProbe />
    </MemoryRouter>
  )

  expect(screen.getByRole("button", { name: "Preset is Inbox" })).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Remove Preset filter" }))

  await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("smart_folder_id=7"))
  expect(screen.getByTestId("location")).toHaveTextContent(/[?&]q=/)
})
