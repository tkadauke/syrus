import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "../i18n"
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
    field: "job_class",
    label: "Job class",
    bucket: "string",
    operators: ["contains", "is"],
    values: []
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
  },
  {
    field: "created_at",
    label: "Created",
    bucket: "date",
    operators: ["before", "after", "between", "within_last", "more_than_ago"],
    values: [],
    date_precision: "datetime"
  },
  {
    field: "due_on",
    label: "Due",
    bucket: "date",
    operators: ["before", "after", "between", "within_last", "more_than_ago"],
    values: [],
    date_precision: "date"
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
    vi.useRealTimers()
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
        state: null
      })
    )
    const applyCall = buildLink.mock.calls.find((call) => typeof call[2].q === "string")
    expect(applyCall?.[2]).not.toHaveProperty("smart_folder_id")
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
    expect(screen.getByRole("button", { name: "State is Closed" }).compareDocumentPosition(screen.getByRole("button", { name: "State list" })) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()

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

  it("buffers text filter value edits until blur", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "job_class", op: "contains", value: "Run" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Job class contains Run" }))
    const valueInput = screen.getByLabelText("Value")

    fireEvent.change(valueInput, { target: { value: "RunJ" } })

    expect(decodedFilterFromLocation()).toBeNull()
    expect(screen.getByRole("dialog", { name: "Job class filter settings" })).toBeInTheDocument()

    fireEvent.blur(valueInput)

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "job_class", op: "contains", value: "RunJ" }]
      })
    })
  })

  it("commits text filter value edits on Enter", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "job_class", op: "contains", value: "Run" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Job class contains Run" }))
    const valueInput = screen.getByLabelText("Value")

    fireEvent.change(valueInput, { target: { value: "RunJob" } })
    expect(decodedFilterFromLocation()).toBeNull()

    fireEvent.keyDown(valueInput, { key: "Enter" })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "job_class", op: "contains", value: "RunJob" }]
      })
    })
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

  it("renders and updates saved absolute datetime ranges", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "created_at", op: "between", value: ["2026-05-01T08:30:00Z", "2026-05-02T17:45:00Z"] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Created between 2026-05-01 08:30 - 2026-05-02 17:45" }))
    const from = screen.getByLabelText("From") as HTMLInputElement
    const to = screen.getByLabelText("To") as HTMLInputElement

    expect(from.type).toBe("datetime-local")
    expect(from.value).toBe("2026-05-01T08:30")
    expect(to.value).toBe("2026-05-02T17:45")

    fireEvent.change(from, { target: { value: "2026-05-03T09:15" } })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "created_at", op: "between", value: ["2026-05-03T09:15", "2026-05-02T17:45:00Z"] }]
      })
    })
  })

  it("renders and updates saved relative date ranges", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "created_at", op: "more_than_ago", value: { n: 7, unit: "days" } }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Created more than 7 days ago" }))
    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "14" } })
    fireEvent.change(screen.getByLabelText("Unit"), { target: { value: "weeks" } })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "created_at", op: "more_than_ago", value: { n: 14, unit: "weeks" } }]
      })
    })
    expect(screen.getByRole("button", { name: "Created more than 14 weeks ago" })).toBeInTheDocument()
  })

  it("applies datetime range presets without changing the AST shape", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.setSystemTime(new Date("2026-08-31T10:20:00"))

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "created_at", op: "after", value: "2026-08-01T00:00" }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Created after 2026-08-01 00:00" }))
    fireEvent.click(screen.getByRole("button", { name: "Today" }))

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "created_at", op: "between", value: ["2026-08-31T00:00", "2026-08-31T23:59"] }]
      })
    })

    vi.useRealTimers()
  })

  it("uses date precision for date-only fields", async () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "due_on", op: "between", value: ["2026-05-01", "2026-05-31"] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
        <LocationProbe />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Due between 2026-05-01 - 2026-05-31" }))
    const from = screen.getByLabelText("From") as HTMLInputElement

    expect(from.type).toBe("date")
    fireEvent.change(from, { target: { value: "2026-05-02" } })

    await waitFor(() => {
      expect(decodedFilterFromLocation()).toEqual({
        and: [{ field: "due_on", op: "between", value: ["2026-05-02", "2026-05-31"] }]
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

    fireEvent.click(screen.getByRole("button", { name: "Kind list" }))

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

  it("renders operators and unset placeholder using translation keys", () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is_none_of", value: [] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("button", { name: "State is none of (unset)" })).toBeInTheDocument()
  })

  it("renders translated bucket labels in the add-filter menu", () => {
    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={null}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))

    expect(screen.getByRole("button", { name: "State list" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Repository reference" })).toBeInTheDocument()
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

describe("FilterBar keyboard navigation", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  describe("add-filter combobox", () => {
    it("highlights the first item on ArrowDown from the input, including a single-result menu", () => {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={null}
            filterSchema={[filterSchema[1]]}
            pathname="/dashboard/jobs"
            search=""
          />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      fireEvent.keyDown(screen.getByPlaceholderText("Search filters..."), { key: "ArrowDown" })

      expect(screen.getByRole("button", { name: "Kind list" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
    })

    it("highlights the last (bottommost) item on ArrowUp from the input", () => {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={null}
            filterSchema={filterSchema}
            pathname="/dashboard/jobs"
            search=""
          />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      fireEvent.keyDown(screen.getByPlaceholderText("Search filters..."), { key: "ArrowUp" })

      expect(screen.getByRole("button", { name: "Due date" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
      expect(screen.getByRole("button", { name: "State list" })).not.toHaveClass("bg-gray-50")
    })

    it("selects the highlighted item on Enter, the same as a click", async () => {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={{ and: [] }}
            filterSchema={filterSchema}
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
      const searchInput = screen.getByPlaceholderText("Search filters...")
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "Enter" })

      await waitFor(() => {
        expect(decodedFilterFromLocation()).toEqual({
          and: [{ field: "state", op: "is", value: "closed" }]
        })
      })
    })

    it("resets the highlight when the query text changes", () => {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={null}
            filterSchema={filterSchema}
            pathname="/dashboard/jobs"
            search=""
          />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      const searchInput = screen.getByPlaceholderText("Search filters...")
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      expect(screen.getByRole("button", { name: "State list" })).toHaveClass("bg-gray-50")

      fireEvent.change(searchInput, { target: { value: "s" } })

      expect(screen.getByRole("button", { name: "State list" })).not.toHaveClass("bg-gray-50")
      expect(screen.getByRole("button", { name: "State list" })).toHaveClass("hover:bg-gray-50")
    })

    it("no-ops on arrow keys when the filtered list is empty", () => {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={null}
            filterSchema={filterSchema}
            pathname="/dashboard/jobs"
            search=""
          />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      const searchInput = screen.getByPlaceholderText("Search filters...")
      fireEvent.change(searchInput, { target: { value: "zzz-no-match" } })
      expect(screen.getByText("No matching filters")).toBeInTheDocument()

      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "ArrowUp" })

      expect(screen.getByText("No matching filters")).toBeInTheDocument()
    })
  })

  describe("typeahead FK value editor", () => {
    function mockFkOptionsFetch(optionsByQuery: Record<string, { value: number; label: string }[]>) {
      return vi.spyOn(window, "fetch").mockImplementation((input) => {
        const url = new URL(String(input), "http://example.test")
        if (url.pathname !== "/api/v1/app/filters/fk_options") {
          return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
        }

        const q = url.searchParams.get("q") || ""
        return Promise.resolve(jsonResponse({ options: optionsByQuery[q] || [] }))
      })
    }

    function renderTypeahead() {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={{ and: [{ field: "repository_id", op: "is_one_of", value: [] }] }}
            filterSchema={filterSchema}
            pathname="/dashboard/jobs"
            search=""
          />
          <LocationProbe />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "Repository is one of (unset)" }))
      return screen.getByPlaceholderText("Search by name...")
    }

    it("highlights the first item on ArrowDown from the input, including a single-result menu", async () => {
      mockFkOptionsFetch({ ac: [{ value: 4, label: "acme/api" }] })
      const searchInput = renderTypeahead()

      fireEvent.change(searchInput, { target: { value: "ac" } })
      await screen.findByRole("button", { name: "acme/api" })
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })

      expect(screen.getByRole("button", { name: "acme/api" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
    })

    it("highlights the last (bottommost) item on ArrowUp from the input", async () => {
      mockFkOptionsFetch({
        a: [{ value: 1, label: "alpha" }, { value: 2, label: "bravo" }, { value: 3, label: "gamma" }]
      })
      const searchInput = renderTypeahead()

      fireEvent.change(searchInput, { target: { value: "a" } })
      await screen.findByRole("button", { name: "gamma" })
      fireEvent.keyDown(searchInput, { key: "ArrowUp" })

      expect(screen.getByRole("button", { name: "gamma" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
      expect(screen.getByRole("button", { name: "alpha" })).not.toHaveClass("bg-gray-50")
    })

    it("selects the highlighted item on Enter, the same as a click", async () => {
      mockFkOptionsFetch({ ac: [{ value: 4, label: "acme/api" }] })
      const searchInput = renderTypeahead()

      fireEvent.change(searchInput, { target: { value: "ac" } })
      await screen.findByRole("button", { name: "acme/api" })
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "Enter" })

      await waitFor(() => {
        expect(decodedFilterFromLocation()).toEqual({
          and: [{ field: "repository_id", op: "is_one_of", value: ["4"] }]
        })
      })
    })

    it("resets the highlight when the query text changes", async () => {
      mockFkOptionsFetch({
        a: [{ value: 1, label: "alpha" }],
        al: [{ value: 1, label: "alpha" }]
      })
      const searchInput = renderTypeahead()

      fireEvent.change(searchInput, { target: { value: "a" } })
      await screen.findByRole("button", { name: "alpha" })
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      expect(screen.getByRole("button", { name: "alpha" })).toHaveClass("bg-gray-50")

      fireEvent.change(searchInput, { target: { value: "al" } })

      await waitFor(() => {
        expect(screen.getByRole("button", { name: "alpha" })).not.toHaveClass("bg-gray-50")
      })
    })

    it("no-ops on arrow keys when there are no matching options", async () => {
      mockFkOptionsFetch({})
      const searchInput = renderTypeahead()

      fireEvent.change(searchInput, { target: { value: "zzz-no-match" } })
      await screen.findByText("No matches")

      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "ArrowUp" })

      expect(screen.getByText("No matches")).toBeInTheDocument()
    })
  })

  describe("multi-select enum value editor", () => {
    function renderMulti() {
      render(
        <MemoryRouter initialEntries={["/dashboard/jobs"]}>
          <FilterBar
            filter={{ and: [{ field: "state", op: "is_none_of", value: [] }] }}
            filterSchema={filterSchema}
            pathname="/dashboard/jobs"
            search=""
          />
          <LocationProbe />
        </MemoryRouter>
      )

      fireEvent.click(screen.getByRole("button", { name: "State is none of (unset)" }))
      return screen.getByPlaceholderText("Search...")
    }

    it("highlights the first item on ArrowDown from the input, including a single-result menu", () => {
      const searchInput = renderMulti()

      fireEvent.change(searchInput, { target: { value: "open" } })
      fireEvent.keyDown(searchInput, { key: "ArrowDown" })

      expect(screen.getByRole("button", { name: "Open" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
    })

    it("highlights the last (bottommost) item on ArrowUp from the input", () => {
      const searchInput = renderMulti()

      fireEvent.keyDown(searchInput, { key: "ArrowUp" })

      expect(screen.getByRole("button", { name: "Closed" })).toHaveClass("bg-gray-50", "dark:bg-gray-800")
      expect(screen.getByRole("button", { name: "Open" })).not.toHaveClass("bg-gray-50")
    })

    it("selects the highlighted item on Enter, the same as a click", async () => {
      const searchInput = renderMulti()

      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "Enter" })

      await waitFor(() => {
        expect(decodedFilterFromLocation()).toEqual({
          and: [{ field: "state", op: "is_none_of", value: ["open"] }]
        })
      })
    })

    it("resets the highlight when the query text changes", () => {
      const searchInput = renderMulti()

      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      expect(screen.getByRole("button", { name: "Open" })).toHaveClass("bg-gray-50")

      fireEvent.change(searchInput, { target: { value: "c" } })

      expect(screen.getByRole("button", { name: "Closed" })).not.toHaveClass("bg-gray-50")
    })

    it("no-ops on arrow keys when the filtered list is empty", () => {
      const searchInput = renderMulti()

      fireEvent.change(searchInput, { target: { value: "zzz-no-match" } })
      expect(screen.getByText("No matches")).toBeInTheDocument()

      fireEvent.keyDown(searchInput, { key: "ArrowDown" })
      fireEvent.keyDown(searchInput, { key: "ArrowUp" })

      expect(screen.getByText("No matches")).toBeInTheDocument()
    })
  })

  it("scrolls the highlighted item into view when navigating with arrow keys", () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={null}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.keyDown(screen.getByPlaceholderText("Search filters..."), { key: "ArrowDown" })

    expect(scrollIntoView).toHaveBeenCalledWith({ block: "nearest" })
  })
})

describe("FilterBar German locale", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
    vi.restoreAllMocks()
  })

  it("renders operators in German when locale is de", async () => {
    await i18n.changeLanguage("de")

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

    expect(screen.getByRole("button", { name: "State ist Open" })).toBeInTheDocument()
  })

  it("renders unset placeholder in German when locale is de", async () => {
    await i18n.changeLanguage("de")

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "state", op: "is_none_of", value: [] }] }}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    expect(screen.getByRole("button", { name: "State ist keines von (leer)" })).toBeInTheDocument()
  })

  it("renders time units in German in the date filter editor", async () => {
    await i18n.changeLanguage("de")

    const dateFilterSchema: FilterSchemaField[] = [
      {
        field: "created_at",
        label: "Created",
        bucket: "date",
        operators: ["within_last"],
        values: []
      }
    ]

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={{ and: [{ field: "created_at", op: "within_last", value: { n: 7, unit: "days" } }] }}
          filterSchema={dateFilterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "Created in den letzten 7 Tagen" }))

    const unitSelect = screen.getByLabelText("Einheit")
    expect(within(unitSelect.closest("label")!).getByRole("option", { name: "Tagen" })).toBeInTheDocument()
    expect(within(unitSelect.closest("label")!).getByRole("option", { name: "Wochen" })).toBeInTheDocument()
    expect(within(unitSelect.closest("label")!).getByRole("option", { name: "Monaten" })).toBeInTheDocument()
  })

  it("renders bucket labels in German in the add-filter menu", async () => {
    await i18n.changeLanguage("de")

    render(
      <MemoryRouter initialEntries={["/dashboard/jobs"]}>
        <FilterBar
          filter={null}
          filterSchema={filterSchema}
          pathname="/dashboard/jobs"
          search=""
        />
      </MemoryRouter>
    )

    fireEvent.click(screen.getByRole("button", { name: "+ Filter hinzufügen" }))

    expect(screen.getByRole("button", { name: "State Liste" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Repository Referenz" })).toBeInTheDocument()
  })
})
