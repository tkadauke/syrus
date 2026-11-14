import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, expect, it, vi } from "vitest"
import type { DashboardPayload } from "../api/dashboard"
import { DashboardFilterBar } from "./Dashboard"

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

const proposerRows = [
  { title: "Human proposal", handle: "ada" },
  { title: "Coworker proposal", handle: "adrian" },
  { title: "Unattributed work", handle: null }
]

function ProposerFilteredRows() {
  const location = useLocation()
  const encoded = new URLSearchParams(location.search).get("q")
  const filter = encoded ? decodeFilter(encoded) : { and: [] }
  const proposer = filter.and.find((chip) => chip.field === "proposer" && chip.op === "is")?.value
  const rows = proposer ? proposerRows.filter((row) => row.handle === proposer) : proposerRows

  return (
    <ul aria-label="Dashboard jobs">
      {rows.map((row) => (
        <li key={row.title}>{row.title}</li>
      ))}
    </ul>
  )
}

function decodeFilter(encoded: string) {
  const standard = encoded.replace(/-/g, "+").replace(/_/g, "/")
  const padded = standard.padEnd(Math.ceil(standard.length / 4) * 4, "=")
  return JSON.parse(decodeURIComponent(escape(atob(padded)))) as { and: Array<{ field: string; op: string; value?: string }> }
}

function encodeFilter(filter: object) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(filter))))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
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
  const initialSearch = `?q=${encodeFilter(payload.filter)}`

  render(
    <MemoryRouter initialEntries={[`/dashboard/jobs${initialSearch}`]}>
      <DashboardFilterBar payload={payload} pathname="/dashboard/jobs" search={initialSearch} />
      <ProposerFilteredRows />
      <LocationProbe />
    </MemoryRouter>
  )

  expect(screen.getByRole("button", { name: "Proposer is Ada (@ada)" })).toBeInTheDocument()
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).toHaveTextContent("Human proposal")
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).not.toHaveTextContent("Coworker proposal")
  fireEvent.click(screen.getByRole("button", { name: "Proposer is Ada (@ada)" }))
  fireEvent.change(screen.getByLabelText("Value"), { target: { value: "adrian" } })

  await waitFor(() => expect(screen.getByRole("button", { name: "Proposer is Adrian (@adrian)" })).toBeInTheDocument())
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).toHaveTextContent("Coworker proposal")
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).not.toHaveTextContent("Human proposal")
  fireEvent.click(screen.getByRole("button", { name: "Remove Proposer filter" }))

  await waitFor(() => expect(screen.queryByRole("button", { name: /Proposer is/ })).not.toBeInTheDocument())
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).toHaveTextContent("Human proposal")
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).toHaveTextContent("Coworker proposal")
  expect(screen.getByRole("list", { name: "Dashboard jobs" })).toHaveTextContent("Unattributed work")
})
