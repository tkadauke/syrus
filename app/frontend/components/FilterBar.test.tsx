import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { FilterBar, type FilterSchemaField } from "./FilterBar"

const filterSchema: FilterSchemaField[] = [
  {
    field: "state",
    label: "State",
    bucket: "enum",
    operators: ["is", "is_none_of"],
    values: [
      { value: "open", label: "Open" },
      { value: "closed", label: "Closed" }
    ]
  },
  {
    field: "kind",
    label: "Kind",
    bucket: "enum",
    operators: ["is"],
    values: [{ value: "issue", label: "Issue" }]
  },
  {
    field: "has_parent",
    label: "Has parent",
    bucket: "boolean",
    operators: ["is_true", "is_false"],
    values: []
  },
  {
    field: "repository_id",
    label: "Repository",
    bucket: "fk",
    operators: ["is", "is_one_of"],
    typeahead: true
  }
]

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

function decodedFilterFromLocation() {
  const location = screen.getByTestId("location").textContent || ""
  const query = location.split("?")[1] || ""
  const q = new URLSearchParams(query).get("q")
  if (!q) return null

  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const base64 = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
  const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes))
}

describe("FilterBar", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("applies chip editor value changes immediately", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "closed" } })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "state", op: "is", value: "closed" }]
      })
    })
  })

  it("renders dark-mode classes on chips, menus, and editors", () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    const chip = screen.getByRole("button", { name: "State is Open" }).closest("span")
    expect(chip).toHaveClass("dark:border-gray-700", "dark:bg-gray-800")

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByPlaceholderText("Search filters...").parentElement).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")

    fireEvent.pointerDown(document.body)
    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    expect(screen.getByRole("dialog", { name: "State filter settings" })).toHaveClass("dark:border-gray-700", "dark:bg-gray-900")
  })

  it("uses a custom link builder for filter and clear navigation", async () => {
    const buildLink = vi.fn((path: string, search: string, updates: Record<string, string | number | null | undefined>) => {
      const params = new URLSearchParams(search)
      for (const [key, value] of Object.entries(updates)) {
        if (value == null || String(value).length === 0) {
          params.delete(key)
        } else {
          params.set(key, String(value))
        }
      }

      const query = params.toString()
      return query ? `${path}?${query}` : path
    })

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs?view=kanban&state=open"]}>
        <FilterBar
          buildLink={buildLink}
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          legacyFilterKeys={["state"]}
          pathname="/dashboard/jobs"
          search="?view=kanban&state=open"
        />
        <LocationProbe />
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "Clear filters" })).toHaveAttribute("href", "/dashboard/jobs?view=kanban")

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "closed" } })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "state", op: "is", value: "closed" }]
      })
    })
    expect(screen.getByTestId("location")).toHaveTextContent("/dashboard/jobs?view=kanban")
    expect(screen.getByTestId("location")).not.toHaveTextContent("state=")
    expect(buildLink).toHaveBeenCalledWith(
      "/dashboard/jobs",
      "?view=kanban&state=open",
      expect.objectContaining({
        page: null,
        q: expect.any(String),
        smart_folder_id: null,
        state: null
      })
    )
  })

  it("shows suggested filters above the regular add-filter menu and applies them immediately", async () => {
    const onFilterApplied = vi.fn()

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [] }}
          filterSchema={filterSchema}
          onFilterApplied={onFilterApplied}
          pathname="/dashboard/jobs"
          search=""
          suggestions={[
            {
              id: 1,
              label: "State is Closed",
              filter: { field: "state", op: "is", value: "closed" }
            }
          ]}
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))

    expect(screen.getByText("Suggested")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "State is Closed" }).compareDocumentPosition(screen.getByRole("button", { name: "State enum" })) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()

    fireEvent.click(screen.getByRole("button", { name: "State is Closed" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "state", op: "is", value: "closed" }]
      })
    })
    expect(onFilterApplied).toHaveBeenCalledWith({
      and: [{ field: "state", op: "is", value: "closed" }]
    })
  })

  it("loads matching RHS filter suggestions from the server while searching", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname !== "/api/v1/app/filters/suggestions") {
        return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
      }

      expect(url.searchParams.get("surface")).toBe("dashboard")
      expect(url.searchParams.get("subject")).toBe("job")
      expect(url.searchParams.get("q")).toBe("sy")
      expect(url.searchParams.has("active_q")).toBe(false)

      return Promise.resolve(jsonResponse({
        suggestions: [
          {
            id: "value-repository",
            label: "Repository is tkadauke/syrus",
            filter: { field: "repository_id", op: "is", value: 2 },
            source: "value"
          }
        ]
      }))
    })

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
          suggestionSearch={{ surface: "dashboard", subject: "job" }}
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "sy" } })

    const suggestion = await screen.findByRole("button", { name: "Repository is tkadauke/syrus" })
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/filters/suggestions?surface=dashboard&subject=job&q=sy",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal: expect.any(AbortSignal)
      })
    )

    fireEvent.click(suggestion)

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "repository_id", op: "is", value: 2 }]
      })
    })
  })

  it("does not show a value placeholder for predicate filters", () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "has_parent", op: "is_true", value: null }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Has parent is true" }))

    expect(screen.getByRole("dialog", { name: "Has parent filter settings" })).toBeInTheDocument()
    expect(screen.queryByText("No value needed")).not.toBeInTheDocument()
  })

  it("renders multi-value selections as compact removable tokens", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is_none_of", value: ["open"] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "State is none of Open" }))
    const dialog = screen.getByRole("dialog", { name: "State filter settings" })

    expect(within(dialog).getByText("Open")).toBeInTheDocument()
    expect(within(dialog).queryByText("Nothing selected yet")).not.toBeInTheDocument()
    expect(within(dialog).getByPlaceholderText("Search...")).toBeInTheDocument()
    expect(within(dialog).queryByRole("listbox")).not.toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: "Remove Open" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "state", op: "is_none_of", value: [] }]
      })
    })
    expect(within(dialog).getByText("Nothing selected yet")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "State is none of (unset)" })).toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: "Closed" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "state", op: "is_none_of", value: ["closed"] }]
      })
    })
    expect(within(dialog).getByText("Closed")).toBeInTheDocument()
  })

  it("uses search-as-you-type controls for FK filters", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname !== "/api/v1/app/filters/fk_options") {
        return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
      }

      const ids = url.searchParams.getAll("ids[]")
      const q = url.searchParams.get("q")
      if (ids.includes("3")) {
        return Promise.resolve(jsonResponse({ options: [{ value: 3, label: "acme/widgets" }] }))
      }
      if (q === "api") {
        return Promise.resolve(jsonResponse({ options: [{ value: 4, label: "acme/api" }] }))
      }

      return Promise.resolve(jsonResponse({ options: [] }))
    })

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "repository_id", op: "is_one_of", value: ["3"] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Repository is one of 3" }))
    const dialog = screen.getByRole("dialog", { name: "Repository filter settings" })

    expect(within(dialog).getAllByRole("combobox")).toHaveLength(1)
    expect(within(dialog).getByText("Operator").compareDocumentPosition(within(dialog).getByText("Value")) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    const searchInput = within(dialog).getByPlaceholderText("Search by name...")
    expect(searchInput.parentElement).toHaveClass("flex-wrap", "max-h-[10rem]", "overflow-y-auto")
    expect(within(dialog).queryByText("Search by name to add a value")).not.toBeInTheDocument()
    expect(await within(dialog).findByText("acme/widgets")).toBeInTheDocument()

    fireEvent.change(searchInput, { target: { value: "api" } })
    expect(await within(dialog).findByRole("button", { name: "acme/api" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/filters/fk_options?field=repository_id&q=api",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )

    fireEvent.click(within(dialog).getByRole("button", { name: "acme/api" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "repository_id", op: "is_one_of", value: ["3", "4"] }]
      })
    })
  })

  it("hydrates FK filter chip labels from saved filter ids", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname !== "/api/v1/app/filters/fk_options") {
        return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
      }

      const ids = url.searchParams.getAll("ids[]")
      if (url.searchParams.get("field") === "repository_id" && ids.includes("2")) {
        return Promise.resolve(jsonResponse({ options: [{ value: 2, label: "tkadauke/syrus" }] }))
      }

      return Promise.resolve(jsonResponse({ options: [] }))
    })

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs?smart_folder_id=7"]}>
        <FilterBar
          filter={{ and: [{ field: "repository_id", op: "is", value: 2 }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search="?smart_folder_id=7"
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("button", { name: "Repository is 2" })).toBeInTheDocument()
    expect(await screen.findByRole("button", { name: "Repository is tkadauke/syrus" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/filters/fk_options?field=repository_id&ids%5B%5D=2",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("opens the filter menu before adding OR alternatives", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    expect(screen.getByRole("dialog", { name: "State filter settings" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Apply filter" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Done" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Wrap in NOT" })).toHaveTextContent("¬")

    fireEvent.click(screen.getByRole("button", { name: "+ OR alternative" }))

    expect(screen.queryByRole("dialog", { name: "State filter settings" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    expect(decodedFilterFromLocation()).toBeNull()

    fireEvent.click(screen.getByRole("button", { name: "Kind enum" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [
          {
            or: [
              { field: "state", op: "is", value: "open" },
              { field: "kind", op: "is", value: "issue" }
            ]
          }
        ]
      })
    })
    expect(screen.queryByPlaceholderText("Search filters...")).not.toBeInTheDocument()
    expect(screen.getByRole("dialog", { name: "Kind filter settings" })).toBeInTheDocument()
  })

  it("closes an open chip editor with Escape or an outside click", () => {
    const { rerender } = render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    expect(screen.getByRole("dialog", { name: "State filter settings" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("dialog", { name: "State filter settings" })).not.toBeInTheDocument()

    rerender(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is", value: "open" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )
    fireEvent.click(screen.getByRole("button", { name: "State is Open" }))
    expect(screen.getByRole("dialog", { name: "State filter settings" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("dialog", { name: "State filter settings" })).not.toBeInTheDocument()
  })
})

function jsonResponse(payload: unknown) {
  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json" }
  })
}
