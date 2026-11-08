import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { bootstrapPayload, incompleteOnboardingBootstrap, setupStatus, setupStatusPayload } from "../test/app/bootstrap"
import { chatPayload, expectSyrusBrandLink } from "../test/app/chatPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App onboarding", () => {
  installAppTestLifecycle()

  it("redirects the retired /setup route to onboarding", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(incompleteOnboardingBootstrap())
    document.body.appendChild(script)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/setup"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      expect(screen.getByRole("heading", { name: "Set up Syrus" })).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("redirects incomplete root visits to onboarding and points the Setup tab there", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(incompleteOnboardingBootstrap())
    document.body.appendChild(script)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      expectSyrusBrandLink("/app-shell")
      expect(screen.getByRole("link", { name: "Setup" })).toHaveAttribute("href", "/app-shell/onboarding")
      // Before the onboarding chat starts, the other top-level tabs are hidden.
      expect(screen.queryByRole("link", { name: "Dashboard" })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "Repositories" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("sends first-run users from the app root to onboarding", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        setup_status: setupStatus({
          state: "first_admin",
          next_step: "configure_credentials",
          next_step_path: "/credentials",
          credentials_configured: false,
          repository_configured: false,
          first_job_started: false,
          first_successful_job_completed: false,
          first_epic_landed: false,
          onboarding_chat_started: false,
          credential_status: {
            github: false,
            agent: false,
            active_agent_provider: "claude"
          },
          counts: {
            repositories: 0,
            jobs: 0,
            successful_jobs: 0
          }
        })
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockRejectedValue(new Error("unexpected fetch"))

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      expect(screen.getByRole("heading", { name: "Set up Syrus" })).toBeInTheDocument()
      expect(screen.queryByText("Work through the shortest path to a successful first run.")).not.toBeInTheDocument()
      expect(screen.queryByText(/of 6 complete/)).not.toBeInTheDocument()
      expect(screen.getAllByRole("listitem")).toHaveLength(6)
      // "Configure GitHub" opens an in-page token modal rather than navigating away.
      expect(screen.getByRole("button", { name: "Configure GitHub" })).toBeInTheDocument()
      expect(screen.getByText("Connect a personal access token and the GitHub App — both are required.")).toBeInTheDocument()
      expect(screen.queryByText("Operator can manage this Syrus instance.")).not.toBeInTheDocument()
      expect(screen.queryByText("Choose a provider and add its credentials.")).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      script.remove()
    }
  })

  it("shows the land-Epic step as the next action once the chat has started", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        setup_status: setupStatus({
          state: "first_chat_started",
          next_step: "start_first_chat",
          next_step_path: "/onboarding",
          first_successful_job_completed: false,
          first_epic_created: true,
          first_epic_started: true,
          first_epic_landed: false,
          onboarding_chat_started: true,
          counts: {
            repositories: 1,
            jobs: 0,
            successful_jobs: 0
          }
        })
      })
    )
    document.body.appendChild(script)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/onboarding"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      // Six steps remain for orientation, without the old header progress counter.
      expect(screen.getAllByRole("listitem")).toHaveLength(6)
      expect(screen.queryByText(/of 6 complete/)).not.toBeInTheDocument()
      expect(screen.getByText("Land your first Epic")).toBeInTheDocument()
      expect(screen.getByText("Your first Epic is in progress. Approve its Jobs so they can land.")).toBeInTheDocument()
      expect(screen.queryByText("You've started the Syrus chat. The other tabs are now unlocked.")).not.toBeInTheDocument()
      // The chat steps are buttons (they launch/open the seeded chat), not links.
      expect(screen.getAllByRole("button", { name: "Open Syrus chat" }).length).toBeGreaterThan(0)
    } finally {
      script.remove()
    }
  })

  it("reveals the other nav tabs as soon as the onboarding chat starts, without a reload", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(incompleteOnboardingBootstrap())
    document.body.appendChild(script)

    const started = bootstrapPayload({
      setup: setupStatusPayload({ complete: false, chat_started: true, onboarding_chat_path: "/chats/5", next_step: "epic" }),
      setup_status: setupStatus({
        state: "first_chat_started",
        next_step: "start_first_chat",
        next_step_path: "/onboarding",
        first_successful_job_completed: false,
        first_epic_landed: false,
        onboarding_chat_started: true
      })
    })

    vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const url = String(input)
      if (url.endsWith("/api/v1/app/chats/onboarding") && (init as RequestInit)?.method === "POST") {
        return new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/5", chat: chatPayload().chat }), {
          status: 201,
          headers: { "Content-Type": "application/json" }
        })
      }
      if (url.endsWith("/api/v1/app/chats/5")) {
        return new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
      }
      if (url.endsWith("/api/v1/app/chats/5/mark_read") && (init as RequestInit)?.method === "PATCH") {
        return new Response(null, { status: 204 })
      }
      if (url.endsWith("/api/v1/app/chats/5")) {
        return new Response(JSON.stringify(chatPayload({ id: 5, chatPath: "/chats/5" })), { status: 200, headers: { "Content-Type": "application/json" } })
      }
      if (url.endsWith("/api/v1/app/bootstrap")) {
        return new Response(JSON.stringify(started), { status: 200, headers: { "Content-Type": "application/json" } })
      }
      return new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/onboarding"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      // Tabs are hidden before the onboarding chat starts.
      expect(screen.queryByRole("link", { name: "Dashboard" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Start Syrus chat" }))

      // Starting the chat refreshes bootstrap, revealing the nav tabs in place.
      expect(await screen.findByRole("link", { name: "Dashboard" })).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("shows completion on onboarding once the first Epic lands", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/onboarding"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Onboarding" })).toBeInTheDocument()
      expect(screen.getByText("Ready for normal operations")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Open dashboard" })).toHaveAttribute("href", "/dashboard/jobs?view=list")
    } finally {
      script.remove()
    }
  })
})
