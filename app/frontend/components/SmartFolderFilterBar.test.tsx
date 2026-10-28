import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { linkFromSearch } from "./filterBar/helpers"
import { SmartFolderFilterBar } from "./SmartFolderFilterBar"

const schema = [{
  field: "state",
  label: "State",
  bucket: "status",
  operators: ["is"],
  values: [{ value: "open", label: "Open" }, { value: "closed", label: "Closed" }]
}]

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{location.search}</output>
}

function renderBar(kind: "builtin" | "user_defined", filter = { and: [{ field: "state", op: "is", value: "open" }] }) {
  render(
    <MemoryRouter initialEntries={["/items?smart_folder_id=7"]}>
      <SmartFolderFilterBar
        activeSmartFolderId={7}
        buildLink={linkFromSearch}
        filter={filter}
        filterSchema={schema}
        pathname="/items"
        search="?smart_folder_id=7"
        smartFolders={[{ id: 7, kind }]}
      />
      <LocationProbe />
    </MemoryRouter>
  )
}

describe("SmartFolderFilterBar", () => {
  it("renders the selected folder's effective preset as a chip", () => {
    renderBar("builtin")

    expect(screen.getByRole("button", { name: "State is Open" })).toBeInTheDocument()
  })

  it("clears built-in selection when its preset is edited", async () => {
    renderBar("builtin")

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    fireEvent.change(screen.getByRole("combobox", { name: "Value" }), { target: { value: "closed" } })

    await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
    expect(screen.getByTestId("location")).toHaveTextContent("q=")
  })

  it("retains user-defined folder identity when its filter is edited", async () => {
    renderBar("user_defined")

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    fireEvent.change(screen.getByRole("combobox", { name: "Value" }), { target: { value: "closed" } })

    await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("smart_folder_id=7"))
  })

  it("deselects a built-in and sends explicit empty q when its final chip is removed", async () => {
    renderBar("builtin")

    fireEvent.click(screen.getByRole("button", { name: "Remove State filter" }))

    await waitFor(() => expect(screen.getByTestId("location")).not.toHaveTextContent("smart_folder_id"))
    expect(new URLSearchParams(screen.getByTestId("location").textContent || "").has("q")).toBe(true)
  })

  it("keeps an explicit empty q when clearing the selected user folder", async () => {
    renderBar("user_defined")

    fireEvent.click(screen.getByRole("link", { name: "Clear filters" }))

    await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("smart_folder_id=7"))
    expect(new URLSearchParams(screen.getByTestId("location").textContent || "").has("q")).toBe(true)
  })
})
