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

it("keeps built-in SmartFolder navigation when an expanded scope chip is removed", async () => {
  vi.spyOn(window, "fetch").mockResolvedValue(new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }))
  const payload = {
    subject: "job",
    active_smart_folder_id: 7,
    active_smart_folder_filter: {},
    filter: {
      and: [
        { field: "attention", op: "is", value: "inbox" },
        { field: "eligible_approver", op: "is", value: "me" }
      ]
    },
    smart_folders: [{ id: 7, name: "Inbox", kind: "builtin", subject_type: "job", position: 0, visibility: "always", count: 1, active: true }],
    controls: {
      filter_schema: [
        {
          field: "attention",
          label: "Preset",
          bucket: "preset",
          operators: ["is"],
          values: [{ value: "inbox", label: "Inbox" }]
        },
        {
          field: "eligible_approver",
          label: "Eligible approver",
          bucket: "enum",
          operators: ["is"],
          values: [{ value: "me", label: "Me" }]
        }
      ],
      filter_suggestions: []
    }
  } as unknown as DashboardPayload

  render(
    <MemoryRouter initialEntries={["/dashboard/jobs?smart_folder_id=7"]}>
      <DashboardFilterBar payload={payload} pathname="/dashboard/jobs" search="?smart_folder_id=7" />
      <LocationProbe />
    </MemoryRouter>
  )

  expect(screen.getByRole("button", { name: "Preset is Inbox" })).toBeInTheDocument()
  expect(screen.getByRole("button", { name: "Eligible approver is Me" })).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Remove Eligible approver filter" }))

  await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("smart_folder_id=7"))
  expect(screen.getByTestId("location")).toHaveTextContent(/[?&]q=/)
})

it("clears built-in SmartFolder navigation when its preset is removed", async () => {
  vi.spyOn(window, "fetch").mockResolvedValue(new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }))
  const payload = {
    subject: "job",
    active_smart_folder_id: 7,
    active_smart_folder_filter: {},
    filter: {
      and: [
        { field: "attention", op: "is", value: "inbox" },
        { field: "eligible_approver", op: "is", value: "me" }
      ]
    },
    smart_folders: [{ id: 7, name: "Inbox", kind: "builtin", subject_type: "job", position: 0, visibility: "always", count: 1, active: true }],
    controls: {
      filter_schema: [
        {
          field: "attention",
          label: "Preset",
          bucket: "preset",
          operators: ["is"],
          values: [{ value: "inbox", label: "Inbox" }]
        },
        {
          field: "eligible_approver",
          label: "Eligible approver",
          bucket: "enum",
          operators: ["is"],
          values: [{ value: "me", label: "Me" }]
        }
      ],
      filter_suggestions: []
    }
  } as unknown as DashboardPayload

  render(
    <MemoryRouter initialEntries={["/dashboard/jobs?smart_folder_id=7"]}>
      <DashboardFilterBar payload={payload} pathname="/dashboard/jobs" search="?smart_folder_id=7" />
      <LocationProbe />
    </MemoryRouter>
  )

  fireEvent.click(screen.getByRole("button", { name: "Remove Preset filter" }))

  await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
  expect(screen.getByTestId("location")).toHaveTextContent(/[?&]q=/)
})

it("switches between human and coworker proposers and clears the filter", async () => {
  vi.spyOn(window, "fetch").mockResolvedValue(new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }))
  const payload = {
    subject: "job",
    active_smart_folder_id: null,
    active_smart_folder_filter: {},
    filter: { and: [{ field: "proposer", op: "is", value: "ada" }] },
    smart_folders: [],
    controls: {
      filter_schema: [
        {
          field: "proposer",
          label: "Proposer",
          bucket: "enum",
          operators: ["is", "is_not", "is_set", "is_unset"],
          values: [
            { value: "ada", label: "Ada (@ada)" },
            { value: "adrian", label: "Adrian (@adrian)" }
          ]
        }
      ],
      filter_suggestions: []
    }
  } as unknown as DashboardPayload

  render(
    <MemoryRouter initialEntries={["/dashboard/jobs"]}>
      <DashboardFilterBar payload={payload} pathname="/dashboard/jobs" search="" />
      <LocationProbe />
    </MemoryRouter>
  )

  expect(screen.getByRole("button", { name: "Proposer is Ada (@ada)" })).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Proposer is Ada (@ada)" }))
  fireEvent.change(screen.getByLabelText("Value"), { target: { value: "adrian" } })

  await waitFor(() => expect(screen.getByRole("button", { name: "Proposer is Adrian (@adrian)" })).toBeInTheDocument())
  fireEvent.click(screen.getByRole("button", { name: "Remove Proposer filter" }))

  await waitFor(() => expect(screen.queryByRole("button", { name: /Proposer is/ })).not.toBeInTheDocument())
})
