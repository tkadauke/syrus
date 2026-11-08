import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { jobDetailPayload } from "../test/app/jobPayloads"
import { directJobFormPayload } from "../test/app/repositoryPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App direct jobs", () => {
  installAppTestLifecycle()

  it("renders the direct job form, applies a template, and creates another job", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Direct job created.",
              create_more: true,
              redirect_to: "/jobs/new?repository_id=3&create_more=1",
              job: {
                id: 44,
                title: "Configure Syrus build dependencies",
                state: "queued",
                repository: {
                  id: 3,
                  slug: "acme/widgets",
                  repository_path: "/repositories/3",
                  default_agent_provider: "codex",
                  default_agent_provider_label: "Codex"
                },
                job_path: "/jobs/44"
              }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(directJobFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/new?repository_id=3&create_more=1"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "New direct job" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "New direct job" })).toHaveClass("text-text-primary")
    expect(await screen.findByDisplayValue("acme/widgets")).toBeInTheDocument()
    expect(screen.getByText("Target").closest("section")).toHaveClass("dark:bg-gray-900", "dark:border-gray-700")
    expect(screen.getByLabelText("Create More")).toBeChecked()
    expect(screen.getByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
    fireEvent.click(screen.getByRole("button", { name: /Configure Syrus build dependencies/ }))
    expect(screen.getByDisplayValue("Configure Syrus build dependencies")).toBeInTheDocument()
    expect(screen.getByDisplayValue("Write a .syrus.yml setup file.")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Google Doc URL"), { target: { value: "https://docs.google.com/document/d/context/edit" } })
    fireEvent.click(screen.getByRole("button", { name: "Create job" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.any(FormData)
        })
      )
    })
    const postCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/jobs" && call[1]?.method === "POST")
    const body = postCall?.[1]?.body as FormData
    expect(body.get("repository_id")).toBe("3")
    expect(body.get("agent_provider")).toBe("")
    expect(body.get("title")).toBe("Configure Syrus build dependencies")
    expect(body.get("prompt")).toBe("Write a .syrus.yml setup file.")
    expect(body.get("priority")).toBe("medium")
    expect(body.get("create_more")).toBe("1")
    expect(body.get("job_attachment[google_doc_url]")).toBe("https://docs.google.com/document/d/context/edit")
    expect(await screen.findByText("Direct job created.")).toBeInTheDocument()
  })

  it("links from the empty direct job form within the React shell", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...directJobFormPayload(),
            repositories: [],
            selected_repository_id: null
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "No active repositories" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Add repository" })).toHaveAttribute("href", "/app-shell/repositories/new")
  })

  it("creates a direct job and navigates within the React shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Direct job created.",
              create_more: false,
              redirect_to: "/jobs/44",
              job: {
                id: 44,
                title: "Configure Syrus build dependencies",
                state: "queued",
                repository: {
                  id: 3,
                  slug: "acme/widgets",
                  repository_path: "/repositories/3",
                  default_agent_provider: "codex",
                  default_agent_provider_label: "Codex"
                },
                job_path: "/jobs/44"
              }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/jobs/44") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              jobDetailPayload({
                job: {
                  id: 44,
                  kind: "direct",
                  issue_number: null,
                  issue_title: null,
                  issue_body: "Write a .syrus.yml setup file.",
                  pr_number: null,
                  pr_url: null
                },
                paths: {
                  job_path: "/jobs/44",
                  source_path: "/jobs/44/source",
                  app_detail_path: "/api/v1/app/jobs/44",
                  app_source_path: "/api/v1/app/jobs/44/source"
                }
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(directJobFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/new?repository_id=3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /Configure Syrus build dependencies/ }))
    fireEvent.click(screen.getByLabelText("Create More"))
    fireEvent.click(screen.getByRole("button", { name: "Create job" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.any(FormData)
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Job" })).toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/44",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
  })
})
