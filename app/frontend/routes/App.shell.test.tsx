import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { AppChromeV2 } from "./AppChromeV2"
import { bootstrapPayload, incompleteOnboardingBootstrap, setupStatus, setupStatusPayload, sidebarPluginPagesPayload } from "../test/app/bootstrap"
import { chatPayload, expectSyrusBrandLink, sidebarChat, sidebarGroups } from "../test/app/chatPayloads"
import { dashboardJobItem, dashboardPayload, dashboardPayloadPath, dashboardResponse } from "../test/app/dashboardPayloads"
import { credentialsPayload, notificationPreferencesPayload } from "../test/app/settingsPayloads"
import { mockMediaQuery } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App shell and navigation", () => {
  installAppTestLifecycle()

  it("renders system alert banners from bootstrap data", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        system_alerts: [
          {
            id: "data_root_disk_usage",
            dismissal_key: "data_root_disk_usage:critical:96",
            severity: "alarm",
            title: "Worker data volume usage is critical.",
            message:
              "SYRUS_DATA_ROOT is 96% full with <code>3.5GB</code> available. On single-host Docker installs this volume shares a disk with Docker's own image store.",
            action_steps: [
              "Check Docker's image store first: run <code>docker image prune -a</code> on the Docker host to delete unused images.",
              "Inspect retained workflow workspaces under <code>/syrus/workflows</code>."
            ],
            cta: { text: "Open admin overview", path: "/admin" }
          }
        ]
      })
    )
    document.body.appendChild(script)

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const alerts = await screen.findByRole("region", { name: "System alerts" })
    expect(within(alerts).getByRole("heading", { name: "Worker data volume usage is critical." })).toBeInTheDocument()
    expect(within(alerts).getByText("3.5GB")).toBeInTheDocument()
    // Action steps render server-provided HTML verbatim, so the docker-image
    // remedy (shared-disk reality) shows up as a copy-pasteable command.
    expect(within(alerts).getByText("docker image prune -a")).toBeInTheDocument()
    expect(within(alerts).getByText("/syrus/workflows")).toBeInTheDocument()
    expect(within(alerts).getByRole("link", { name: "Open admin overview" })).toHaveAttribute("href", "/app-shell/admin")

    const dismissButton = within(alerts).getByRole("button", { name: "Dismiss system alert" })
    const article = dismissButton.closest("article")
    expect(article).not.toBeNull()
    if (!article) throw new Error("Expected system alert dismiss button to be inside an alert article")

    const content = article.querySelector("[data-testid='system-alert-content']")
    const dismissContainer = article.querySelector("[data-testid='system-alert-dismiss-container']")
    expect(content).toContainElement(within(alerts).getByRole("heading", { name: "Worker data volume usage is critical." }))
    expect(content).not.toContainElement(dismissButton)
    expect(dismissContainer).toContainElement(dismissButton)
  })

  it("dismisses system alert banners only for the current warning fingerprint", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        system_alerts: [
          {
            id: "codex_usage:1",
            dismissal_key: "codex_usage:1:warning:2026-08-08T03:46:43Z:weekly=2026-08-08T03:46:43Z=19",
            severity: "warn",
            title: "Codex usage is low.",
            message: "Codex reports weekly 19% remaining for this account. Usage resets in 2 days, 5 hours.",
            action_steps: ["Pause or move Codex-backed automation to another provider before starting more work."],
            cta: { text: "Open credentials", path: "/credentials" }
          }
        ]
      })
    )
    document.body.appendChild(script)

    const view = render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Codex usage is low." })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Dismiss system alert" }))
    expect(screen.queryByRole("heading", { name: "Codex usage is low." })).not.toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.system_alert_dismissals")).toContain("2026-08-08T03:46:43Z")

    view.unmount()
    script.textContent = JSON.stringify(
      bootstrapPayload({
        system_alerts: [
          {
            id: "codex_usage:1",
            dismissal_key: "codex_usage:1:warning:2026-08-15T03:46:43Z:weekly=2026-08-15T03:46:43Z=19",
            severity: "warn",
            title: "Codex usage is low.",
            message: "Codex reports weekly 19% remaining for this account. Usage resets in 1 week.",
            action_steps: ["Pause or move Codex-backed automation to another provider before starting more work."],
            cta: { text: "Open credentials", path: "/credentials" }
          }
        ]
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Codex usage is low." })).toBeInTheDocument()
    script.remove()
  })

  it("renders shared app chrome from embedded bootstrap data", async () => {
    const script = document.createElement("script")
    const payload = {
      ...bootstrapPayload(),
      app: {
        revision: "9c0f8d15",
        revision_url: "https://github.com/tkadauke/syrus/commit/9c0f8d15"
      }
    }
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(payload)
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockRejectedValue(new Error("unexpected fetch"))

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expect(primaryNav).toBeInTheDocument()
      const accountNav = screen.getByRole("navigation", { name: "Account" })
      expectSyrusBrandLink("/app-shell")
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(within(primaryNav).queryByRole("link", { name: "Jobs" })).toBeNull()
      expect(within(primaryNav).queryByRole("link", { name: "Chat" })).toBeNull()
      expect(within(primaryNav).queryByRole("link", { name: "Admin" })).toBeNull()
      expect(within(accountNav).getByRole("button", { name: "operator@example.com" })).toHaveAttribute("aria-expanded", "false")
      expect(within(accountNav).queryByRole("link", { name: "Settings" })).toBeNull()
      expect(within(accountNav).queryByRole("button", { name: "Sign out" })).toBeNull()
      fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
      expect(within(accountNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/profile")
      expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("title", "Curia — The Roman Senate house")
      expect(within(accountNav).getByRole("button", { name: "Sign out" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      script.remove()
    }
  })

  it("toggles and persists the app shell theme", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user,
          theme: "dark"
        }
      })
    )
    document.body.appendChild(script)
    // Bare /app-shell renders the dashboard now, so each endpoint needs its
    // own response (a single shared Response body can only be read once).
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path === "/api/v1/app/theme") {
        return new Response(JSON.stringify({ theme: "light" }), { status: 200, headers: { "Content-Type": "application/json" } })
      }
      if (path.startsWith("/api/v1/app/dashboard")) {
        return new Response(JSON.stringify(dashboardPayload({ subject: "job", view: "list", items: [] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      }

      return new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const accountNav = await screen.findByRole("navigation", { name: "Account" })
      expect(document.documentElement).toHaveClass("dark")

      fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
      fireEvent.click(within(accountNav).getByRole("button", { name: "Light" }))

      expect(document.documentElement).not.toHaveClass("dark")
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/theme",
          expect.objectContaining({
            method: "PATCH",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({ theme: "light" })
          })
        )
      })
      expect(within(accountNav).getByRole("button", { name: "Light" })).toHaveAttribute("aria-pressed", "true")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("uses the v2 shell", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(async () => new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/session/new"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("navigation", { name: "Primary" })).toBeInTheDocument()
      expect(screen.getByRole("navigation", { name: "Account" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders a Publilius Syrus quote in the footer on non-chat routes", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(
        async () => new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
      )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/repositories"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByRole("navigation", { name: "Primary" })
      const link = screen.getByRole("link", { name: "Malum est consilium quod mutari non potest." })
      expect(link).toHaveAttribute("href", "https://en.wikipedia.org/wiki/Publilius_Syrus")
      const footer = link.closest("footer")
      expect(footer).toHaveClass("hidden", "lg:block")
    } finally {
      randomSpy.mockRestore()
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("hides the Publilius Syrus quote on chat routes", async () => {
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(
        async () => new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } })
      )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByRole("heading", { name: "What would you like to build?" })
      expect(screen.queryByRole("contentinfo")).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
    }
  })

  it("renders the v2 sidebar navigation and account popup actions", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        },
        team_user_count: 2
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/theme" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ theme: "dark" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/8", chat: chatPayload().chat }), {
            status: 201,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/sidebar_pages") {
        return Promise.resolve(new Response(JSON.stringify(sidebarPluginPagesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/session/new"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expectSyrusBrandLink("/app-shell")
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(await within(primaryNav).findByRole("link", { name: "Spending" })).toHaveAttribute("href", "/app-shell/insights/spending")
      expect(within(primaryNav).getByRole("link", { name: "Repositories" })).toHaveAttribute("href", "/app-shell/repositories")
      screen.getAllByRole("button", { name: "Report a bug" }).forEach((button) => {
        expect(button).not.toHaveClass("fixed")
      })

      fireEvent.click(screen.getByRole("button", { name: "operator@example.com" }))
      expect(screen.getByRole("button", { name: "Dark" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/app-shell/profiles/1")
      expect(screen.getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/profile")
      expect(screen.getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
      expect(screen.getByRole("link", { name: "Admin" })).toHaveAttribute("title", "Curia — The Roman Senate house")
      expect(screen.getByRole("button", { name: "Sign out" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Dark" }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/theme",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({ theme: "dark" })
          })
        )
      })

      fireEvent.click(screen.getByRole("button", { name: "New Chat" }))
      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      expect(await screen.findByRole("heading", { name: "What would you like to build?" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats", expect.objectContaining({ method: "POST", body: undefined }))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("hides v2 sidebar navigation behind Setup before onboarding chat starts", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        ...incompleteOnboardingBootstrap(),
        current_user: {
          ...bootstrapPayload().current_user,
          layout_version: "v2"
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/onboarding"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expect(within(primaryNav).getByRole("link", { name: "Setup" })).toHaveAttribute("href", "/app-shell/onboarding")
      expect(within(primaryNav).queryByRole("link", { name: "Dashboard" })).not.toBeInTheDocument()
      expect(within(primaryNav).queryByRole("link", { name: "Repositories" })).not.toBeInTheDocument()
      expect(within(primaryNav).queryByRole("link", { name: "Schedules" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("keeps Setup in the v2 sidebar and reveals navigation after onboarding chat starts", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        setup: setupStatusPayload({ complete: false, chat_started: true, onboarding_chat_path: "/chats/5", next_step: "epic" }),
        setup_status: setupStatus({
          state: "first_chat_started",
          next_step: "start_first_chat",
          next_step_path: "/onboarding",
          first_successful_job_completed: false,
          first_epic_landed: false,
          onboarding_chat_started: true
        }),
        current_user: {
          ...bootstrapPayload().current_user,
          layout_version: "v2"
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (String(input) === "/api/v1/app/sidebar_pages") {
        return Promise.resolve(new Response(JSON.stringify(sidebarPluginPagesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/onboarding"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expect(within(primaryNav).getByRole("link", { name: "Setup" })).toHaveAttribute("href", "/app-shell/onboarding")
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(await within(primaryNav).findByRole("link", { name: "Spending" })).toHaveAttribute("href", "/app-shell/insights/spending")
      expect(within(primaryNav).getByRole("link", { name: "Repositories" })).toHaveAttribute("href", "/app-shell/repositories")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("resizes the v2 desktop sidebar and stores the selected width", async () => {
    window.localStorage.setItem("syrus.sidebar.width", "300")
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/session/new"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const resizeHandle = await screen.findByRole("separator", { name: "Resize sidebar" })
      const sidebar = resizeHandle.closest("aside")
      expect(sidebar).toBeInstanceOf(HTMLElement)
      expect(sidebar).toHaveStyle({ width: "300px" })
      expect(resizeHandle).toHaveAttribute("aria-valuemin", "60")
      expect(resizeHandle).toHaveAttribute("aria-valuemax", "420")
      expect(resizeHandle).toHaveAttribute("aria-valuenow", "300")

      fireEvent.mouseDown(resizeHandle, { clientX: 300 })
      fireEvent.mouseMove(window, { clientX: 390 })
      await waitFor(() => {
        expect(sidebar).toHaveStyle({ width: "390px" })
        expect(window.localStorage.getItem("syrus.sidebar.width")).toBe("390")
      })

      fireEvent.mouseMove(window, { clientX: 900 })
      await waitFor(() => {
        expect(sidebar).toHaveStyle({ width: "420px" })
        expect(resizeHandle).toHaveAttribute("aria-valuenow", "420")
        expect(window.localStorage.getItem("syrus.sidebar.width")).toBe("420")
      })
      fireEvent.mouseUp(window)

      fireEvent.keyDown(resizeHandle, { key: "ArrowLeft" })
      expect(sidebar).toHaveStyle({ width: "404px" })
      expect(window.localStorage.getItem("syrus.sidebar.width")).toBe("404")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("keeps the v2 mobile brand trigger anchored in place after scroll, with no floating duplicate", async () => {
    const restoreMediaQuery = mockMediaQuery(true)
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/session/new"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByRole("navigation", { name: "Primary" })
      const anchoredTrigger = screen.getByRole("button", { name: "Open sidebar" })
      // The brand button is grouped with the TEST-channel badge in an inner
      // flex wrapper; the mobile top bar is the outer w-full row that also
      // holds the Notifications bell.
      const mobileTopBar = anchoredTrigger.closest("div.w-full")
      if (!(mobileTopBar instanceof HTMLElement)) throw new Error("Expected mobile top bar to render")
      expect(mobileTopBar).toHaveClass("w-full")
      expect(anchoredTrigger).not.toHaveClass("fixed")
      expect(within(anchoredTrigger).getByText("Syrus")).toBeInTheDocument()
      expect(anchoredTrigger.querySelector('[data-testid="syrus-mark"]')).not.toBeNull()
      // On mobile the bell opens the shared Activity shell instead of navigating.
      expect(within(mobileTopBar).getByRole("button", { name: "Notifications" })).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Open settings" })).not.toBeInTheDocument()

      // The chrome's scroll container is a div, not a landmark: routes render
      // the page's own <main> (see AppChromeV2).
      const scrollPane = screen.getByTestId("app-scroll-pane")
      expect(scrollPane).toBeInstanceOf(HTMLElement)
      Object.defineProperty(scrollPane, "scrollTop", { configurable: true, value: 24 })
      fireEvent.scroll(scrollPane as HTMLElement)

      // The scroll-triggered fixed-position duplicate of the brand/bell
      // buttons was removed (it used to overlap page content once scrolled);
      // the desktop sidebar (present but CSS-hidden on mobile) and the
      // anchored mobile top bar are the only remaining copies, and neither
      // is fixed-positioned.
      expect(screen.getAllByRole("button", { name: "Open sidebar" })).toHaveLength(1)
      expect(screen.getByRole("button", { name: "Open sidebar" })).not.toHaveClass("fixed")
      const notificationLinks = screen.getAllByRole("button", { name: "Notifications" })
      expect(notificationLinks.some((link) => link.parentElement?.classList.contains("fixed"))).toBe(false)

      fireEvent.click(anchoredTrigger)
      const drawerPrimaryNav = screen.getAllByRole("navigation", { name: "Primary" }).at(-1) as HTMLElement | undefined
      if (!(drawerPrimaryNav instanceof HTMLElement)) throw new Error("Expected drawer primary navigation to render")
      expect(within(drawerPrimaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(screen.getAllByRole("button", { name: "Close sidebar" }).length).toBeGreaterThan(0)
      expect(screen.getAllByRole("button", { name: "Notifications" }).length).toBeGreaterThan(0)
      expect(screen.getAllByRole("separator", { name: "Resize sidebar" })).toHaveLength(1)
    } finally {
      restoreMediaQuery()
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("omits dashboard subjects and smart folders from the v2 mobile drawer", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (dashboardPayloadPath(url)) {
        return Promise.resolve(
          dashboardResponse(
            dashboardPayload({
              subject: "job",
              active_smart_folder_id: 3,
              smart_folders: [
                {
                  id: 3,
                  name: "Merged this week",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "always",
                  count: 8,
                  active: true,
                  path: "/dashboard/jobs?smart_folder_id=3"
                }
              ],
              items: [dashboardJobItem()]
            }),
            path
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=3"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByLabelText("Dashboard smart folders panel")
      fireEvent.click(screen.getByRole("button", { name: "Open sidebar" }))
      const drawerPrimaryNav = screen.getAllByRole("navigation", { name: "Primary" }).at(-1) as HTMLElement | undefined
      if (!(drawerPrimaryNav instanceof HTMLElement)) throw new Error("Expected drawer primary navigation to render")

      expect(within(drawerPrimaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(within(drawerPrimaryNav).queryByRole("navigation", { name: "Dashboard sections" })).not.toBeInTheDocument()
      expect(within(drawerPrimaryNav).queryByLabelText("Dashboard smart folders panel")).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders v2 admin subnavigation above admin content with horizontal scrolling", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/admin/console") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              settings: {
                polling_paused: false,
                runs_paused: false,
                signups_open: true,
                max_job_failures: 3,
                grade_max_iterations: 2
              },
              users: [],
              recent_admin_actions: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/console"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Admin console" })).toBeInTheDocument()
      expect(screen.getByRole("navigation", { name: "Primary" })).toBeInTheDocument()
      const adminNav = screen.getByRole("navigation", { name: "Admin" })
      expect(adminNav.closest("aside")).toBeNull()
      expect(adminNav).toHaveClass("sticky", "overflow-y-auto")
      expect(within(adminNav).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(adminNav).getByRole("link", { name: "Queue" })).toHaveAttribute("href", "/app-shell/admin/queue")
      expect(within(adminNav).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
      expect(within(adminNav).getByRole("link", { name: "Invitations" })).toHaveAttribute("href", "/app-shell/invitations")
      expect(within(adminNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings/edit")
      expect(within(adminNav).getByRole("link", { name: "Overview" })).not.toHaveClass("bg-brand/10")
      expect(within(adminNav).getByRole("link", { name: "Console" })).toHaveClass("bg-brand/10", "text-brand")
      expect(within(adminNav).getByRole("link", { name: "Console" }).className).not.toMatch(/\b(?:bg|text)-blue-\d{2,3}\b/)
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/console",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders v2 settings routes with a left-hand settings navigation", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/profile"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(await screen.findByRole("main", { name: "Profile" })).toBeInTheDocument()
      const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
      expect(settingsNav.closest("aside")).toHaveClass("lg:w-56", "lg:border-r")
      // Mobile-width tab strip scrolls horizontally with no scrollbar; the edge
      // fade signals there's more to scroll to instead of looking clipped. It
      // must be turned off at the lg breakpoint, where the nav becomes a
      // non-scrolling vertical column.
      expect(settingsNav).toHaveClass("overflow-x-auto", "scroll-fade-x")
      expect(settingsNav.className).toMatch(/\blg:\[mask-image:none\]/)
      expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/app-shell/profile")
      expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveClass("bg-brand/10", "text-brand")
      expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
      expect(within(settingsNav).getByRole("link", { name: "Agent Settings" })).toHaveAttribute("href", "/app-shell/settings/agent")
      expect(within(settingsNav).getByRole("link", { name: "Preferences" })).toHaveAttribute("href", "/app-shell/settings/preferences")
      expect(within(settingsNav).getByRole("link", { name: "Themes" })).toHaveAttribute("href", "/app-shell/settings/themes")
      expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveAttribute("href", "/app-shell/settings/hidden_chats")
      expect(within(settingsNav).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/documents")
      expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveAttribute("href", "/app-shell/tags")
      expect(within(settingsNav).queryByRole("link", { name: "Design System" })).not.toBeInTheDocument()
      // Grouped like the Admin nav: account-configuration, product-feature,
      // workspace/library, and integration items each cluster under a header.
      expect(within(settingsNav).getByText("Account")).toBeInTheDocument()
      expect(within(settingsNav).getByText("Product")).toBeInTheDocument()
      expect(within(settingsNav).getByText("Workspace")).toBeInTheDocument()
      expect(within(settingsNav).getByText("Integrations")).toBeInTheDocument()
      expect(within(settingsNav).getByRole("link", { name: "Connected Platforms" })).toHaveAttribute("href", "/app-shell/settings/connected_platforms")
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credentials", expect.objectContaining({ credentials: "same-origin" }))
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/settings/hidden_chats?page=1", expect.anything())
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("restores hidden chats from v2 settings", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    let hiddenChats = [
      {
        ...sidebarChat({
          id: 42,
          title: "Archived planning",
          repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
          last_message_at: "2026-06-18T12:00:00Z"
        }),
        hidden_at: "2026-06-20T12:00:00Z",
        app_unhide_path: "/api/v1/app/chats/42/unhide"
      }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/settings/hidden_chats?page=1") {
        return Promise.resolve(
          new Response(JSON.stringify({ chats: hiddenChats, total: hiddenChats.length, page: 1, per_page: 20, total_pages: hiddenChats.length > 0 ? 1 : 0 }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/42/unhide" && init?.method === "PATCH") {
        hiddenChats = []
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Chat restored.",
              chat: sidebarChat({
                id: 42,
                title: "Archived planning",
                repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                last_message_at: "2026-06-18T12:00:00Z"
              })
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/settings/hidden_chats"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Hidden chats" })).toBeInTheDocument()
      const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
      expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveClass("bg-brand/10", "text-brand")
      expect(await screen.findByText("Archived planning")).toBeInTheDocument()
      expect(screen.getByText("acme/widgets")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Unhide" }))

      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/42/unhide", expect.objectContaining({ method: "PATCH" })))
      expect(await screen.findByText("Chat restored.")).toBeInTheDocument()
      expect(await screen.findByText("No hidden chats.")).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("groups recent chats in the v2 sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    const recentChats = [
      sidebarChat({ id: 1, title: "General latest", repository: null, last_message_at: "2026-06-20T12:00:00Z" }),
      sidebarChat({ id: 2, title: null, title_pending: true, repository: null, last_message_at: "2026-06-19T12:00:00Z", unread: true }),
      sidebarChat({
        id: 10,
        title: "Widgets active",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z",
        turn_in_flight: true
      }),
      sidebarChat({
        id: 11,
        title: "Widgets two",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      }),
      sidebarChat({
        id: 12,
        title: "Widgets three",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-16T12:00:00Z"
      }),
      sidebarChat({
        id: 13,
        title: "Widgets four",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-15T12:00:00Z"
      }),
      sidebarChat({
        id: 14,
        title: "Widgets five",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-14T12:00:00Z"
      }),
      sidebarChat({
        id: 15,
        title: "Widgets hidden",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-13T12:00:00Z"
      }),
      sidebarChat({
        id: 20,
        title: "Roads latest",
        repository: { id: 4, slug: "acme/roads", repository_path: "/repositories/4" },
        last_message_at: "2026-06-21T12:00:00Z"
      })
    ]
    const recentGroups = [
      { key: "repository-4", label: "acme/roads", repository_id: 4, chats: [recentChats[8]], has_more: false },
      { key: "general", label: "General", repository_id: null, chats: recentChats.slice(0, 2), has_more: false },
      { key: "repository-3", label: "acme/widgets", repository_id: 3, chats: recentChats.slice(2, 7), has_more: true }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: recentGroups, repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/chats/more?group_by=repository&group_key=3&before_id=14") {
        return Promise.resolve(
          new Response(JSON.stringify({ chats: [recentChats[7]], has_more: false }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/chats/10") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/10/bookmarks") {
        return Promise.resolve(
          new Response(JSON.stringify({ bookmarks: chatPayload().bookmarks }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/10"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toHaveClass("h-full")
      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      const sidebarScrollPane = recentNav.closest(".overflow-y-auto")
      const accountTrigger = screen.getByRole("button", { name: /operator@example\.com/ })
      expect(sidebarScrollPane).toBeInstanceOf(HTMLElement)
      expect(sidebarScrollPane).toContainElement(primaryNav)
      expect(sidebarScrollPane).not.toContainElement(accountTrigger)
      expect(sidebarScrollPane?.parentElement).toHaveClass("flex", "h-full", "flex-col")
      expect(accountTrigger.closest(".border-t")).toHaveClass("shrink-0")
      expect(recentNav.parentElement).not.toHaveClass("overflow-y-auto")
      expect(screen.getByRole("button", { name: "New Chat" }).closest(".sticky")).toHaveClass("sticky", "top-0")
      const headers = within(recentNav)
        .getAllByRole("heading")
        .map((heading) => heading.textContent)
      expect(headers).toEqual(["acme/roads", "General", "acme/widgets"])
      expect(within(recentNav).getByRole("link", { name: "New chat" })).toHaveAttribute("href", "/app-shell/chats/2")
      expect(within(recentNav).getByRole("link", { name: "New chat" })).toHaveClass("text-gray-700")
      expect(within(recentNav).getByText("New chat")).toHaveClass("font-semibold")
      expect(within(recentNav).getByRole("link", { name: "Widgets active" })).toHaveClass("bg-brand/10", "text-brand")
      expect(within(recentNav).getByRole("link", { name: "Widgets active" }).className).not.toMatch(/\b(?:bg|text)-blue-\d{2,3}\b/)
      expect(within(within(recentNav).getByRole("link", { name: "Widgets active" })).getByTestId("agent-replying-marker")).toBeInTheDocument()
      // The dropdown itself renders through a FloatingPortal (outside `recentNav`'s
      // DOM subtree) so flip/shift can reposition it clear of the sidebar's clipping
      // ancestor; query its content on `screen`, not `within(recentNav)`.
      fireEvent.click(within(recentNav).getByRole("button", { name: "Chat actions for Widgets active" }))
      expect(await screen.findByText("Bookmarks")).toHaveClass("font-semibold")
      expect(screen.getByRole("link", { name: "Aqueducts" })).toHaveAttribute("href", "#message-9")
      fireEvent.click(screen.getByRole("link", { name: "Aqueducts" }))
      expect(screen.queryByRole("link", { name: "Aqueducts" })).not.toBeInTheDocument()
      expect(within(recentNav).queryByRole("link", { name: "Widgets hidden" })).not.toBeInTheDocument()
      expect(within(recentNav).getByRole("button", { name: "acme/widgets" })).toHaveAttribute("aria-expanded", "true")

      fireEvent.click(within(recentNav).getByRole("button", { name: "Show more" }))

      expect(await within(recentNav).findByRole("link", { name: "Widgets hidden" })).toBeInTheDocument()

      fireEvent.click(within(recentNav).getByRole("button", { name: "acme/widgets" }))

      expect(within(recentNav).getByRole("button", { name: "acme/widgets" })).toHaveAttribute("aria-expanded", "false")
      expect(within(recentNav).queryByRole("link", { name: "Widgets active" })).not.toBeInTheDocument()
      expect(within(recentNav).queryByRole("link", { name: "Widgets hidden" })).not.toBeInTheDocument()
      expect(within(recentNav).getByRole("link", { name: "Roads latest" })).toBeInTheDocument()

      fireEvent.click(within(recentNav).getByRole("button", { name: "acme/widgets" }))

      expect(within(recentNav).getByRole("button", { name: "acme/widgets" })).toHaveAttribute("aria-expanded", "true")
      expect(within(recentNav).getByRole("link", { name: "Widgets active" })).toBeInTheDocument()
      expect(within(recentNav).getByRole("link", { name: "Widgets hidden" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  }, 30000)

  it("hides a chat from the v2 recent chats sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    let recentChats = [
      sidebarChat({
        id: 10,
        title: "Widgets active",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      }),
      sidebarChat({
        id: 11,
        title: "Widgets two",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/10") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ id: 10 })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/11") {
        const payload = chatPayload({ id: 11 })
        payload.bookmarks = []
        return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/11/hide" && init?.method === "PATCH") {
        recentChats = recentChats.filter((chat) => chat.id !== 11)
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Chat hidden.",
              chat: sidebarChat({
                id: 11,
                title: "Widgets two",
                repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
                last_message_at: "2026-06-17T12:00:00Z"
              })
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/10"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      expect(await within(recentNav).findByRole("link", { name: "Widgets two" })).toBeInTheDocument()

      // The dropdown renders through a FloatingPortal outside `recentNav`; query
      // its content on `screen`.
      fireEvent.click(within(recentNav).getByRole("button", { name: "Chat actions for Widgets two" }))
      expect(await screen.findByText("No bookmarks yet")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Hide Chat" }))

      expect(within(recentNav).queryByRole("link", { name: "Widgets two" })).not.toBeInTheDocument()
      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/11/hide", expect.objectContaining({ method: "PATCH" })))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("clears an active chat unread marker after opening it", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(
      bootstrapPayload({
        current_user: {
          ...bootstrapPayload().current_user
        },
        feature_flags: {
          v2_ui: true
        }
      })
    )
    document.body.appendChild(script)
    let recentChats = [
      sidebarChat({
        id: 10,
        title: "Widgets active",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z",
        unread: true
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/chats/10") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ id: 10 })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/10/mark_read") {
        recentChats = recentChats.map((chat) => (chat.id === 10 ? { ...chat, unread: false } : chat))
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/10"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )
      window.dispatchEvent(new Event("focus"))

      await screen.findByText("Widgets active")
      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/10/mark_read", expect.objectContaining({ method: "PATCH" })))
      await waitFor(() => expect(screen.getByText("Widgets active")).toHaveClass("font-medium"))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })
})
