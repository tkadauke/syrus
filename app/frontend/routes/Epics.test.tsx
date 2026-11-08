import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { epicDetailPayload, epicFormPayload } from "../test/app/repositoryPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App Epics", () => {
  installAppTestLifecycle()

  it("renders the new epic form and submits it to the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              error: {
                code: "validation_failed",
                message: "Title can't be blank"
              }
            }),
            { status: 422, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(epicFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "New Epic" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/dashboard/epics")
    fireEvent.change(await screen.findByLabelText("Title"), { target: { value: "Raise the forum" } })
    fireEvent.change(screen.getByLabelText("Description"), { target: { value: "Install tasteful columns." } })
    fireEvent.change(screen.getByLabelText("Repository"), { target: { value: "3" } })
    fireEvent.change(screen.getByLabelText("GitHub issue URL"), { target: { value: "https://github.com/acme/widgets/issues/12" } })
    fireEvent.click(screen.getByRole("button", { name: "Create Epic" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({
            epic: {
              title: "Raise the forum",
              description: "Install tasteful columns.",
              repository_id: "3",
              github_issue_url: "https://github.com/acme/widgets/issues/12"
            }
          })
        })
      )
    })
    expect(await screen.findByText("Title can't be blank")).toBeInTheDocument()
  })

  it("creates an Epic and navigates within the React shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Epic created.",
              redirect_to: "/epics/7",
              epic: {
                id: 7,
                title: "Raise the forum",
                description: "Install tasteful columns.",
                repository_id: 3,
                github_issue_url: "https://github.com/acme/widgets/issues/12",
                epic_path: "/epics/7"
              }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/epics/7") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              epicDetailPayload({
                message: "Epic created."
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(epicFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByLabelText("Title"), { target: { value: "Raise the forum" } })
    fireEvent.change(screen.getByLabelText("Description"), { target: { value: "Install tasteful columns." } })
    fireEvent.change(screen.getByLabelText("Repository"), { target: { value: "3" } })
    fireEvent.change(screen.getByLabelText("GitHub issue URL"), { target: { value: "https://github.com/acme/widgets/issues/12" } })
    fireEvent.click(screen.getByRole("button", { name: "Create Epic" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({
            epic: {
              title: "Raise the forum",
              description: "Install tasteful columns.",
              repository_id: "3",
              github_issue_url: "https://github.com/acme/widgets/issues/12"
            }
          })
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Epic" })).toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
  })

  it("renders the edit Epic form with React shell links", async () => {
    const basePayload = epicFormPayload()
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...basePayload,
            epic: {
              ...basePayload.epic,
              id: 7,
              title: "Raise the forum",
              repository_id: 3,
              epic_path: "/epics/7"
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Edit Epic" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Edit Epic" })).toHaveClass("text-text-primary")
    expect(screen.getByLabelText("Title")).toHaveClass("bg-surface", "text-text-primary", "border-border")
    expect(await screen.findByRole("link", { name: "Back to Epic" })).toHaveAttribute("href", "/app-shell/epics/7")
    expect(screen.getByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/epics/7")
  })

  it("renders an Epic detail page and updates state through the app API", async () => {
    let currentPayload = epicDetailPayload()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        currentPayload = epicDetailPayload({
          message: "Epic updated.",
          state: "in_progress",
          epic: {
            owner_user_id: 1,
            owner_status: "mine",
            owner_user: { id: 1, email_address: "operator@example.com" },
            owned_by_current_user: true,
            claimable: false
          },
          stateTransitions: [
            { label: "Move back to ready", target_state: "ready", confirm: null },
            { label: "Archive", target_state: "archived", confirm: "Archive this Epic?" }
          ]
        })
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated.", epic: currentPayload.epic }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Epic" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: /EPIC-7/ })).toBeInTheDocument()
    expect(screen.getByText("Raise the forum", { selector: "h1,h2,h3" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: /EPIC-7/ })).toHaveClass("text-text-primary")
    expect(screen.queryByRole("link", { name: "Back to Epics" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/epics/7/edit")
    expect(screen.getAllByRole("link", { name: "acme/widgets" }).every((el) => el.getAttribute("href") === "/app-shell/repositories/3")).toBe(true)
    expect(screen.getByText("columns")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Jobs (1)" }))
    expect(screen.getByRole("link", { name: "Survey forum" })).toHaveAttribute("href", "/app-shell/jobs/42")
    fireEvent.click(screen.getByRole("button", { name: "Dependencies" }))
    expect(screen.getByText("(1 epic dep, 0 job blockers)")).toBeInTheDocument()
    expect(screen.getByText("Dependency graph").closest("details")).toHaveClass("dark:bg-gray-900", "dark:border-gray-700")
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menuitem", { name: "Move to backlog" })).toBeInTheDocument()
    expect(screen.getByRole("progressbar")).toBeInTheDocument()
    expect(screen.getByText("1 Closed")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("menuitem", { name: "Start" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/state",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ target_state: "in_progress" })
        })
      )
    })
    expect(await screen.findByText("Epic updated.")).toBeInTheDocument()
    expect(screen.getByText("In Progress")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/epics/7/edit")
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menuitem", { name: "Move back to ready" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Archive" })).toBeInTheDocument()
  })

  it("renders and removes Epic dependencies from the detail page", async () => {
    let currentPayload = epicDetailPayload({
      dependencies: [{ epic_id: 6, title: "Deliver marble", state: "done", url: "/epics/6" }],
      dependents: [{ epic_id: 8, title: "Polish search UI", state: "in_progress", url: "/epics/8" }]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/dependencies/6" && init?.method === "DELETE") {
        currentPayload = epicDetailPayload({
          message: "Dependency removed.",
          dependencies: [],
          dependents: [{ epic_id: 8, title: "Polish search UI", state: "in_progress", url: "/epics/8" }]
        })
        return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Dependencies" }))
    expect(await screen.findByRole("heading", { name: "Dependencies" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Deliver marble" })).toHaveAttribute("href", "/app-shell/epics/6")
    expect(screen.getByText("Done")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Polish search UI" })).toHaveAttribute("href", "/app-shell/epics/8")

    fireEvent.click(screen.getByRole("button", { name: "Remove dependency on Deliver marble" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/epics/7/dependencies/6", expect.objectContaining({ method: "DELETE", credentials: "same-origin" }))
    })
    expect(await screen.findByText("Dependency removed.")).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole("link", { name: "Deliver marble" })).not.toBeInTheDocument())
  })

  it("adds Epic dependencies and reports cycle errors inline", async () => {
    let currentPayload = epicDetailPayload({ dependencies: [], dependents: [] })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/filters/fk_options")) {
        const url = new URL(path, "http://syrus.test")
        const query = url.searchParams.get("q")
        const options =
          query === "Cycle" ? [{ value: 10, label: "Cycle dependency" }] : query === "Index" ? [{ value: 9, label: "Index chat transcripts" }] : []
        return Promise.resolve(new Response(JSON.stringify({ options }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/epics/7/dependencies" && init?.method === "POST") {
        if (init.body === JSON.stringify({ depends_on_epic_id: 10 })) {
          return Promise.resolve(
            new Response(JSON.stringify({ error: { code: "validation_failed", message: "Depends on epic would create a cycle" } }), {
              status: 422,
              headers: { "Content-Type": "application/json" }
            })
          )
        }
        currentPayload = epicDetailPayload({
          message: "Dependency added.",
          dependencies: [{ epic_id: 9, title: "Index chat transcripts", state: "ready", url: "/epics/9" }],
          dependents: []
        })
        return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Dependencies" }))
    await waitFor(() => expect(screen.getAllByText("None")).toHaveLength(2))

    fireEvent.change(screen.getByLabelText("Add dependency"), { target: { value: "Cycle" } })
    fireEvent.click(await screen.findByRole("button", { name: "Cycle dependency" }))
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Depends on epic would create a cycle")

    fireEvent.change(screen.getByLabelText("Add dependency"), { target: { value: "Index" } })
    fireEvent.click(await screen.findByRole("button", { name: "Index chat transcripts" }))
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/filters/fk_options?field=epic_id&q=Index", expect.objectContaining({ credentials: "same-origin" }))
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/dependencies",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ depends_on_epic_id: 9 })
        })
      )
    })
    expect(await screen.findByText("Dependency added.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Index chat transcripts" })).toHaveAttribute("href", "/app-shell/epics/9")
    expect(screen.getByLabelText("Add dependency")).toHaveDisplayValue("")
  })

  it("claims and unclaims an Epic from the detail controls", async () => {
    let currentPayload = epicDetailPayload()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/claim" && init?.method === "PATCH") {
        currentPayload = epicDetailPayload({
          epic: { owner_user_id: 1, owner_status: "mine", owner_user: { id: 1, email_address: "operator@example.com" }, owned_by_current_user: true }
        })
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic claimed.", epic: currentPayload.epic }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/epics/7/unclaim" && init?.method === "PATCH") {
        currentPayload = epicDetailPayload()
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic unclaimed.", epic: currentPayload.epic }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(new Response(JSON.stringify(currentPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Claim" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Unclaim" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Claim" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/epics/7/claim", expect.objectContaining({ method: "PATCH", credentials: "same-origin" }))
    })
    expect(await screen.findByText("Epic claimed.")).toBeInTheDocument()
    expect(screen.getByText(/Owner operator@example\.com/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Claim" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Unclaim" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Unclaim" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/epics/7/unclaim", expect.objectContaining({ method: "PATCH", credentials: "same-origin" }))
    })
    expect(await screen.findByText("Epic unclaimed.")).toBeInTheDocument()
    expect(screen.getAllByText(/Unclaimed/).length).toBeGreaterThan(0)
  })

  it("does not show claim controls for an Epic owned by another user", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            epicDetailPayload({
              epic: {
                owner_user_id: 2,
                owner_status: "other_owned",
                owner_user: { id: 2, email_address: "teammate@example.com" },
                owned_by_current_user: false
              }
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText(/Owner teammate@example\.com/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Claim" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Unclaim" })).not.toBeInTheDocument()
  })
})
