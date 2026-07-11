import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, useLocation } from "react-router-dom"
import { App } from "./App"
import type { BootstrapPayload } from "../api/bootstrap"
import type { JobStep } from "../api/jobs"
import * as videoWalkthroughs from "../api/videoWalkthroughs"

const actionCable = vi.hoisted(() => ({
  createSubscription: vi.fn(() => ({ unsubscribe: vi.fn() }))
}))

const excalidrawMock = vi.hoisted(() => ({
  throwOnRender: false,
  addFiles: vi.fn(),
  lastInitialData: null as { appState?: Record<string, unknown>; elements?: unknown[]; files?: Record<string, Record<string, unknown>> } | null,
  updateScene: vi.fn()
}))

const html2canvasMock = vi.hoisted(() => vi.fn(async () => ({
  toBlob(callback: (blob: Blob | null) => void) {
    callback(new Blob(["screenshot"], { type: "image/png" }))
  }
})))

const mermaidMock = vi.hoisted(() => ({
  initialize: vi.fn(),
  render: vi.fn(async (_id: string, definition: string) => ({
    svg: `<svg role="img" aria-label="Dependency graph"><text>${definition}</text></svg>`
  }))
}))

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: actionCable.createSubscription
    }
  })
}))

vi.mock("@excalidraw/excalidraw", () => ({
  Excalidraw: ({ excalidrawAPI, initialData, onChange }: {
    excalidrawAPI?: (api: { addFiles: typeof excalidrawMock.addFiles; updateScene: typeof excalidrawMock.updateScene }) => void
    initialData?: { appState?: Record<string, unknown>; elements?: unknown[]; files?: Record<string, Record<string, unknown>> }
    onChange?: (elements: unknown[], appState: Record<string, unknown>, files: Record<string, Record<string, unknown>>) => void
  }) => {
    if (excalidrawMock.throwOnRender) throw new Error("Canvas crashed")

    excalidrawMock.lastInitialData = initialData || null
    excalidrawAPI?.({ addFiles: excalidrawMock.addFiles, updateScene: excalidrawMock.updateScene })

    return (
      <button
        onClick={() => onChange?.(
          [...(initialData?.elements || []), { id: "shape-react", type: "image", fileId: "file-react", version: 1 }],
          { ...(initialData?.appState || {}), viewBackgroundColor: "#ffffff", selectedElementIds: { "shape-react": true } },
          {
            ...(initialData?.files || {}),
            "file-react": {
              id: "file-react",
              dataURL: "data:image/png;base64,abc",
              mimeType: "image/png",
              created: 1
            }
          }
        )}
        type="button"
      >
        Draw on whiteboard
      </button>
    )
  }
}))

vi.mock("html2canvas-pro", () => ({
  default: html2canvasMock
}))

vi.mock("mermaid", () => ({
  default: mermaidMock
}))

let restoreClipboardMock: (() => void) | null = null

describe("App", () => {
  beforeEach(() => {
    document.getElementById("syrus-bootstrap-data")?.remove()
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    document.documentElement.classList.remove("dark")
    excalidrawMock.throwOnRender = false
    excalidrawMock.addFiles.mockClear()
    excalidrawMock.lastInitialData = null
    excalidrawMock.updateScene.mockClear()
    html2canvasMock.mockClear()
    mermaidMock.initialize.mockClear()
    mermaidMock.render.mockClear()
    actionCable.createSubscription.mockClear()
    document.documentElement.classList.remove("dark")
  })

  afterEach(() => {
    restoreClipboardMock?.()
    restoreClipboardMock = null
  })

  it("loads bootstrap data into the SPA shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          current_user: {
            id: 1,
            email_address: "operator@example.com",
            name: "Operator",
            first_name: null,
            last_name: null,
            display_name: "Operator",
            admin: true,
            scheduling_paused: false,
            landing_paused: false,
            agent_provider: "claude",
            agent_max_turns: 200,
            theme: "light"
          },
          team_user_count: 1,
          app: {
            revision: "dev",
            revision_url: null
          },
          navigation: {
            default_chat_path: "/dashboard"
          },
          csrf_token: "csrf-token",
          feature_flags: {}
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        {/* Bare /app-shell now routes to the dashboard like "/"; the debug
            shell only serves unregistered paths. */}
        <MemoryRouter initialEntries={["/app-shell/debug"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Syrus SPA" })).toBeInTheDocument()
    const accountNav = await screen.findByRole("navigation", { name: "Account" })
    expect(within(accountNav).getByRole("button", { name: "operator@example.com" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByRole("link", { name: "Settings" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Sign out" })).not.toBeInTheDocument()
    fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
    expect(within(accountNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/profile")
    expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
    expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("title", "Curia — The Roman Senate house")
    expect(within(accountNav).getByRole("button", { name: "Sign out" })).toBeInTheDocument()
    expect(screen.getAllByText("dev").length).toBeGreaterThan(0)
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/bootstrap",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
    expect(actionCable.createSubscription).toHaveBeenCalledWith(
      { channel: "AppUserChannel" },
      expect.objectContaining({ received: expect.any(Function) })
    )
  })

  it("routes bare /app-shell to the dashboard for signed-in users", async () => {
    // Before RootRoute covered /app-shell, the bare desktop entry path fell
    // through to the debug catch-all instead of behaving like "/".
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/dashboard")) {
        return new Response(
          JSON.stringify(dashboardPayload({ subject: "job", view: "list", items: [dashboardJobItem()] })),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
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

      expect(await screen.findByRole("main", { name: "Dashboard" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus SPA" })).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      script.remove()
    }
  })

  it("renders system alert banners from bootstrap data", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      system_alerts: [
        {
          id: "data_root_disk_usage",
          severity: "alarm",
          title: "Worker data volume usage is critical.",
          message: "SYRUS_DATA_ROOT is 96% full with <code>3.5GB</code> available. On single-host Docker installs this volume shares a disk with Docker's own image store.",
          action_steps: [
            "Check Docker's image store first: run <code>docker image prune -a</code> on the Docker host to delete unused images.",
            "Inspect retained workflow workspaces under <code>/syrus/workflows</code>."
          ],
          cta: { text: "Open admin overview", path: "/admin" }
        }
      ]
    }))
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
  })

  it("renders a minimal first-run welcome for a new instance", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: true })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const welcome = await screen.findByRole("main", { name: "Syrus first-run welcome" })
    expect(screen.getByRole("heading", { name: "Welcome to Syrus!" })).toBeInTheDocument()
    // Versioned icon URL: public/ files are cached for a year, so an
    // unversioned /icon.png would show a previous backend's stale artwork.
    expect(welcome.querySelector("img")?.getAttribute("src")).toMatch(/^\/icon\.png\?v=\d+$/)
    expect(screen.getByRole("link", { name: "Set up this Syrus instance" })).toHaveAttribute("href", "/users/new")
    expect(screen.getByText("No users exist yet. The first account becomes the administrator for this instance.")).toBeInTheDocument()
    // No "Sign in" when there are no users yet — there's nobody to sign in as.
    expect(screen.queryByRole("link", { name: "Sign in" })).not.toBeInTheDocument()
    // The marketing pitch stays off the first-run screen.
    expect(screen.queryByRole("region", { name: "Workflow" })).not.toBeInTheDocument()
    expect(screen.queryByText("Syrus turns GitHub issues into reviewed pull requests.")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/bootstrap",
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("renders invitation-only landing CTA for locked instances", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: false })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus public landing" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Sign in" })[0]).toHaveAttribute("href", "/session/new")
    expect(screen.getAllByText("This instance is invitation-only. Ask the operator for an invitation if you need access.").length).toBeGreaterThan(0)
    expect(screen.getByText("Access to this Syrus instance is controlled by its operator. Use an invitation link, or sign in with an existing account.")).toBeInTheDocument()
  })

  it("renders account creation CTA when signups are open", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: true })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus public landing" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Create account" })[0]).toHaveAttribute("href", "/users/new")
    expect(screen.getAllByText("Open sign-ups are enabled for this instance.").length).toBeGreaterThan(0)
  })

  it("renders account creation CTA when an invitation token is present", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: false })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/?token=invite-123"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus public landing" })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Create account from invitation" })[0]).toHaveAttribute("href", "/users/new?token=invite-123")
    expect(screen.getByText("Detected")).toBeInTheDocument()
  })

  it("skips the marketing landing inside the desktop shell and lands on sign-in", async () => {
    // Desktop users who are merely signed out already installed the app —
    // they need the sign-in form, not the self-hosting pitch.
    const restoreUserAgent = stubDesktopUserAgent()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: false })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Sign in" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus public landing" })).not.toBeInTheDocument()
    } finally {
      restoreUserAgent()
    }
  })

  it("routes desktop-shell invitation links straight to the invite signup", async () => {
    const restoreUserAgent = stubDesktopUserAgent()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/auth/signup")) {
        return new Response(
          JSON.stringify({
            allowed: true,
            first_signup: false,
            signups_open: false,
            invitation: { token: "invite-123", email_address: "guest@example.com", invited_by_email: "admin@example.com" }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      }

      return new Response(JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: false })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/?token=invite-123"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Create account" })).toBeInTheDocument()
      expect(await screen.findByText("Accepting an invitation from admin@example.com.")).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus public landing" })).not.toBeInTheDocument()
      // The token must survive the desktop redirect — the signup page's state
      // fetch carries it as the query string.
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/auth/signup?token=invite-123",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      restoreUserAgent()
    }
  })

  it("keeps the first-run welcome inside the desktop shell", async () => {
    // First run IS the desktop first-run screen — no redirect to sign-in
    // (there is nobody to sign in as yet).
    const restoreUserAgent = stubDesktopUserAgent()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(publicBootstrapPayload({ first_signup: true })), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Syrus first-run welcome" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Set up this Syrus instance" })).toHaveAttribute("href", "/users/new")
    } finally {
      restoreUserAgent()
    }
  })

  it("renders the sign-in route and submits credentials through the auth API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ error: { code: "invalid_credentials", message: "Try another email address or password." } }),
        { status: 422, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/session/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Sign in" })).toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Account" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Admin" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Settings" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Sign out" })).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "operator@example.com" } })
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "wrong" } })
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/auth/session",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ email_address: "operator@example.com", password: "wrong" })
        })
      )
    })
    expect(await screen.findByText("Try another email address or password.")).toBeInTheDocument()
  })

  it("renders the sign-up route from the public signup payload", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          allowed: true,
          first_signup: true,
          signups_open: false,
          invitation: null
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/users/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Create account" })).toBeInTheDocument()
    expect(await screen.findByText("No users exist yet. This account will become the administrator.")).toBeInTheDocument()
    // First signup: no "Already have an account? Sign in" — nobody to sign in as.
    expect(screen.queryByRole("link", { name: "Already have an account? Sign in" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/auth/signup",
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("shows the sign-in link on the sign-up route once users exist", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ allowed: true, first_signup: false, signups_open: true, invitation: null }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/users/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Already have an account? Sign in" })).toHaveAttribute("href", "/app-shell/session/new")
  })

  it("renders the logged-out landing CTA from public bootstrap state", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(publicBootstrapPayload()),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/?token=invite-token"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus public landing" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Create account from invitation" })).toHaveAttribute("href", "/users/new?token=invite-token")
    expect(screen.getAllByText("Invitation-only").length).toBeGreaterThan(0)
    expect(screen.getByText("Invitation link")).toBeInTheDocument()
    expect(screen.getByText("Detected")).toBeInTheDocument()
    expect(screen.getByText("An invitation token is present in this link. Create your account to join this instance.")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/bootstrap",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("routes signed-in root to the dashboard instead of the public landing page", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [dashboardJobItem()]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Dashboard" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus public landing" })).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders the password request route and shows the API response message", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          message: "Password reset instructions sent (if user with that email address exists).",
          redirect_to: "/session/new"
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/passwords/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Reset password" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Back to sign in" })).toHaveAttribute("href", "/app-shell/session/new")
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "operator@example.com" } })
    fireEvent.click(screen.getByRole("button", { name: "Email reset instructions" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/auth/passwords",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ email_address: "operator@example.com" })
        })
      )
    })
    expect(await screen.findByText("Password reset instructions sent (if user with that email address exists).")).toBeInTheDocument()
  })

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
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).toHaveAttribute("href", "/app-shell/scheduled_tasks")
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
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      script.remove()
    }
  })

  it("toggles and persists the app shell theme", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
        theme: "dark"
      }
    }))
    document.body.appendChild(script)
    // Bare /app-shell renders the dashboard now, so each endpoint needs its
    // own response (a single shared Response body can only be read once).
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const path = String(input)
      if (path === "/api/v1/app/theme") {
        return new Response(JSON.stringify({ theme: "light" }), { status: 200, headers: { "Content-Type": "application/json" } })
      }
      if (path.startsWith("/api/v1/app/dashboard")) {
        return new Response(
          JSON.stringify(dashboardPayload({ subject: "job", view: "list", items: [] })),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
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
      fireEvent.click(within(accountNav).getByRole("button", { name: "Switch to light mode" }))

      expect(document.documentElement).not.toHaveClass("dark")
      expect(within(accountNav).getByRole("button", { name: "Switch to dark mode" })).toBeInTheDocument()
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
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } })
    )

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
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
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
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } })
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      },
      team_user_count: 2
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/theme" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ theme: "dark" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/8", chat: chatPayload().chat }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } }))
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
      expect(within(primaryNav).getByRole("link", { name: "Spending" })).toHaveAttribute("href", "/app-shell/insights/spending")
      expect(within(primaryNav).getByRole("link", { name: "Repositories" })).toHaveAttribute("href", "/app-shell/repositories")
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).toHaveAttribute("href", "/app-shell/scheduled_tasks")
      expect(within(primaryNav).getByRole("link", { name: "Team" })).toHaveAttribute("href", "/app-shell/profiles")
      expect(screen.getByRole("button", { name: "Report a bug" })).toHaveClass("bottom-4", "right-4")

      fireEvent.click(screen.getByRole("button", { name: "operator@example.com" }))
      expect(screen.getByRole("button", { name: "Switch to dark mode" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/app-shell/profiles/1")
      expect(screen.getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/profile")
      expect(screen.getByRole("link", { name: "My Profile" })).toHaveAttribute("href", "/app-shell/profiles/1")
      expect(screen.getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
      expect(screen.getByRole("link", { name: "Admin" })).toHaveAttribute("title", "Curia — The Roman Senate house")
      expect(screen.getByRole("button", { name: "Sign out" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Switch to dark mode" }))
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
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats",
        expect.objectContaining({ method: "POST", body: undefined })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("hides v2 sidebar navigation behind Setup before onboarding chat starts", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      ...incompleteOnboardingBootstrap(),
      current_user: {
        ...bootstrapPayload().current_user,
        layout_version: "v2"
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
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
    script.textContent = JSON.stringify(bootstrapPayload({
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
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
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
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(within(primaryNav).getByRole("link", { name: "Spending" })).toHaveAttribute("href", "/app-shell/insights/spending")
      expect(within(primaryNav).getByRole("link", { name: "Repositories" })).toHaveAttribute("href", "/app-shell/repositories")
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).toHaveAttribute("href", "/app-shell/scheduled_tasks")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("submits the v2 sidebar global search field to the search route", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/filters/fk_options")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/search?q=forum") {
        return Promise.resolve(new Response(JSON.stringify([]), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/search"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.change(await screen.findByLabelText("Search Syrus"), { target: { value: "forum" } })
      fireEvent.submit(screen.getByRole("search"))

      expect(await screen.findByRole("main", { name: "Search" })).toBeInTheDocument()
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/search?q=forum",
          expect.objectContaining({ credentials: "same-origin" })
        )
      })
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders grouped chat matches in v2 unified search results", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/search?q=needle") {
        return Promise.resolve(new Response(JSON.stringify(unifiedSearchPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/search?q=needle"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("link", { name: "Forum planning" })).toHaveAttribute("href", "/app-shell/chats/77?message_id=11")
      expect(screen.getByText((_content, element) => element?.textContent === "Best needle")).toBeInTheDocument()
      expect(screen.getByText("3 more matches in this chat")).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Show 2 more matches" }))

      expect(await screen.findByText((_content, element) => element?.textContent === "Second needle")).toBeInTheDocument()
      expect(screen.getByText((_content, element) => element?.textContent === "Third needle")).toBeInTheDocument()
      expect(screen.getByText("Only the top 2 additional matches are shown.")).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders the v2 chat search empty state and all filter fields", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.includes("field=repository_id")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [{ value: "3", label: "acme/widgets" }] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.includes("field=epic_id")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [{ value: "5", label: "EPIC-5 Search" }] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.includes("field=job_id")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [{ value: "8", label: "JOB-8 Recent job" }] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/search"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Search your chats or filter by repository, epic, or job.")).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Search text" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Repository select" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Epic select" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Job select" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders v2 chat search result cards, expands matches, and follows message links", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/filters/fk_options")) {
        return Promise.resolve(new Response(JSON.stringify({ options: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/search?q=needle") {
        return Promise.resolve(new Response(JSON.stringify(chatSearchPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/search/messages?q=needle&chat_session_id=77") {
        return Promise.resolve(new Response(JSON.stringify({
          matches: [
            chatSearchMatch({ message_id: 11, role: "assistant", snippet: "First <b>needle</b>", created_at: "2026-06-20T10:00:00Z" }),
            chatSearchMatch({ message_id: 12, role: "user", snippet: "Second <b>needle</b>", created_at: "2026-06-20T10:01:00Z" }),
            chatSearchMatch({ message_id: 13, role: "assistant", snippet: "Third <b>needle</b>", created_at: "2026-06-20T10:02:00Z" }),
            chatSearchMatch({ message_id: 14, role: "tool_result", snippet: "Fourth <b>needle</b>", created_at: "2026-06-20T10:03:00Z" })
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/77?message_id=12") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/search?q=needle"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("link", { name: "Forum planning" })).toHaveAttribute("href", "/chats/77")
      expect(screen.getByText((_content, element) => element?.textContent === "Best needle ignored")).toBeInTheDocument()
      expect(screen.getByText(/ago$/)).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Show 1 more match" }))
      const secondMatch = await screen.findByText((_content, element) => element?.textContent === "Second needle")
      fireEvent.click(secondMatch.closest("button") as HTMLButtonElement)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/chats/77?message_id=12",
          expect.objectContaining({ credentials: "same-origin" })
        )
      })
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
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
      expect(resizeHandle).toHaveAttribute("aria-valuemin", "208")
      expect(resizeHandle).toHaveAttribute("aria-valuemax", "420")
      expect(resizeHandle).toHaveAttribute("aria-valuenow", "300")

      fireEvent.mouseDown(resizeHandle, { clientX: 300 })
      await waitFor(() => expect(document.body).toHaveClass("cursor-col-resize"))
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
      await waitFor(() => expect(document.body).not.toHaveClass("cursor-col-resize"))

      fireEvent.keyDown(resizeHandle, { key: "Home" })
      expect(sidebar).toHaveStyle({ width: "208px" })
      expect(window.localStorage.getItem("syrus.sidebar.width")).toBe("208")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("uses an anchored v2 mobile brand trigger that floats after scroll", async () => {
    const restoreMediaQuery = mockMediaQuery(true)
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
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
      const mobileTopBar = anchoredTrigger.closest("div")
      if (!(mobileTopBar instanceof HTMLElement)) throw new Error("Expected mobile top bar to render")
      expect(mobileTopBar).toHaveClass("w-full")
      expect(anchoredTrigger).not.toHaveClass("fixed")
      expect(within(anchoredTrigger).getByText("Syrus")).toBeInTheDocument()
      expect(anchoredTrigger.querySelector('img[alt=""][src^="/icon.png?v="]')).not.toBeNull()
      expect(within(mobileTopBar).getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "/app-shell/notifications")
      expect(screen.queryByRole("button", { name: "Open settings" })).not.toBeInTheDocument()

      const scrollPane = document.querySelector("main.overflow-auto")
      expect(scrollPane).toBeInstanceOf(HTMLElement)
      Object.defineProperty(scrollPane, "scrollTop", { configurable: true, value: 24 })
      fireEvent.scroll(scrollPane as HTMLElement)

      const sidebarTriggers = screen.getAllByRole("button", { name: "Open sidebar" })
      const floatingTrigger = sidebarTriggers.find((button) => button.classList.contains("fixed"))
      expect(floatingTrigger).toBeDefined()
      expect(floatingTrigger).toHaveClass("left-3", "top-3")
      expect(floatingTrigger?.querySelector('img[alt=""][src^="/icon.png?v="]')).not.toBeNull()
      const floatingNotification = screen.getAllByRole("link", { name: "Notifications" }).find((link) => link.parentElement?.classList.contains("fixed"))
      expect(floatingNotification).toHaveAttribute("href", "/app-shell/notifications")
      expect(floatingNotification?.parentElement).toHaveClass("right-3", "top-3")

      fireEvent.click(floatingTrigger as HTMLButtonElement)
      const drawerPrimaryNav = screen.getAllByRole("navigation", { name: "Primary" }).at(-1) as HTMLElement | undefined
      if (!(drawerPrimaryNav instanceof HTMLElement)) throw new Error("Expected drawer primary navigation to render")
      expect(within(drawerPrimaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(screen.getAllByRole("button", { name: "Close sidebar" }).length).toBeGreaterThan(0)
      expect(screen.getAllByRole("link", { name: "Notifications" }).length).toBeGreaterThan(0)
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard?view=list&smart_folder_id=3&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
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
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/admin/console") {
        return Promise.resolve(new Response(
          JSON.stringify({
            settings: {
              polling_paused: false,
              runs_paused: false,
              signups_open: true,
              max_job_failures: 3,
              grade_max_iterations: 2,
              merge_train_enabled: false
            },
            users: [],
            recent_admin_actions: []
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        ))
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
      expect(adminNav).toHaveClass("flex", "overflow-x-auto")
      expect(within(adminNav).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(adminNav).getByRole("link", { name: "Queue" })).toHaveAttribute("href", "/app-shell/admin/queue")
      expect(within(adminNav).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
      expect(within(adminNav).getByRole("link", { name: "Invitations" })).toHaveAttribute("href", "/app-shell/invitations")
      expect(within(adminNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings/edit")
      expect(within(adminNav).getByRole("link", { name: "Overview" })).not.toHaveClass("bg-blue-50")
      expect(within(adminNav).getByRole("link", { name: "Console" })).toHaveClass("bg-blue-50", "text-blue-700")
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
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
      expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/app-shell/profile")
      expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveClass("bg-blue-50", "text-blue-700")
      expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
      expect(within(settingsNav).getByRole("link", { name: "Agent Settings" })).toHaveAttribute("href", "/app-shell/settings/agent")
      expect(within(settingsNav).getByRole("link", { name: "Preferences" })).toHaveAttribute("href", "/app-shell/settings/preferences")
      expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveAttribute("href", "/app-shell/settings/hidden_chats")
      expect(within(settingsNav).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/documents")
      expect(within(settingsNav).getByRole("link", { name: "Templates" })).toHaveAttribute("href", "/app-shell/cron_templates")
      expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveAttribute("href", "/app-shell/tags")
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
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
        return Promise.resolve(new Response(JSON.stringify({ chats: hiddenChats, total: hiddenChats.length, page: 1, per_page: 20, total_pages: hiddenChats.length > 0 ? 1 : 0 }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/42/unhide" && init?.method === "PATCH") {
        hiddenChats = []
        return Promise.resolve(new Response(JSON.stringify({ message: "Chat restored.", chat: sidebarChat({ id: 42, title: "Archived planning", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-18T12:00:00Z" }) }), { status: 200, headers: { "Content-Type": "application/json" } }))
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
      expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveClass("bg-blue-50", "text-blue-700")
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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const recentChats = [
      sidebarChat({ id: 1, title: "General latest", repository: null, last_message_at: "2026-06-20T12:00:00Z" }),
      sidebarChat({ id: 2, title: null, title_pending: true, repository: null, last_message_at: "2026-06-19T12:00:00Z", unread: true }),
      sidebarChat({ id: 10, title: "Widgets active", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-18T12:00:00Z", turn_in_flight: true }),
      sidebarChat({ id: 11, title: "Widgets two", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-17T12:00:00Z" }),
      sidebarChat({ id: 12, title: "Widgets three", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-16T12:00:00Z" }),
      sidebarChat({ id: 13, title: "Widgets four", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-15T12:00:00Z" }),
      sidebarChat({ id: 14, title: "Widgets five", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-14T12:00:00Z" }),
      sidebarChat({ id: 15, title: "Widgets hidden", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-13T12:00:00Z" }),
      sidebarChat({ id: 20, title: "Roads latest", repository: { id: 4, slug: "acme/roads", repository_path: "/repositories/4" }, last_message_at: "2026-06-21T12:00:00Z" })
    ]
    const recentGroups = [
      { key: "general", label: "General", repository_id: null, chats: recentChats.slice(0, 2), has_more: false },
      { key: "repository-4", label: "acme/roads", repository_id: 4, chats: [recentChats[8]], has_more: false },
      { key: "repository-3", label: "acme/widgets", repository_id: 3, chats: recentChats.slice(2, 7), has_more: true }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: recentGroups, repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/more?repository_id=3&before_id=14") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [recentChats[7]], has_more: false }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/10") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
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
      expect(screen.getByRole("button", { name: "New Chat" }).parentElement).toHaveClass("sticky", "top-0")
      const headers = within(recentNav).getAllByRole("heading").map((heading) => heading.textContent)
      expect(headers).toEqual(["acme/roads", "General", "acme/widgets"])
      expect(within(recentNav).getByRole("link", { name: "New chat" })).toHaveAttribute("href", "/app-shell/chats/2")
      expect(within(recentNav).getByRole("link", { name: "New chat" })).toHaveClass("text-gray-700")
      expect(within(recentNav).getByText("New chat")).toHaveClass("font-semibold")
      expect(within(recentNav).getByRole("link", { name: "Widgets active" })).toHaveClass("bg-blue-50", "text-blue-700")
      expect(within(within(recentNav).getByRole("link", { name: "Widgets active" })).getByTitle("Chat turn active")).toBeInTheDocument()
      fireEvent.click(within(recentNav).getByRole("button", { name: "Chat actions for Widgets active" }))
      expect(within(recentNav).getByText("Bookmarks")).toHaveClass("font-semibold")
      expect(within(recentNav).getByRole("link", { name: "Aqueducts" })).toHaveAttribute("href", "#message-9")
      fireEvent.click(within(recentNav).getByRole("link", { name: "Aqueducts" }))
      expect(within(recentNav).queryByRole("link", { name: "Aqueducts" })).not.toBeInTheDocument()
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
  })

  it("hides a chat from the v2 recent chats sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    let recentChats = [
      sidebarChat({ id: 10, title: "Widgets active", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-18T12:00:00Z" }),
      sidebarChat({ id: 11, title: "Widgets two", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-17T12:00:00Z" })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
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
        return Promise.resolve(new Response(JSON.stringify({ message: "Chat hidden.", chat: sidebarChat({ id: 11, title: "Widgets two", repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" }, last_message_at: "2026-06-17T12:00:00Z" }) }), { status: 200, headers: { "Content-Type": "application/json" } }))
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

      fireEvent.click(within(recentNav).getByRole("button", { name: "Chat actions for Widgets two" }))
      expect(await within(recentNav).findByText("No bookmarks yet")).toBeInTheDocument()
      fireEvent.click(within(recentNav).getByRole("button", { name: "Hide Chat" }))

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
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
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
        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/10") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ id: 10 })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/10/mark_read") {
        recentChats = recentChats.map((chat) => chat.id === 10 ? { ...chat, unread: false } : chat)
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

      await screen.findByText("Widgets active")
      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/10/mark_read", expect.objectContaining({ method: "PATCH" })))
      await waitFor(() => expect(screen.getByText("Widgets active")).toHaveClass("font-medium"))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders the team directory route", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          team_user_count: 2,
          profiles: [
            {
              id: 7,
              display_name: "Ada Lovelace",
              first_name: "Ada",
              last_name: "Lovelace",
              github_handle: "ada",
              role_label: "Operator",
              avatar_url: null,
              bio_excerpt: "Keeps the machines honest.",
              counts: { repositories: 1, epics: 2, jobs: 3, open_jobs: 1 },
              profile_path: "/profiles/7"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/profiles"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Team directory" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Ada Lovelace" })).toHaveAttribute("href", "/app-shell/profiles/7")
    expect(screen.getByText("Operator")).toBeInTheDocument()
    expect(screen.getByText("@ada")).toBeInTheDocument()
    expect(screen.getByText("Keeps the machines honest.")).toBeInTheDocument()
  })

  it("sends first-run users from the app root to onboarding", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
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
    }))
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
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      script.remove()
    }
  })

  it("shows the land-Epic step as the next action once the chat has started", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
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
    }))
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
        return new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/5", chat: chatPayload().chat }), { status: 201, headers: { "Content-Type": "application/json" } })
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

  it("renders the chat route", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      script.remove()
    }
  })

  it("submits bug reports from the shared app chrome", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Bug report queued.", job_id: 44 }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByRole("button", { name: "Report a bug" }))
      const dialog = await screen.findByRole("dialog", { name: "Report a bug" })
      expect(dialog).toBeInTheDocument()
      expect(dialog.parentElement).toHaveAttribute("data-html2canvas-ignore")
      expect(screen.getByLabelText("Title")).toHaveValue("Dashboard bug")
      expect(html2canvasMock).toHaveBeenCalledTimes(1)
      expect(screen.getByRole("radio", { name: "Viewport" })).toBeChecked()
      expect(screen.getByRole("radio", { name: "Full page" })).toBeInTheDocument()
      expect(screen.getByRole("radio", { name: "No screenshot" })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      await waitFor(() => expect(html2canvasMock).toHaveBeenCalledTimes(2))
      expect(html2canvasMock).toHaveBeenLastCalledWith(
        document.body,
        expect.objectContaining({
          x: 0,
          y: 0,
          scrollX: 0,
          scrollY: 0,
          scale: 1
        })
      )
      fireEvent.change(screen.getByLabelText("Description"), { target: { value: "The aqueduct counter is off by one." } })
      fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The aqueduct counter is off by one.")
      expect((form.get("screenshot") as File).name).toBe("bug-report-full-page.png")
      expect(await screen.findByRole("status")).toHaveTextContent("Bug report queued.")
      expect(screen.queryByRole("dialog", { name: "Report a bug" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("does not capture full-page bug report screenshots until selected", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      fireEvent.click(await screen.findByRole("button", { name: "Report a bug" }))
      expect(await screen.findByRole("dialog", { name: "Report a bug" })).toBeInTheDocument()

      expect(html2canvasMock).toHaveBeenCalledTimes(1)
      expect(html2canvasMock).toHaveBeenLastCalledWith(
        document.body,
        expect.objectContaining({
          width: window.innerWidth,
          height: window.innerHeight,
          windowWidth: window.innerWidth,
          windowHeight: window.innerHeight
        })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("scales oversized full-page bug report screenshots instead of rejecting them", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      fireEvent.click(await screen.findByRole("button", { name: "Report a bug" }))
      expect(await screen.findByRole("dialog", { name: "Report a bug" })).toBeInTheDocument()

      Object.defineProperty(document.body, "scrollWidth", { configurable: true, value: 4000 })
      Object.defineProperty(document.body, "scrollHeight", { configurable: true, value: 4000 })
      Object.defineProperty(document.documentElement, "scrollWidth", { configurable: true, value: 4000 })
      Object.defineProperty(document.documentElement, "scrollHeight", { configurable: true, value: 4000 })

      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      await waitFor(() => expect(html2canvasMock).toHaveBeenCalledTimes(2))
      const fullPageCall = html2canvasMock.mock.calls[1] as unknown as [HTMLElement, { scale?: number; scrollX?: number; scrollY?: number; width?: number; height?: number }]
      const options = fullPageCall[1]

      expect(options).toEqual(expect.objectContaining({
        width: 4000,
        height: 4000,
        scrollX: 0,
        scrollY: 0
      }))
      expect(options.scale).toBeCloseTo(Math.sqrt(8_000_000 / 16_000_000))
      expect(screen.getByRole("radio", { name: "Full page" })).toBeChecked()
      expect(screen.queryByText("Full-page screenshot capture failed. The viewport screenshot is still available.")).not.toBeInTheDocument()
    } finally {
      delete (document.body as { scrollWidth?: number }).scrollWidth
      delete (document.body as { scrollHeight?: number }).scrollHeight
      delete (document.documentElement as { scrollWidth?: number }).scrollWidth
      delete (document.documentElement as { scrollHeight?: number }).scrollHeight
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("submits bug reports without a screenshot when that option is selected", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Bug report queued.", job_id: 45 }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByRole("button", { name: "Report a bug" }))
      await screen.findByRole("dialog", { name: "Report a bug" })
      fireEvent.click(screen.getByRole("radio", { name: "No screenshot" }))
      fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("screenshot")).toBeNull()
    } finally {
      script.remove()
    }
  })

  it("accepts bug reports with the command-enter shortcut", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Bug report queued.", job_id: 46 }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByRole("button", { name: "Report a bug" }))
      await screen.findByRole("dialog", { name: "Report a bug" })
      fireEvent.change(screen.getByLabelText("Description"), { target: { value: "The toga modal has fallen." } })
      fireEvent.keyDown(screen.getByLabelText("Description"), { key: "Enter", metaKey: true })

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The toga modal has fallen.")
    } finally {
      script.remove()
    }
  })

  it("renders the admin overview route from the app admin API", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(
        JSON.stringify({
          active_runs: { total: 2, by_trigger: { initial: 1, retry: 1 } },
          queued_runs: { total: 1 },
          recent_failures_24h: { total: 0, by_trigger: {} },
          github_rate_limits: [],
          github_api_blocked_users: [],
          provider_circuits: [],
          agent_session_capture_rate: { total: 3, captured: 3, rate: 1.0 },
          data_root_disk_usage: { path: "/syrus-home/.syrus", filesystem: "/dev/pvc", total_bytes: 100, used_bytes: 90, available_bytes: 10, used_percent: 90, mounted_on: "/syrus-home", observed_at: "2026-06-05T12:00:00Z", level: "warning" },
          workers: { total: 1, stale: 0 },
          recurring: { overdue: [] },
          stuck: [
            {
              kind: "stale_heartbeat",
              severity: "warn",
              detail: "Run #4 silent for 10m",
              age_label: "10m",
              run_id: 4,
              workflow_id: 2,
              workflow_slug: "WF-2",
              workflow_path: "/jobs/1?tab=workflows#workflow-2",
              workflow_trigger_kind: "initial",
              step_kind: "implement",
              job_id: 1,
              job_path: "/jobs/1"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      ))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Active runs")).toBeInTheDocument()
      expect(screen.getByRole("main", { name: "Admin overview" })).toBeInTheDocument()
      const adminNav = screen.getByRole("navigation", { name: "Admin" })
      expect(within(adminNav).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(adminNav).getByRole("link", { name: "Stuck" })).toHaveAttribute("href", "/app-shell/admin/stuck")
      expect(within(adminNav).getByRole("link", { name: "Users" })).toHaveAttribute("href", "/app-shell/admin/users")
      expect(within(adminNav).getByRole("link", { name: "Queue" })).toHaveAttribute("href", "/app-shell/admin/queue")
      expect(within(adminNav).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
      expect(within(adminNav).getByRole("link", { name: "Console" })).toHaveAttribute("href", "/app-shell/admin/console")
      expect(within(adminNav).getByRole("link", { name: "GitHub App" })).toHaveAttribute("href", "/app-shell/admin/github_app/register")
      expect(within(adminNav).getByRole("link", { name: "Installations" })).toHaveAttribute("href", "/app-shell/admin/installations")
      expect(within(adminNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings/edit")
      expect(within(adminNav).getByRole("link", { name: "Invitations" })).toHaveAttribute("href", "/app-shell/invitations")
      expect(screen.getByRole("link", { name: /Active runs/ })).toHaveAttribute("href", "/app-shell/admin/queue/active")
      expect(screen.getByRole("link", { name: /Stuck things/ })).toHaveAttribute("href", "/app-shell/admin/stuck")
      expect(screen.getByRole("link", { name: "Run #4 silent for 10m" })).toHaveAttribute("href", "/app-shell/jobs/1?tab=workflows#workflow-2")
      expect(screen.getByText("Data root disk")).toBeInTheDocument()
      expect(screen.getByText("90%")).toBeInTheDocument()
      expect(screen.getByText("2")).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("renders the migrated /admin route from the same admin overview component", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          active_runs: { total: 0, by_trigger: {} },
          queued_runs: { total: 0 },
          recent_failures_24h: { total: 0, by_trigger: {} },
          github_rate_limits: [],
          github_api_blocked_users: [],
          provider_circuits: [],
          agent_session_capture_rate: { total: 0, captured: 0, rate: null },
          data_root_disk_usage: null,
          workers: { total: 1, stale: 0 },
          recurring: { overdue: [] },
          stuck: []
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/admin"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("GitHub rate limits")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Admin overview" })).toBeInTheDocument()
  })

  it("renders the spending insights route from the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          scope: { admin: true, user_id: 1, label: "All users" },
          filters: {
            start_date: "2026-06-01",
            end_date: "2026-06-05",
            default_window_days: 90,
            agent_provider: null,
            agent_providers: [
              { value: "claude", label: "Claude Code" },
              { value: "codex", label: "Codex" }
            ]
          },
          totals: {
            week_usd: 3.75,
            month_usd: 3.75,
            lifetime_usd: 4.5,
            workflow_lifetime_usd: 3.75,
            chat_lifetime_usd: 0.75,
            average_job_30d_usd: 1.875,
            average_merged_pr_30d_usd: 1.25
          },
          breakdowns: {
            epics: [{ id: 7, label: "Cost Senate", path: "/epics/7", jobs_count: 1, total_usd: 1.25, average_job_usd: 1.25, display_number: "EPIC-7" }],
            users: [{ id: 2, label: "operator@example.com", path: "/profiles/2", jobs_count: 2, total_usd: 3.75, average_job_usd: 1.875, last_30_days_usd: 3.75 }],
            repositories: [{ id: 3, label: "acme/syrus", path: "/repositories/3", jobs_count: 2, total_usd: 3.75, average_job_usd: 1.875 }],
            trigger_kinds: [{ trigger_kind: "initial", jobs_count: 2, runs_count: 2, total_usd: 3.75, average_usd: 1.875 }]
          },
          top_runs: [{
            id: 11,
            cost_usd: 2.5,
            trigger_kind: "initial",
            agent_provider: "codex",
            created_at: "2026-06-04T12:00:00Z",
            job: { id: 9, title: "Replace Meyer's-singleton statics with inline-variable constants across every remaining math header", path: "/jobs/9?tab=workflows#workflow-4" },
            repository: { id: 3, slug: "tkadauke/raytracer", path: "/repositories/3" },
            epic: { id: 7, display_number: "EPIC-7", title: "Cost Senate", path: "/epics/7" }
          }],
          trend: [
            { date: "2026-06-03", total_usd: 1.25 },
            { date: "2026-06-04", total_usd: 2.5 }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/insights/spending?start_date=2026-06-01&end_date=2026-06-05"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("This week")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Spending insights" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/insights/spending?start_date=2026-06-01&end_date=2026-06-05", expect.objectContaining({ credentials: "same-origin" }))
    expect(screen.getByRole("link", { name: "EPIC-7 / Cost Senate" })).toHaveAttribute("href", "/app-shell/epics/7")
    const topRunJobLink = screen.getByRole("link", { name: "Replace Meyer's-singleton statics with inline-variable constants across every remaining math header" })
    expect(topRunJobLink).toHaveAttribute("href", "/app-shell/jobs/9?tab=workflows#workflow-4")
    expect(topRunJobLink).toHaveClass("block", "truncate")
    const repositoryLink = screen.getByRole("link", { name: "tkadauke/raytracer" })
    expect(repositoryLink).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(repositoryLink).toHaveClass("block", "truncate")
    expect(screen.getByRole("img", { name: "Daily spend" })).toBeInTheDocument()
    fireEvent.change(screen.getByRole("combobox", { name: "Model" }), { target: { value: "codex" } })
    fireEvent.click(screen.getByRole("button", { name: "Apply" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/insights/spending?start_date=2026-06-01&end_date=2026-06-05&agent_provider=codex", expect.objectContaining({ credentials: "same-origin" }))
    })
  })

  it("persists the selected dashboard view when the view toggle is clicked", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(dashboardPayload({ subject: "job", view: path.includes("view=kanban") ? "kanban" : "list" })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("link", { name: "kanban" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ subject: "job", active_smart_folder_id: null, view: "kanban" })
        })
      )
    })
  })

  it("does not carry the current dashboard view when switching subjects in the v2 sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path.startsWith("/api/v1/app/dashboard")) {
        const subject = path.includes("subject=epic") ? "epic" : "job"
        const view = subject === "epic" ? "kanban" : "list"
        return Promise.resolve(
          new Response(JSON.stringify(dashboardPayload({ subject, view })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
            <App />
            <LocationProbe />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const dashboardSections = await screen.findByRole("navigation", { name: "Dashboard sections" })
      fireEvent.click(within(dashboardSections).getByRole("link", { name: "Jobs" }))

      await waitFor(() => {
        expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/dashboard/jobs")
      })
      expect(screen.getByTestId("location")).not.toHaveTextContent("view=")
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard?subject=job",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      script.remove()
    }
  })

  it("persists and clears the selected dashboard smart folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(dashboardPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByText("Folders and filters"))
      fireEvent.click(screen.getByRole("link", { name: "My work 1" }))
      fireEvent.click(screen.getByText("More"))
      fireEvent.click(screen.getByRole("link", { name: "All jobs" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({ subject: "job", smart_folder_id: 7 })
          })
        )
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({ subject: "job", smart_folder_id: null })
          })
        )
      })
    } finally {
      restoreMedia()
    }
  })

  it("renders the app-shell dashboard route from the app dashboard API", async () => {
    let sortColumn = "title"
    let sortDirection = "desc"
    let latestFilterTree: unknown = null
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        const body = JSON.parse(String(init.body)) as { sort_column: string; sort_direction: string }
        sortColumn = body.sort_column
        sortDirection = body.sort_direction

        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Dashboard preferences updated.",
              dashboard_preferences: {}
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (path === "/api/v1/app/dashboard/jobs/bulk" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Retry enqueued for 1 job.",
              action: "retry",
              affected_job_ids: [42],
              skipped_job_ids: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/dashboard/jobs?smart_folder_id=11",
              smart_folder: { id: 11, name: "Open work", position: 1, filter: { and: [{ field: "state", op: "is", value: "open" }] } }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (
        path === "/api/v1/app/dashboard?view=list&subject=job" ||
        path.startsWith("/api/v1/app/dashboard?view=list&q=") ||
        path === "/api/v1/app/dashboard?smart_folder_id=11&subject=job"
      ) {
        const q = new URL(path, "https://syrus.test").searchParams.get("q")
        if (q) latestFilterTree = decodeFilterQ(q)

        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                filter: latestFilterTree || { and: [] },
                page: 2,
                per_page: 10,
                total: 25,
                total_pages: 3,
                preferences: {
                  sort: { column: sortColumn, direction: sortDirection },
                  visible_columns: ["checkbox", "issue", "state", "repository", "owner", "latest", "workflows_count", "started"],
                  kanban_lanes: ["queued", "running", "succeeded"],
                  raw: {}
                },
                items: [
                  dashboardJobItem({
                    retry_state: {
                      classification: "git_failure",
                      classification_label: "Git failure",
                      retryable: true,
                      next_auto_retry_at: null,
                      retry_attempt_count: 1,
                      retry_budget_remaining: 2,
                      retry_budget: 3,
                      auto_retry_exhausted: false,
                      provider_circuit_open: false,
                      retry_delayed_until: null,
                      retry_delay_reason: null,
                      state_label: "Retryable failure"
                    }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Repair aqueduct")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Dashboard" })).toHaveClass("max-w-[96rem]")
    expect(screen.queryByText("25 jobs in this view")).not.toBeInTheDocument()
    const dashboardHeader = screen.getByRole("heading", { name: "Dashboard" }).closest("header")
    expect(dashboardHeader).not.toHaveClass("border-b")
    expect(dashboardHeader).toHaveClass("flex", "flex-wrap", "items-center", "gap-3")
    expect(screen.getByRole("navigation", { name: "Dashboard view" }).closest("header")).toBe(dashboardHeader)
    expect(screen.getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("target", "_blank")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("target", "_blank")
    expect(document.querySelectorAll("[data-status-pill='true']")).toHaveLength(4)
    for (const label of screen.getAllByText("Retryable failure")) {
      expect(label.closest("[data-status-pill='true']")).toHaveClass("rounded-full", "ring-1")
    }
    expect(screen.getAllByRole("link", { name: "acme/widgets" }).some((link) => link.getAttribute("href") === "/app-shell/repositories/3")).toBe(true)
    expect(screen.getAllByText("acme/widgets").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "Ada Lovelace" })).toHaveAttribute("href", "/app-shell/profiles/2")
    expect(screen.getByRole("link", { name: "kanban" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=kanban")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveAttribute("href", "/app-shell/epics/new")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveClass("bg-blue-600", "text-white")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveAttribute("href", "/app-shell/jobs/new")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveClass("bg-green-600", "text-white")
    expect(screen.queryByText("0 selected")).not.toBeInTheDocument()
    expect(screen.queryByText(/Sorted by/)).not.toBeInTheDocument()
    expect(within(screen.getByRole("button", { name: "Sort by Issue ascending" })).getByText("↓")).toBeInTheDocument()
    const stateCell = screen.getByRole("cell", { name: "open" })
    expect(stateCell).toBeInTheDocument()
    expect(stateCell).not.toHaveTextContent(/rebase|running/i)
    const latestWorkflowCell = screen.getByRole("cell", { name: "Latest workflow: rebase running" })
    expect(latestWorkflowCell).toBeInTheDocument()
    const latestWorkflowTrigger = within(latestWorkflowCell).getByLabelText("Latest workflow trigger: rebase")
    expect(latestWorkflowTrigger).toHaveClass("rounded-full", "ring-1", "bg-gray-100")
    expect(latestWorkflowCell).toHaveTextContent(/rebase.*running/i)
    expect(within(latestWorkflowCell).getByText("running").closest("[data-status-pill='true']")?.parentElement?.parentElement).toHaveClass("items-start")
    expect(screen.getByText("Showing 11-20 of 25")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=1")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=3")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/dashboard?view=list&subject=job",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal: expect.any(AbortSignal)
      })
    )

    fireEvent.click(screen.getByLabelText("Select Repair aqueduct"))
    fireEvent.click(screen.getByRole("button", { name: "Claim" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/jobs/bulk",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ job_ids: [42], bulk_action: "claim" })
        })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByPlaceholderText("Search filters...")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByPlaceholderText("Search filters...")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "state" } })
    fireEvent.click(screen.getByRole("button", { name: "State enum" }))
    expect(await screen.findByRole("dialog", { name: "State filter settings" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Apply filter" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Done" })).not.toBeInTheDocument()

    await waitFor(() => {
      expect(latestFilterTree).toEqual({ and: [ { field: "state", op: "is", value: "open" } ] })
    })
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "closed" } })
    await waitFor(() => {
      expect(latestFilterTree).toEqual({ and: [ { field: "state", op: "is", value: "closed" } ] })
    })
    expect(screen.getByRole("button", { name: "Wrap in NOT" })).toHaveTextContent("¬")
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringMatching(/^\/api\/v1\/app\/dashboard\?view=list&q=/),
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
    expect(await screen.findByRole("link", { name: "Clear filters" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")

    fireEvent.click(await screen.findByRole("button", { name: "+ OR alternative" }))
    expect(screen.queryByRole("dialog", { name: "State filter settings" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Search filters...")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "State enum" }))

    await waitFor(() => {
      expect(latestFilterTree).toEqual({
        and: [
          {
            or: [
              { field: "state", op: "is", value: "closed" },
              { field: "state", op: "is", value: "open" }
            ]
          }
        ]
      })
    })
    fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
    fireEvent.change(screen.getByPlaceholderText("Search filters..."), { target: { value: "parent" } })
    fireEvent.click(screen.getByRole("button", { name: "Has parent boolean" }))
    await waitFor(() => {
      expect(latestFilterTree).toEqual({
        and: [
          {
            or: [
              { field: "state", op: "is", value: "closed" },
              { field: "state", op: "is", value: "open" }
            ]
          },
          { field: "has_parent", op: "is_true", value: null }
        ]
      })
    })
    fireEvent.click(await screen.findByRole("button", { name: "Has parent is true" }))
    expect(await screen.findByRole("dialog", { name: "Has parent filter settings" })).toBeInTheDocument()
    expect(screen.queryByText("No value needed")).not.toBeInTheDocument()

    expect(screen.queryByLabelText("Sort column")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Direction")).not.toBeInTheDocument()
    await waitFor(() => {
      expect(screen.queryByText("Dashboard preferences updated.")).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Sort by Issue ascending" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            subject: "job",
            active_smart_folder_id: null,
            sort_column: "title",
            sort_direction: "asc"
          })
        })
      )
    })
    expect(within(await screen.findByRole("button", { name: "Sort by Issue descending" })).getByText("↑")).toBeInTheDocument()

    const columnsButton = screen.getByRole("button", { name: "Columns" })
    expect(columnsButton).toHaveClass("h-9", "w-9")
    expect(columnsButton).not.toHaveTextContent("Columns")
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("group", { name: "Visible columns" })).not.toBeInTheDocument()
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("group", { name: "Visible columns" })).not.toBeInTheDocument()
    fireEvent.click(columnsButton)
    expect(screen.getByRole("group", { name: "Visible columns" })).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("Workflows count"))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            subject: "job",
            visible_columns: ["state", "repository", "owner", "latest", "started"]
          })
        })
      )
    })

    fireEvent.click(screen.getByLabelText("Select Repair aqueduct"))
    expect(await screen.findByText("1 selected")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/jobs/bulk",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            job_ids: [42],
            bulk_action: "retry"
          })
        })
      )
    })
    expect(await screen.findByText("Retry enqueued for 1 job.")).toBeInTheDocument()
  }, 15000)

  it("renders dashboard timestamp columns as relative times with absolute tooltips", async () => {
    const restoreMedia = mockMediaQuery(true)
    const dateNowSpy = vi.spyOn(Date, "now").mockReturnValue(new Date("2026-05-30T12:01:00Z").getTime())
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard?view=list&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                preferences: {
                  ...dashboardPayload().preferences,
                  visible_columns: ["checkbox", "issue", "started", "created_at", "updated_at"]
                },
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const startedAt = "2026-05-30T10:01:00Z"
      const absoluteStartedAt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(startedAt))
      await screen.findByText("Repair aqueduct")
      const relativeStartedAt = document.querySelector(`time[datetime="${startedAt}"]`)

      expect(relativeStartedAt).toHaveTextContent("2 hours ago")
      expect(relativeStartedAt).toHaveAttribute("dateTime", startedAt)
      expect(relativeStartedAt).toHaveAttribute("title", absoluteStartedAt)
      expect(screen.queryByText(absoluteStartedAt)).not.toBeInTheDocument()
    } finally {
      dateNowSpy.mockRestore()
      restoreMedia()
    }
  })

  it("shows dashboard subjects in the sidebar", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard?view=list&subject=job") {
        return Promise.resolve(new Response(JSON.stringify(dashboardPayload({ subject: "job", view: "list" })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("navigation", { name: "Dashboard sections" })).toBeInTheDocument()
      expect(screen.queryByRole("navigation", { name: "Dashboard subjects" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("uses the indigo trigger badge for chat feedback workflows", async () => {
    const restoreMedia = mockMediaQuery(true)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            preferences: {
              sort: { column: "created_at", direction: "desc" },
              visible_columns: ["issue", "state", "latest"],
              kanban_lanes: ["queued", "running", "succeeded"],
              raw: {}
            },
            items: [
              dashboardJobItem({
                active_workflow_trigger_kind: "chat_feedback",
                latest_workflow_trigger_kind: "chat_feedback"
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const latestWorkflowCell = await screen.findByRole("cell", { name: "Latest workflow: chat_feedback running" })
      const latestWorkflowTrigger = within(latestWorkflowCell).getByLabelText("Latest workflow trigger: chat_feedback")
      expect(latestWorkflowTrigger).toHaveClass("bg-indigo-100", "text-indigo-700", "ring-indigo-200")
    } finally {
      restoreMedia()
    }
  })

  it("renders postponed auto-merge attempts from dashboard job state", async () => {
    const restoreMedia = mockMediaQuery(true)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            preferences: {
              sort: { column: "created_at", direction: "desc" },
              visible_columns: ["issue", "state", "latest"],
              kanban_lanes: ["queued", "running", "succeeded"],
              raw: {}
            },
            items: [
              dashboardJobItem({
                latest_workflow_trigger_kind: "auto_merge",
                latest_workflow_state: "postponed"
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const latestCell = await screen.findByRole("cell", { name: "Latest workflow: auto_merge postponed" })
      expect(within(latestCell).getByText("auto merge")).toBeInTheDocument()
      expect(within(latestCell).getByText("postponed")).toBeInTheDocument()
      expect(within(latestCell).queryByText("cancelled")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("leaves the latest workflow cell empty for dashboard jobs with no workflows", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard?view=list&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                preferences: {
                  sort: { column: "created_at", direction: "desc" },
                  visible_columns: ["checkbox", "issue", "state", "latest"],
                  kanban_lanes: ["queued", "running", "succeeded"],
                  raw: {}
                },
                items: [
                  dashboardJobItem({
                    id: 523,
                    title: "Blocked child",
                    state: "blocked_by_epic",
                    summary_state: "blocked_by_epic",
                    active_workflow_trigger_kind: null,
                    latest_workflow_id: null,
                    latest_workflow_trigger_kind: null,
                    latest_workflow_state: "queued",
                    workflows_count: 0
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Blocked child")).toBeInTheDocument()
    const row = screen.getByRole("row", { name: /Blocked child/i })
    const cells = within(row).getAllByRole("cell")
    expect(cells[3]).toBeEmptyDOMElement()
    expect(within(row).queryByText("Queued")).not.toBeInTheDocument()

    fetchSpy.mockRestore()
  })

  it("disambiguates GitHub issue numbers from Syrus Job ids on the dashboard", async () => {
    const clipboardWrite = mockClipboardWrite()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [
              dashboardJobItem({
                id: 594,
                kind: "direct",
                title: "Navigate to Epic",
                issue_number: null,
                issue_url: null,
                pr_number: null,
                pr_url: null,
                epic: {
                  id: 7,
                  number: 7,
                  display_number: "EPIC-7",
                  path: "/epics/7"
                }
              }),
              dashboardJobItem({ id: 595, kind: "issue", title: "GitHub issue", issue_number: 123, issue_url: "https://github.com/acme/widgets/issues/123", pr_number: null, pr_url: null })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Navigate to Epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/app-shell/epics/7")
    expect(screen.getByText("Navigate to Epic").closest("td")).toHaveTextContent("EPIC-7/JOB-594")
    const copySlugButton = screen.getByRole("button", { name: "Copy JOB-594 to clipboard" })
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-594"))
    expect(screen.getByRole("link", { name: "#123" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/123")
    expect(screen.queryByText("#594")).not.toBeInTheDocument()
  })

  it("renders dashboard job metadata with middot separators and copyable direct job slugs", async () => {
    const clipboardWrite = mockClipboardWrite()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [
              dashboardJobItem({
                id: 602,
                kind: "direct",
                title: "Direct chat repair",
                issue_number: null,
                issue_url: null,
                pr_number: 44,
                pr_url: "https://github.com/acme/widgets/pull/44",
                tags: [],
                source_chat: {
                  chat_id: 9,
                  chat_title: "Review",
                  proposal_id: 6,
                  proposal_kind: "job",
                  message_id: 3,
                  path: "/chats/9",
                  display_name: "Chat",
                  profile_path: "/profiles/2"
                }
              }),
              dashboardJobItem({
                id: 603,
                kind: "direct",
                title: "Direct standalone",
                issue_number: null,
                issue_url: null,
                pr_number: null,
                pr_url: null,
                tags: [],
                source_chat: null
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const chatJobCell = (await screen.findByRole("link", { name: "Direct chat repair" })).closest("td")
    expect(chatJobCell).toHaveTextContent("JOB-602·PR #44·Chat")
    expect(within(chatJobCell!).getByRole("link", { name: "PR #44" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/44")
    expect(within(chatJobCell!).getByRole("link", { name: "Chat" })).toHaveAttribute("href", "/app-shell/chats/9")

    const copySlugButton = within(chatJobCell!).getByRole("button", { name: "Copy JOB-602 to clipboard" })
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-602"))

    const standaloneCell = screen.getByRole("link", { name: "Direct standalone" }).closest("td")
    expect(standaloneCell).toHaveTextContent("JOB-603")
    expect(within(standaloneCell!).queryByText("·")).not.toBeInTheDocument()
  })

  it("surfaces readiness failures on the dashboard", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      setup_status: {
        ...setupStatus(),
        readiness: {
          status: "error",
          checks: [
            {
              key: "worker_queue",
              label: "Worker/queue",
              status: "error",
              message: "No Solid Queue worker processes are registered.",
              remediation: "Start the worker process with bin/jobs and confirm it can connect to the queue database.",
              optional: false
            },
            {
              key: "github",
              label: "GitHub",
              status: "ok",
              message: "GitHub accepted the configured personal access token.",
              remediation: null,
              optional: false
            }
          ]
        }
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(dashboardPayload({ subject: "job", view: "list", items: [dashboardJobItem()] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("region", { name: "System readiness" })).toBeInTheDocument()
    expect(screen.getByText("No Solid Queue worker processes are registered.")).toBeInTheDocument()
    expect(screen.getByText("Start the worker process with bin/jobs and confirm it can connect to the queue database.")).toBeInTheDocument()
    expect(screen.queryByText("GitHub accepted the configured personal access token.")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/dashboard?view=list&subject=job",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders useful owner badges on the jobs dashboard", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard?view=list&ownership_scope=team&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                ownership: { scope: "team", owner_id: 1, team_user_count: 2, badges_visible: true },
                preferences: {
                  sort: { column: "created_at", direction: "desc" },
                  visible_columns: ["checkbox", "issue", "state", "repository", "latest", "workflows_count", "started"],
                  kanban_lanes: ["queued", "running", "succeeded"],
                  ownership_scope: "team",
                  owner_user_id: 1,
                  owner_id: 1,
                  raw: {}
                },
                items: [
                  dashboardJobItem({ title: "Mine", owner_badge: null }),
                  dashboardJobItem({
                    id: 43,
                    title: "Theirs",
                    owner_user: { id: 2, name: "Teammate", email_address: "teammate@example.com" },
                    owner_badge: { label: "Teammate", kind: "other_user" }
                  })
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&ownership_scope=team"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Teammate")).toBeInTheDocument()
    expect(screen.queryByText("Operator")).not.toBeInTheDocument()
    // Owner filter for jobs moved to the FilterBar; no standalone ownership chip rendered
    expect(screen.queryByRole("button", { name: /Owner is/i })).toBeNull()
  })

  it("keeps dashboard folders and filters collapsed on mobile", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [dashboardJobItem()]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Repair aqueduct")).toBeInTheDocument()
      const controls = screen.getByRole("group", { name: "Dashboard controls" })
      expect(controls).toHaveClass("justify-between")
      expect(within(controls).getByRole("navigation", { name: "Dashboard subjects" })).toBeInTheDocument()
      expect(within(controls).getByRole("navigation", { name: "Dashboard subjects" }).parentElement).toHaveClass("flex-1", "overflow-x-auto")
      expect(within(controls).getByRole("navigation", { name: "Dashboard view" })).toBeInTheDocument()
      expect(within(controls).queryByRole("button", { name: "Columns" })).not.toBeInTheDocument()

      const disclosure = screen.getByText("Folders and filters").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "My work 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=7")
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Job dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [
              dashboardJobItem({
                summary_state: "implemented",
                total_cost_usd: 0.1234
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const row = await screen.findByRole("article", { name: "Repair aqueduct" })
      expect(within(row).getByLabelText("Select Repair aqueduct")).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
      expect(within(row).getByText("implemented")).toBeInTheDocument()
      expect(within(row).getByText("$0.12")).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
      expect(within(row).getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
      expect(within(row).getByText("Not approved")).toBeInTheDocument()
      expect(within(row).getByText("1 workflow")).toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("omits mobile Job dashboard cost before any billed run", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            items: [dashboardJobItem({ total_cost_usd: null })]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const row = await screen.findByRole("article", { name: "Repair aqueduct" })
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).queryByText("$0.00")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Epic dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "epic",
            view: "list",
            preferences: {
              sort: { column: "updated_at", direction: "desc" },
              visible_columns: ["epic", "state", "repository", "updated"],
              kanban_lanes: ["backlog", "ready", "in_progress", "done"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "updated_at"]
            },
            items: [
              dashboardEpicItem({
                description: "Epic: Extend filter framework to Epics Make Syrus's chip-bar filter framework work for Epics."
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const row = await screen.findByRole("article", { name: "EPIC-7 Raise the forum" })
      expect(row).toHaveClass("grid-cols-[auto_minmax(0,1fr)]")
      expect(within(row).getByRole("checkbox", { name: "Select Raise the forum" })).toBeInTheDocument()
      expect(within(row).getByRole("link", { name: "EPIC-7 Raise the forum" })).toHaveAttribute("href", "/app-shell/epics/7")
      expect(within(row).getByText("ready")).toBeInTheDocument()
      expect(within(row).getByText("EPIC-7")).toBeInTheDocument()
      expect(within(row).getByText("Raise the forum")).toBeInTheDocument()
      expect(within(row).getByText(/chip-bar filter framework/)).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).queryByText("View")).not.toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders mobile Workflow dashboard rows as consolidated cards", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "workflow",
            view: "list",
            preferences: {
              sort: { column: "started_at", direction: "desc" },
              visible_columns: ["workflow", "job", "trigger", "state", "started", "finished", "agent"],
              kanban_lanes: ["queued", "running", "done"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              columns: {
                required: [
                  { key: "workflow", title: "Workflow" },
                  { key: "job", title: "Job" }
                ],
                optional: [
                  { key: "trigger", title: "Trigger" },
                  { key: "state", title: "State" },
                  { key: "started", title: "Started" },
                  { key: "finished", title: "Finished" },
                  { key: "agent", title: "Agent" }
                ]
              },
              sort_columns: ["title", "state", "started_at", "finished_at"]
            },
            items: [dashboardWorkflowItem()]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/workflows?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const row = await screen.findByRole("link", { name: "WF-9 Repair aqueduct" })
      expect(row).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-9")
      expect(row).toHaveClass("grid-cols-[7.25rem_minmax(0,1fr)]")
      expect(within(row).getByText("running")).toBeInTheDocument()
      expectRunningPill(within(row).getByText("running"))
      expect(within(row).getByText("WF-9")).toBeInTheDocument()
      expect(within(row).getByText("Repair aqueduct")).toBeInTheDocument()
      expect(within(row).getByText("acme/widgets")).toBeInTheDocument()
      expect(within(row).getByText("manual")).toBeInTheDocument()
      expect(within(row).getByText("codex")).toBeInTheDocument()
      expect(within(row).getByText(/Started/)).toBeInTheDocument()
      expect(within(row).getByText(/Finished/)).toBeInTheDocument()
      expect(within(row).queryByText("View")).not.toBeInTheDocument()
      expect(screen.queryByRole("table")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders desktop Workflow dashboard slugs as links", async () => {
    const restoreMedia = mockMediaQuery(true)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "workflow",
            view: "list",
            preferences: {
              sort: { column: "started_at", direction: "desc" },
              visible_columns: ["workflow", "job", "state", "started"],
              kanban_lanes: ["queued", "running", "done"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              columns: {
                required: [
                  { key: "workflow", title: "Workflow" },
                  { key: "job", title: "Job" }
                ],
                optional: [
                  { key: "trigger", title: "Trigger" },
                  { key: "state", title: "State" },
                  { key: "started", title: "Started" },
                  { key: "finished", title: "Finished" },
                  { key: "agent", title: "Agent" }
                ]
              },
              sort_columns: ["title", "state", "started_at", "finished_at"]
            },
            items: [dashboardWorkflowItem()]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/workflows?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("link", { name: "WF-9" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-9")
    } finally {
      restoreMedia()
    }
  })

  it("toggles landing queue pause from the React dashboard", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard/landing_pause" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Landing paused.",
              landing_paused: true
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "job",
              view: "list",
              active_smart_folder_id: 7,
              smart_folders: [
                {
                  id: 7,
                  name: "Landing queue",
                  kind: "builtin",
                  subject_type: "job",
                  visibility: "when_present",
                  count: 0,
                  active: true,
                  path: "/dashboard/jobs?smart_folder_id=7"
                }
              ],
              landing_queue: {
                visible: true,
                paused: false,
                toggle_path: "/api/v1/app/dashboard/landing_pause"
              },
              controls: {
                ...dashboardPayload().controls,
                columns: {
                  required: [
                    { key: "checkbox", title: "Checkbox" },
                    { key: "landing_queue_position", title: "Queue" },
                    { key: "issue", title: "Issue" }
                  ],
                  optional: dashboardPayload().controls.columns.optional
                }
              },
              items: [dashboardJobItem({ landing_queue_position: 3 })]
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click(await screen.findByRole("button", { name: "Pause landing" }))
      expect(screen.getByRole("columnheader", { name: "Queue" })).toBeInTheDocument()
      expect(screen.getByRole("cell", { name: "#3" })).toBeInTheDocument()

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/landing_pause",
          expect.objectContaining({
            method: "POST",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({})
          })
        )
      })
      expect(await screen.findByText("Landing paused.")).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("renders expandable landing queue blocker rows in dependency order", async () => {
    const restoreMedia = mockMediaQuery(true)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            active_smart_folder_id: 7,
            preferences: {
              ...dashboardPayload().preferences,
              sort: { column: "landing_queue_position", direction: "asc" }
            },
            controls: {
              ...dashboardPayload().controls,
              columns: {
                required: [
                  { key: "checkbox", title: "Checkbox" },
                  { key: "landing_queue_position", title: "Queue" },
                  { key: "issue", title: "Issue" },
                  { key: "state", title: "State" }
                ],
                optional: dashboardPayload().controls.columns.optional
              }
            },
            landing_queue: {
              visible: true,
              paused: false,
              toggle_path: "/api/v1/app/dashboard/landing_pause",
              entries: [
                {
                  key: "epic:10",
                  position: 1,
                  job_ids: [1],
                  blocker_jobs: [
                    { id: 2, title: "Prepare data layer", job_path: "/jobs/2", state: "open", pr_number: 22, pr_path: "https://github.com/acme/widgets/pull/22", epic_id: 20, epic_title: "Data Layer" },
                    { id: 3, title: "Document rollout", job_path: "/jobs/3", state: "open", pr_number: null, pr_path: null, epic_id: null, epic_title: null }
                  ],
                  dependency_edges: [
                    { from_job_id: 2, to_job_id: 1 },
                    { from_job_id: 1, to_job_id: 3 }
                  ]
                }
              ]
            },
            items: [
              dashboardJobItem({
                id: 1,
                title: "Land API surface",
                landing_queue_position: 1,
                landing_queue_entry_key: "epic:10",
                epic: { id: 10, number: 10, display_number: "EPIC-10", path: "/epics/10" },
                approved_at: "2026-06-01T10:00:00Z"
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const expander = await screen.findByRole("button", { name: /2 blockers/ })
      expect(expander).toHaveAttribute("aria-expanded", "false")
      expect(screen.queryByText("Prepare data layer")).not.toBeInTheDocument()
      expect(screen.getByText("Land API surface")).toBeInTheDocument()

      fireEvent.click(expander)

      expect(expander).toHaveAttribute("aria-expanded", "true")
      expect(screen.getByText("Epic: Data Layer")).toBeInTheDocument()
      expect(screen.getByText("standalone")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Prepare data layer" })).toHaveAttribute("href", "/app-shell/jobs/2")
      expect(screen.getByRole("link", { name: "Prepare data layer" }).closest("tr")).toHaveClass("bg-gray-50/70")
      expect(screen.getByText("Prepare data layer").closest("tr")?.textContent).not.toContain("#1")

      const rowText = Array.from(document.querySelectorAll("tbody tr")).map((row) => row.textContent || "")
      expect(rowText.findIndex((text) => text.includes("Prepare data layer"))).toBeLessThan(rowText.findIndex((text) => text.includes("Land API surface")))
      expect(rowText.findIndex((text) => text.includes("Document rollout"))).toBeGreaterThan(rowText.findIndex((text) => text.includes("Land API surface")))
    } finally {
      restoreMedia()
    }
  })

  it("hides landing queue blocker expanders when not sorted by queue position", async () => {
    const restoreMedia = mockMediaQuery(true)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            preferences: {
              ...dashboardPayload().preferences,
              sort: { column: "title", direction: "asc" }
            },
            landing_queue: {
              visible: true,
              paused: false,
              toggle_path: "/api/v1/app/dashboard/landing_pause",
              entries: [
                {
                  key: "job:1",
                  position: 1,
                  job_ids: [1],
                  blocker_jobs: [{ id: 2, title: "Hidden blocker", job_path: "/jobs/2", state: "open", pr_number: null, pr_path: null }],
                  dependency_edges: [{ from_job_id: 2, to_job_id: 1 }]
                }
              ]
            },
            items: [
              dashboardJobItem({
                id: 1,
                title: "Visible approved job",
                landing_queue_position: 1,
                landing_queue_entry_key: "job:1",
                approved_at: "2026-06-01T10:00:00Z"
              })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Visible approved job")).toBeInTheDocument()
      expect(screen.queryByRole("button", { name: /blocker/ })).not.toBeInTheDocument()
      expect(screen.queryByText("Hidden blocker")).not.toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("resets queue sorting outside the landing queue folder", async () => {
    const restoreMedia = mockMediaQuery(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences") {
        expect(init?.method).toBe("PATCH")
        return new Response(
          JSON.stringify({ message: "Dashboard preferences updated.", dashboard_preferences: {} }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      }

      return new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            active_smart_folder_id: 3,
            preferences: {
              ...dashboardPayload().preferences,
              sort: { column: "landing_queue_position", direction: "asc" }
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "landing_queue_position", "created_at", "started_at"]
            },
            smart_folders: [
              {
                id: 3,
                name: "In progress",
                kind: "builtin",
                subject_type: "job",
                visibility: "when_present",
                count: 2,
                active: true,
                path: "/dashboard/jobs?smart_folder_id=3"
              }
            ],
            landing_queue: {
              visible: false,
              paused: false,
              toggle_path: "/api/v1/app/dashboard/landing_pause"
            },
            items: [
              dashboardJobItem({ id: 1, title: "First job", epic: { id: 10, number: 10, display_number: "#10", path: "/epics/10" } }),
              dashboardJobItem({ id: 2, title: "Second job", epic: { id: 11, number: 11, display_number: "#11", path: "/epics/11" } })
            ]
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=3"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("First job")).toBeInTheDocument()
      expect(screen.getByText("Second job").closest("tr")).not.toHaveClass("border-t-4")

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard/preferences",
          expect.objectContaining({
            method: "PATCH",
            body: JSON.stringify({
              subject: "job",
              active_smart_folder_id: 3,
              sort_column: "created_at",
              sort_direction: "desc"
            })
          })
        )
      })
    } finally {
      restoreMedia()
    }
  })

  it("points an empty first-run dashboard at the direct job action", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({ setupStatus: null }))
    document.body.appendChild(script)

    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            total: 0,
            counts: { jobs: 0, epics: 0, workflows: 0 },
            items: [],
            setup: setupStatusPayload()
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "No Jobs yet" })).toBeInTheDocument()
    expect(screen.getByText("Finish credentials first so Syrus can talk to GitHub and the selected agent.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open setup" })).toHaveAttribute("href", "/app-shell/setup")
  })

  it("does not mention finishing setup on a completed empty dashboard", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "list",
            total: 0,
            counts: { jobs: 0, epics: 0, workflows: 0 },
            items: []
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No jobs exist yet. Create work from a direct prompt or a labelled GitHub issue.")).toBeInTheDocument()
    expect(screen.queryByText(/Finish setup/)).not.toBeInTheDocument()
  })

  it("renders dashboard smart folder visibility groups and badges", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: { v2_ui: true, v2_sidebar_subject_selector: true }
    }))
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard?view=list&smart_folder_id=3&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                active_smart_folder_id: 3,
                smart_folders: [
                  {
                    id: 1,
                    name: "Inbox",
                    kind: "builtin",
                    subject_type: "job",
                    visibility: "always",
                    count: 3,
                    active: false,
                    path: "/dashboard/jobs?smart_folder_id=1"
                  },
                  {
                    id: 2,
                    name: "Stale",
                    kind: "builtin",
                    subject_type: "job",
                    visibility: "on_demand",
                    count: 1,
                    active: false,
                    path: "/dashboard/jobs?smart_folder_id=2"
                  },
                  {
                    id: 3,
                    name: "Merged this week",
                    kind: "builtin",
                    subject_type: "job",
                    visibility: "on_demand",
                    count: 0,
                    active: true,
                    path: "/dashboard/jobs?smart_folder_id=3"
                  },
                  {
                    id: 4,
                    name: "Saved review",
                    kind: "user_defined",
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 2,
                    active: false,
                    path: "/dashboard/jobs?smart_folder_id=4"
                  }
                ],
                filter: { and: [ { field: "attention", op: "is", value: "merged_this_week" } ] },
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
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

      const foldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      const primaryNav = screen.getByRole("navigation", { name: "Primary" })
      const dashboardLink = within(primaryNav).getByRole("link", { name: "Dashboard" })
      const dashboardSections = within(primaryNav).getByRole("navigation", { name: "Dashboard sections" })
      const dashboardSubnav = foldersPanel.closest("[aria-hidden]")
      expect(screen.queryByRole("navigation", { name: "Dashboard subjects" })).not.toBeInTheDocument()
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "false")
      expect(dashboardSections).toHaveClass("inline-flex", "max-w-full", "flex-wrap", "overflow-hidden", "rounded", "border", "border-gray-300", "bg-white", "dark:border-gray-700", "dark:bg-gray-900")
      expect(within(dashboardSections).getByRole("link", { name: "Epics" })).toHaveAttribute("href", "/app-shell/dashboard/epics")
      expect(within(dashboardSections).getByRole("link", { name: "Jobs" })).toHaveAttribute("href", "/app-shell/dashboard/jobs")
      expect(within(dashboardSections).getByRole("link", { name: "Jobs" })).toHaveClass("bg-blue-50", "text-blue-700", "ring-blue-600", "dark:bg-blue-950", "dark:text-blue-200")
      expect(within(dashboardSections).getByRole("link", { name: "Workflows" })).toHaveAttribute("href", "/app-shell/dashboard/workflows")
      expect(primaryNav).toContainElement(foldersPanel)
      expect(dashboardLink.parentElement).toContainElement(dashboardSections)
      expect(dashboardLink.parentElement).toContainElement(foldersPanel)
      expect(within(foldersPanel).getByRole("link", { name: "Inbox 3" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=1")
      const moreGroup = within(foldersPanel).getByText("More").closest("details")
      expect(moreGroup).not.toBeNull()
      expect(within(moreGroup!).getByRole("link", { name: "All jobs" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=all")
      expect(within(moreGroup!).getByRole("link", { name: "Stale 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=2")
      expect(within(moreGroup!).getByRole("link", { name: "Merged this week 0" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=3")
      expect(within(foldersPanel).getAllByRole("link", { name: "All jobs" })).toHaveLength(1)
      expect(screen.getByRole("button", { name: /Attention preset.*Merged this week/ })).toBeInTheDocument()
      const savedReviewLink = within(foldersPanel).getByRole("link", { name: "Saved review 2" })
      expect(savedReviewLink).toHaveAttribute("href", "/app-shell/dashboard/jobs?smart_folder_id=4")
      expect(within(foldersPanel).queryByRole("link", { name: "Manage" })).not.toBeInTheDocument()
      expect(within(foldersPanel).queryByLabelText("Folder name")).not.toBeInTheDocument()
      expect(within(foldersPanel).queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
      fireEvent.mouseEnter(savedReviewLink.parentElement!)
      fireEvent.click(within(foldersPanel).getByRole("button", { name: "Actions for Saved review" }))
      const folderMenu = screen.getByRole("menu")
      expect(folderMenu.parentElement).toBe(document.body)
      expect(foldersPanel).not.toContainElement(folderMenu)

      fireEvent.click(dashboardLink)
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "true")

      fireEvent.click(dashboardLink)
      expect(dashboardSubnav).toHaveAttribute("aria-hidden", "false")
    } finally {
      script.remove()
    }
  })

  it("saves an applied dashboard filter from the v2 sidebar folders", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const appliedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const savedFilter = { and: [{ field: "kind", op: "is", value: "issue" }] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/dashboard/jobs?smart_folder_id=11",
              smart_folder: { id: 11, name: "Open work", position: 1, filter: appliedFilter }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/dashboard") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: url.searchParams.get("smart_folder_id") === "7" ? 7 : null,
                filter: appliedFilter,
                smart_folders: [
                  {
                    id: 7,
                    name: "My work",
                    kind: "user_defined",
                    position: 2,
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 1,
                    active: url.searchParams.get("smart_folder_id") === "7",
                    filter: savedFilter,
                    path: "/dashboard/jobs?smart_folder_id=7"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7&q=stale"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("heading", { name: "Smart folders" })).not.toBeInTheDocument()
      const folderNameInput = within(smartFoldersPanel).getByLabelText("Folder name")
      expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()
      expect(within(smartFoldersPanel).getByRole("heading", { name: "Saved" }).compareDocumentPosition(folderNameInput) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
      fireEvent.change(folderNameInput, { target: { value: "Open work" } })
      fireEvent.click(within(smartFoldersPanel).getByRole("button", { name: "Save folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders",
          expect.objectContaining({
            method: "POST",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({
              filter: JSON.stringify(appliedFilter),
              subject_type: "job",
              smart_folder: { name: "Open work" }
            })
          })
        )
      })
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard?smart_folder_id=11&subject=job",
          expect.objectContaining({ credentials: "same-origin" })
        )
      })
    } finally {
      script.remove()
    }
  })

  it("shows update and save actions when the active saved dashboard folder filter differs", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard?view=list&smart_folder_id=7&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: 7,
                filter: { and: [{ field: "kind", op: "is", value: "issue" }] },
                smart_folders: [
                  {
                    id: 7,
                    name: "My work",
                    kind: "user_defined",
                    position: 2,
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 1,
                    active: true,
                    filter: { and: [{ field: "state", op: "is", value: "open" }] },
                    path: "/dashboard/jobs?view=list&smart_folder_id=7"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).getByRole("button", { name: "Update My work" })).toBeInTheDocument()
      expect(within(smartFoldersPanel).getByRole("button", { name: "Save folder" })).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("hides update and save actions when the active saved dashboard folder filter matches", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/dashboard?view=list&smart_folder_id=7&subject=job") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: 7,
                filter: { and: [{ field: "state", op: "is", value: "open" }] },
                smart_folders: [
                  {
                    id: 7,
                    name: "My work",
                    kind: "user_defined",
                    position: 2,
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 1,
                    active: true,
                    filter: { and: [{ field: "state", op: "is", value: "open" }] },
                    path: "/dashboard/jobs?view=list&smart_folder_id=7"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Update My work" })).not.toBeInTheDocument()
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("preserves the active smart folder while dashboard filters change", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    const storedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const dashboardRequests: string[] = []
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/filters/usage" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Recorded." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/dashboard" && url.searchParams.get("smart_folder_id") === "7") {
        dashboardRequests.push(path)
        const q = url.searchParams.get("q")
        const filter = q ? decodeFilterQueryParam(q) : storedFilter
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: 7,
                filter,
                smart_folders: [
                  {
                    id: 7,
                    name: "My work",
                    kind: "user_defined",
                    position: 2,
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 1,
                    active: true,
                    filter: storedFilter,
                    path: "/dashboard/jobs?view=list&smart_folder_id=7"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByRole("button", { name: "Update My work" })).not.toBeInTheDocument()

      fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Kind enum" }))

      await waitFor(() => {
        expect(dashboardRequests.some((request) => {
          const url = new URL(request, "http://example.test")
          return url.searchParams.get("smart_folder_id") === "7" && url.searchParams.has("q")
        })).toBe(true)
      })
      expect(await within(smartFoldersPanel).findByRole("button", { name: "Update My work" })).toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Has parent boolean" }))

      await waitFor(() => {
        const latestRequest = dashboardRequests.at(-1)
        expect(latestRequest).toBeTruthy()
        const url = new URL(latestRequest!, "http://example.test")
        const qTree = decodeFilterQueryParam(url.searchParams.get("q")!)
        expect(qTree.and.filter((chip) => chip.field === "state")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "kind")).toHaveLength(1)
        expect(qTree.and.filter((chip) => chip.field === "has_parent")).toHaveLength(1)
      })
    } finally {
      script.remove()
    }
  })

  it("clears built-in dashboard folder scope when applying filters", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    const dashboardRequests: string[] = []
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/filters/usage" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Recorded." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/dashboard") {
        dashboardRequests.push(path)
        const hasSmartFolder = url.searchParams.get("smart_folder_id") === "1"
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: hasSmartFolder ? 1 : null,
                filter: url.searchParams.get("q") ? decodeFilterQueryParam(url.searchParams.get("q")!) : { and: [] },
                smart_folders: [
                  {
                    id: 1,
                    name: "Inbox",
                    kind: "attention_preset",
                    position: 0,
                    subject_type: "job",
                    visibility: "primary",
                    count: 1,
                    active: hasSmartFolder,
                    filter: { and: [{ field: "attention", op: "is", value: "inbox" }] },
                    path: "/dashboard/jobs?view=list&smart_folder_id=1"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=1"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).queryByLabelText("Folder name")).not.toBeInTheDocument()

      fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))
      fireEvent.click(screen.getByRole("button", { name: "Kind enum" }))

      await waitFor(() => {
        const latestRequest = dashboardRequests.at(-1)
        expect(latestRequest).toBeTruthy()
        const url = new URL(latestRequest!, "http://example.test")
        expect(url.searchParams.has("q")).toBe(true)
        expect(url.searchParams.has("smart_folder_id")).toBe(false)
      })
      expect(within(smartFoldersPanel).queryByLabelText("Folder name")).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("updates the active saved dashboard folder with the applied filter", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      feature_flags: { v2_ui: true }
    }))
    document.body.appendChild(script)
    const storedFilter = { and: [{ field: "state", op: "is", value: "open" }] }
    const appliedFilter = { and: [{ field: "kind", op: "is", value: "issue" }] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ chats: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/smart_folders/7" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              subject_type: "job",
              subject_label: "Job",
              dashboard_path: "/dashboard/jobs",
              smart_folders: [
                {
                  id: 7,
                  name: "My work",
                  position: 2,
                  filter: appliedFilter
                }
              ],
              message: "Smart folder updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/dashboard" && url.searchParams.get("smart_folder_id") === "7") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              dashboardPayload({
                subject: "job",
                view: "list",
                active_smart_folder_id: 7,
                filter: appliedFilter,
                smart_folders: [
                  {
                    id: 7,
                    name: "My work",
                    kind: "user_defined",
                    position: 2,
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 1,
                    active: true,
                    filter: storedFilter,
                    path: "/dashboard/jobs?view=list&smart_folder_id=7"
                  }
                ],
                items: [dashboardJobItem()]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=7&q=stale"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const smartFoldersPanel = await screen.findByLabelText("Dashboard smart folders panel")
      expect(within(smartFoldersPanel).getByRole("button", { name: "Save folder" })).toBeInTheDocument()
      fireEvent.click(within(smartFoldersPanel).getByRole("button", { name: "Update My work" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders/7",
          expect.objectContaining({
            method: "PATCH",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({
              filter: JSON.stringify(appliedFilter),
              smart_folder: {
                name: "My work",
                position: 2
              }
            })
          })
        )
      })
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/dashboard?view=list&smart_folder_id=7&subject=job",
          expect.objectContaining({ credentials: "same-origin" })
        )
      })
    } finally {
      script.remove()
    }
  })

  it("renders app-shell dashboard kanban lanes from the app dashboard API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/dashboard/preferences" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Dashboard preferences updated.",
              dashboard_preferences: {}
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "job",
              view: "kanban",
              total: 1,
              lanes: [
                { key: "queued", title: "Queued", count: 0, items: [] },
                { key: "running", title: "Running", count: 1, items: [dashboardJobItem()] },
                { key: "succeeded", title: "Succeeded", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Running" })).toBeInTheDocument()
    expect(screen.getByText("Repair aqueduct")).toBeInTheDocument()
    expect(screen.getByText("Repair aqueduct").closest(".select-none")).toBeInTheDocument()
    expectRunningPill(screen.getByText("running"))
    expect(screen.getByLabelText("Active workflow trigger: rebase")).toHaveTextContent("rebase")
    expect(screen.getByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByRole("link", { name: "PR #34" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/34")
    expect(screen.queryByText(/Showing/)).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/dashboard?view=kanban&subject=job",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )

    const lanesButton = screen.getByRole("button", { name: "Kanban lanes" })
    expect(lanesButton).toHaveClass("h-9", "w-9")
    expect(lanesButton).not.toHaveTextContent("Kanban lanes")
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("group", { name: "Kanban lanes" })).not.toBeInTheDocument()
    fireEvent.click(lanesButton)
    expect(screen.getByRole("group", { name: "Kanban lanes" })).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("Succeeded"))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard/preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            subject: "job",
            kanban_lanes: ["queued", "running"]
          })
        })
      )
    })
  })

  it("limits Kanban lanes to 20 cards and loads more on demand", async () => {
    const runningJobs = Array.from({ length: 25 }, (_, index) => dashboardJobItem({
      id: index + 1,
      title: `Repair aqueduct ${index + 1}`,
      paths: { job_path: `/jobs/${index + 1}`, source_path: `/jobs/${index + 1}/source` }
    }))

    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "job",
            view: "kanban",
            total: 25,
            lanes: [
              { key: "queued", title: "Queued", count: 0, items: [] },
              { key: "running", title: "Running", count: 25, items: runningJobs },
              { key: "succeeded", title: "Succeeded", count: 0, items: [] }
            ],
            kanban_limit: 100
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Repair aqueduct 20" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Repair aqueduct 21" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load more Running" }))

    expect(screen.getByRole("link", { name: "Repair aqueduct 21" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repair aqueduct 25" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Load more Running" })).not.toBeInTheDocument()
  })

  it("shows a needs attention badge on stuck Epic kanban cards", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "epic",
            view: "kanban",
            preferences: {
              sort: { column: "updated_at", direction: "desc" },
              visible_columns: ["epic", "state", "repository", "updated"],
              kanban_lanes: ["in_progress"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "updated_at"],
              kanban_lanes: [{ key: "in_progress", title: "In progress" }]
            },
            lanes: [
              {
                key: "in_progress",
                title: "In progress",
                count: 1,
                items: [dashboardEpicItem({ state: "in_progress", stuck: true, landed_jobs_count: 0 })]
              }
            ],
            kanban_limit: 100
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )
    const clipboardWrite = mockClipboardWrite()

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const copySlugButton = within(card).getByRole("button", { name: "Copy EPIC-7 to clipboard" })
    expect(copySlugButton).toHaveTextContent("EPIC-7")
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("EPIC-7"))
    const badge = within(card).getByText("Needs attention")
    expect(badge).toHaveAttribute("title", "All jobs closed - mark this epic done or file a follow-up.")
  })

  it("hides the needs attention badge on non-stuck Epic kanban cards", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "epic",
            view: "kanban",
            preferences: {
              sort: { column: "updated_at", direction: "desc" },
              visible_columns: ["epic", "state", "repository", "updated"],
              kanban_lanes: ["in_progress"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "updated_at"],
              kanban_lanes: [{ key: "in_progress", title: "In progress" }]
            },
            lanes: [
              {
                key: "in_progress",
                title: "In progress",
                count: 1,
                items: [dashboardEpicItem({ state: "in_progress", stuck: false, landed_jobs_count: 0 })]
              }
            ],
            kanban_limit: 100
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    expect(within(card).queryByText("Needs attention")).not.toBeInTheDocument()
  })

  it("shows a colorful progress bar for in_progress Epic kanban cards", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "epic",
            view: "kanban",
            preferences: {
              sort: { column: "updated_at", direction: "desc" },
              visible_columns: ["epic", "state", "repository", "updated"],
              kanban_lanes: ["in_progress"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "updated_at"],
              kanban_lanes: [{ key: "in_progress", title: "In progress" }]
            },
            lanes: [
              {
                key: "in_progress",
                title: "In progress",
                count: 1,
                items: [dashboardEpicItem({ state: "in_progress", jobs_count: 3, job_state_counts: { approved: 1, implemented: 2 } })]
              }
            ],
            kanban_limit: 100
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    expect(within(card).getByRole("progressbar", { name: "Epic job progress" })).toBeInTheDocument()
  })

  it("hides the progress bar for non-in_progress Epic kanban cards", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(
          dashboardPayload({
            subject: "epic",
            view: "kanban",
            preferences: {
              sort: { column: "updated_at", direction: "desc" },
              visible_columns: ["epic", "state", "repository", "updated"],
              kanban_lanes: ["ready"],
              raw: {}
            },
            controls: {
              ...dashboardPayload().controls,
              sort_columns: ["title", "state", "repository", "updated_at"],
              kanban_lanes: [{ key: "ready", title: "Ready" }]
            },
            lanes: [
              {
                key: "ready",
                title: "Ready",
                count: 1,
                items: [dashboardEpicItem({ state: "ready", jobs_count: 3, job_state_counts: { approved: 1 } })]
              }
            ],
            kanban_limit: 100
          })
        ),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    expect(within(card).queryByRole("progressbar")).not.toBeInTheDocument()
  })

  it("moves Epic kanban cards with drag and drop", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["backlog", "ready", "in_progress"],
                raw: {}
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "backlog", title: "Backlog" },
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                { key: "backlog", title: "Backlog", count: 0, items: [] },
                { key: "ready", title: "Ready", count: 1, items: [dashboardEpicItem()] },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

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
    expect(await screen.findByRole("status")).toHaveTextContent("Epic updated.")
  })

  it("moves all-closed Epic kanban cards to Done with drag and drop", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["in_progress", "done"],
                raw: {}
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "in_progress", title: "In progress" },
                  { key: "done", title: "Done" }
                ]
              },
              lanes: [
                { key: "in_progress", title: "In progress", count: 1, items: [dashboardEpicItem({ state: "in_progress", all_jobs_closed: true })] },
                { key: "done", title: "Done", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("Done lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/state",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ target_state: "done" })
        })
      )
    })
    expect(await screen.findByRole("status")).toHaveTextContent("Epic updated.")
  })

  it("optimistically moves Epic kanban cards and keeps drag enabled while updates are pending", async () => {
    let resolvePatch: (response: Response) => void = () => {}
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return new Promise((resolve) => {
          resolvePatch = resolve
        })
      }

      if (path === "/api/v1/app/epics/8/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Epic updated." }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 2,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["ready", "in_progress"],
                raw: {}
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                {
                  key: "ready",
                  title: "Ready",
                  count: 2,
                  items: [
                    dashboardEpicItem(),
                    dashboardEpicItem({
                      id: 8,
                      number: 8,
                      display_number: "EPIC-8",
                      title: "Raise the basilica",
                      paths: {
                        epic_path: "/epics/8",
                        edit_epic_path: "/epics/8/edit",
                        app_state_path: "/api/v1/app/epics/8/state"
                      }
                    })
                  ]
                },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const firstCard = await screen.findByLabelText("EPIC-7 Raise the forum")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(firstCard, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    expect(within(targetLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()

    const secondCard = screen.getByLabelText("EPIC-8 Raise the basilica")
    fireEvent.dragStart(secondCard, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/8/state",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ target_state: "in_progress" })
        })
      )
    })
    expect(within(targetLane).getByRole("link", { name: "Raise the basilica" })).toBeInTheDocument()

    resolvePatch(
      new Response(JSON.stringify({ message: "Epic updated." }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    )
  })

  it("rolls optimistic Epic kanban moves back when the update fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ error: { message: "The senate objected." } }), {
            status: 422,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify(
            dashboardPayload({
              subject: "epic",
              view: "kanban",
              total: 1,
              preferences: {
                sort: { column: "updated_at", direction: "desc" },
                visible_columns: ["epic", "state", "repository", "updated"],
                kanban_lanes: ["ready", "in_progress"],
                raw: {}
              },
              controls: {
                ...dashboardPayload().controls,
                sort_columns: ["title", "state", "repository", "updated_at"],
                kanban_lanes: [
                  { key: "ready", title: "Ready" },
                  { key: "in_progress", title: "In progress" }
                ]
              },
              lanes: [
                { key: "ready", title: "Ready", count: 1, items: [dashboardEpicItem()] },
                { key: "in_progress", title: "In progress", count: 0, items: [] }
              ],
              kanban_limit: 100
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/epics?view=kanban"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const card = await screen.findByLabelText("EPIC-7 Raise the forum")
    const readyLane = screen.getByLabelText("Ready lane")
    const targetLane = screen.getByLabelText("In progress lane")
    const dataTransfer = {
      dropEffect: "",
      effectAllowed: "",
      setData: vi.fn()
    }

    fireEvent.dragStart(card, { dataTransfer })
    fireEvent.dragOver(targetLane, { dataTransfer })
    fireEvent.drop(targetLane, { dataTransfer })

    expect(within(targetLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()
    expect(await screen.findByRole("alert")).toHaveTextContent("The senate objected.")

    await waitFor(() => {
      expect(within(readyLane).getByRole("link", { name: "Raise the forum" })).toBeInTheDocument()
    })
    expect(within(targetLane).queryByRole("link", { name: "Raise the forum" })).not.toBeInTheDocument()
  })

  it("renders the admin queue route from the app admin queue API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          filter: { and: [ { field: "queue_name", op: "is", value: "runs" } ] },
          controls: {
            filter_schema: [
              {
                field: "queue_name",
                label: "Queue",
                bucket: "enum",
                operators: ["is", "is_one_of"],
                values: [
                  { value: "runs", label: "Runs" },
                  { value: "chat", label: "Chat" },
                  { value: "default", label: "Default" }
                ]
              },
              { field: "job_class", label: "Job class", bucket: "string", operators: ["contains", "is"], values: [] }
            ]
          },
          active_smart_folder_id: 1,
          smart_folders: [
            {
              id: 1,
              name: "Runs",
              kind: "builtin",
              subject_type: "admin_queue",
              visibility: "always",
              count: 1,
              active: true,
              path: "/admin/queue/active?smart_folder_id=1"
            },
            {
              id: 2,
              name: "Chat",
              kind: "builtin",
              subject_type: "admin_queue",
              visibility: "always",
              count: 0,
              active: false,
              path: "/admin/queue/active?smart_folder_id=2"
            }
          ],
          jobs: [
            {
              id: 12,
              class_name: "RunJob",
              queue_name: "runs",
              arguments: [42],
              created_at: "2026-05-30T12:00:00Z",
              claimed_at: "2026-05-30T12:01:00Z"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin queue" })).toBeInTheDocument()
      expect(screen.getByRole("heading", { name: "Queue" }).closest("header")).toHaveClass("items-end", "justify-between")
      expect(screen.getByRole("button", { name: "Run stale-run reaper" })).toHaveClass("shrink-0")
      expect(await screen.findByText("RunJob")).toBeInTheDocument()
      const disclosure = screen.getByText("Folders and filters").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("runs")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /Queue is Runs/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Job class string" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Runs 1" })).toHaveAttribute("href", "/app-shell/admin/queue/active?smart_folder_id=1")
      expect(screen.getByRole("link", { name: "All queue" })).toHaveAttribute("href", "/app-shell/admin/queue/active")
      expect(screen.getByRole("link", { name: "Failed" })).toHaveAttribute("href", "/app-shell/admin/queue/failed")
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/queue/active",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("keeps the admin queue filter editor open while filter changes refetch", async () => {
    const restoreMedia = mockMediaQuery(false)
    let resolveRefetch: (response: Response) => void = () => {}
    const queuePayload = (value: string) => ({
      filter: { and: [{ field: "job_class", op: "contains", value }] },
      controls: {
        filter_schema: [
          { field: "queue_name", label: "Queue", bucket: "enum", operators: ["is"], values: [{ value: "runs", label: "Runs" }] },
          { field: "job_class", label: "Job class", bucket: "string", operators: ["contains", "is"], values: [] }
        ]
      },
      active_smart_folder_id: null,
      smart_folders: [],
      jobs: [
        {
          id: 12,
          class_name: "RunJob",
          queue_name: "runs",
          arguments: [42],
          created_at: "2026-05-30T12:00:00Z",
          claimed_at: "2026-05-30T12:01:00Z"
        }
      ]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname !== "/api/v1/app/admin/queue/active") {
        return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
      }

      if (!url.searchParams.has("q")) {
        return Promise.resolve(new Response(JSON.stringify(queuePayload("Run")), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return new Promise<Response>((resolve) => {
        resolveRefetch = resolve
      })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("RunJob")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      fireEvent.click(screen.getByRole("button", { name: "Job class contains Run" }))

      const valueInput = screen.getByLabelText("Value")
      fireEvent.change(valueInput, { target: { value: "RunJ" } })
      fireEvent.keyDown(valueInput, { key: "Enter" })

      await waitFor(() => {
        const queueCalls = fetchSpy.mock.calls.filter((call) => String(call[0]).startsWith("/api/v1/app/admin/queue"))
        expect(queueCalls).toHaveLength(2)
      })
      expect(screen.getByRole("dialog", { name: "Job class filter settings" })).toBeInTheDocument()
      expect(screen.getByLabelText("Value")).toHaveValue("RunJ")

      resolveRefetch(new Response(JSON.stringify(queuePayload("RunJ")), { status: 200, headers: { "Content-Type": "application/json" } }))
      await waitFor(() => {
        expect(screen.getByRole("button", { name: "Job class contains RunJ" })).toBeInTheDocument()
      })
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("shows an update button for admin queue saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    let queuePayload = adminQueuePayloadWithSavedFolder({
      and: [ { field: "queue_name", op: "is", value: "chat" } ]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = new URL(String(input), "http://example.test")
      const method = init?.method || "GET"
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        return Promise.resolve(jsonResponse(queuePayload))
      }
      if (url.pathname === "/api/v1/app/smart_folders/10" && method === "PATCH") {
        queuePayload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
        return Promise.resolve(jsonResponse({ ...queuePayload, message: "Smart folder updated." }))
      }
      if (url.pathname === "/api/v1/app/smart_folders" && method === "POST") {
        queuePayload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
        return Promise.resolve(jsonResponse({
          ...queuePayload,
          message: "Smart folder saved.",
          redirect_to: "/admin/queue/active?smart_folder_id=10"
        }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${method} ${url.pathname}`))
    })

    try {
      const updateView = renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10&q=dGVzdA")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "Update Run repairs" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders/10",
          expect.objectContaining({ method: "PATCH" })
        )
      })
      const patchCall = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/smart_folders/10" && (init as RequestInit | undefined)?.method === "PATCH")
      expect(JSON.parse(String((patchCall?.[1] as RequestInit).body))).toMatchObject({
        filter: JSON.stringify(currentAdminQueueFilter()),
        smart_folder: {
          name: "Run repairs",
          position: 2
        }
      })
      await waitFor(() => {
        expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
      })
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()

      updateView.unmount()
      fetchSpy.mockClear()
      queuePayload = adminQueuePayloadWithSavedFolder({
        and: [ { field: "queue_name", op: "is", value: "chat" } ]
      })

      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10&q=dGVzdA")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      fireEvent.change(screen.getByLabelText("Folder name"), { target: { value: "Chat repairs" } })
      fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders",
          expect.objectContaining({ method: "POST" })
        )
      })
      const postCall = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/smart_folders" && (init as RequestInit | undefined)?.method === "POST")
      expect(JSON.parse(String((postCall?.[1] as RequestInit).body))).toMatchObject({
        filter: JSON.stringify(currentAdminQueueFilter()),
        subject_type: "admin_queue",
        smart_folder: { name: "Chat repairs" }
      })
      await waitFor(() => {
        expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
      })
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("saves an applied admin queue filter from the smart folder nav", async () => {
    const restoreMedia = mockMediaQuery(false)
    const appliedFilter = { and: [ { field: "queue_name", op: "is", value: "runs" } ] }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/smart_folders" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Smart folder saved.",
              redirect_to: "/admin/queue?smart_folder_id=21",
              smart_folder: { id: 21, name: "Runs queue", position: 1, filter: appliedFilter }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      const url = new URL(path, "http://example.test")
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        const activeFolderId = url.searchParams.get("smart_folder_id")
        return Promise.resolve(
          new Response(
            JSON.stringify({
              filter: appliedFilter,
              controls: {
                filter_schema: [
                  {
                    field: "queue_name",
                    label: "Queue",
                    bucket: "enum",
                    operators: ["is", "is_one_of"],
                    values: [
                      { value: "runs", label: "Runs" },
                      { value: "chat", label: "Chat" }
                    ]
                  }
                ]
              },
              active_smart_folder_id: activeFolderId ? Number(activeFolderId) : null,
              smart_folders: [
                {
                  id: 1,
                  name: "Runs",
                  kind: "builtin",
                  subject_type: "admin_queue",
                  visibility: "always",
                  count: 1,
                  active: activeFolderId === "1",
                  filter: { and: [ { field: "queue_name", op: "is", value: "chat" } ] },
                  path: "/admin/queue/active?smart_folder_id=1"
                }
              ],
              jobs: [
                {
                  id: 12,
                  class_name: "RunJob",
                  queue_name: "runs",
                  arguments: [42],
                  created_at: "2026-05-30T12:00:00Z",
                  claimed_at: "2026-05-30T12:01:00Z"
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/queue/active?smart_folder_id=1&q=changed"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByText("RunJob")
      const disclosure = screen.getByText("Folders and filters").closest("details")
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(disclosure).toHaveAttribute("open")
      const folderNameInput = screen.getByLabelText("Folder name")
      fireEvent.change(folderNameInput, { target: { value: "Runs queue" } })
      fireEvent.click(screen.getByRole("button", { name: "Save as new folder" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/smart_folders",
          expect.objectContaining({
            method: "POST",
            credentials: "same-origin",
            headers: expect.objectContaining({
              Accept: "application/json",
              "Content-Type": "application/json"
            }),
            body: JSON.stringify({
              filter: JSON.stringify(appliedFilter),
              subject_type: "admin_queue",
              smart_folder: { name: "Runs queue" }
            })
          })
        )
      })
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin queue filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...payload,
      active_smart_folder_id: null,
      smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
    }))

    try {
      renderAppAt("/app-shell/admin/queue/active")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin queue saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/queue/active") {
        return Promise.resolve(jsonResponse(adminQueuePayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "Queue is Runs" }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "chat" } })

      await waitFor(() => {
        expect(fetchSpy.mock.calls.some(([path]) => {
          const url = new URL(String(path), "http://example.test")
          return url.pathname === "/api/v1/app/admin/queue/active" && url.searchParams.get("smart_folder_id") === "10" && url.searchParams.has("q")
        })).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Run repairs" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin queue saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminQueuePayloadWithSavedFolder(currentAdminQueueFilter())))

    try {
      renderAppAt("/app-shell/admin/queue/active?smart_folder_id=10")

      expect(await screen.findByText("No active claimed executions.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Run repairs" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("renders admin queue workers when SolidQueue reports queue metadata as a string", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          workers: [
            {
              hostname: "worker-a",
              pid: 101,
              queues: "runs",
              threads: 2,
              last_heartbeat_at: "2026-05-30T12:00:00Z",
              stale: false
            }
          ],
          all_processes: [
            {
              kind: "Worker",
              hostname: "worker-a",
              pid: 101,
              last_heartbeat_at: "2026-05-30T12:00:00Z"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/queue/workers"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin queue" })).toBeInTheDocument()
    expect(await screen.findAllByText("worker-a")).toHaveLength(2)
    expect(screen.getByText("runs")).toBeInTheDocument()
    expect(screen.getByText("healthy")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/queue/workers",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin stuck route from the app admin stuck API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          items: [
            {
              kind: "stale_heartbeat",
              severity: "warn",
              detail: "Run #4 silent for 10m",
              age_label: "10m",
              run_id: 4,
              workflow_id: 2,
              workflow_slug: "WF-2",
              workflow_path: "/jobs/1?tab=workflows#workflow-2",
              workflow_trigger_kind: "initial",
              step_kind: "implement",
              job_id: 1,
              job_path: "/jobs/1",
              has_transcript: true
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/stuck"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin stuck items" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Stuck Things" }).closest("header")).toHaveClass("items-end", "justify-between")
    expect(screen.getByRole("button", { name: /Refresh/ })).toHaveClass("shrink-0")
    expect(await screen.findByText("Run #4 silent for 10m")).toBeInTheDocument()
    expect(screen.getByText("stale_heartbeat")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/jobs/1?tab=workflows#workflow-2")
    expect(screen.getByRole("link", { name: "Job" })).toHaveAttribute("href", "/app-shell/jobs/1")
    expect(screen.getByRole("link", { name: "Transcript" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/stuck",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin processes route from the app admin processes API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          filter: { and: [ { field: "state", op: "is", value: "running" } ] },
          controls: {
            filter_schema: [
              {
                field: "state",
                label: "State",
                bucket: "enum",
                operators: ["is", "is_one_of"],
                values: [
                  { value: "running", label: "Running" },
                  { value: "finished", label: "Finished" }
                ]
              },
              { field: "kind", label: "Kind", bucket: "enum", operators: ["is"], values: [ { value: "agent", label: "Agent" } ] },
              { field: "hostname", label: "Hostname", bucket: "enum", operators: ["is"], values: [ { value: "worker-a", label: "worker-a" } ] }
            ]
          },
          active_smart_folder_id: 3,
          smart_folders: [
            {
              id: 3,
              name: "Running",
              kind: "builtin",
              subject_type: "spawned_process",
              visibility: "always",
              count: 1,
              active: true,
              path: "/admin/processes?smart_folder_id=3"
            }
          ],
          running_total: 1,
          processes: [
            {
              id: 8,
              kind: "agent",
              command: "claude --print",
              workdir: "/work",
              hostname: "worker-a",
              pid: 123,
              pgid: 123,
              started_at: "2026-05-30T12:00:00Z",
              last_chunk_at: "2026-05-30T12:01:00Z",
              finished_at: null,
              duration_s: 65,
              exit_status: null,
              outcome: null,
              wall_timeout_s: 1800,
              silent_timeout_s: 300,
              run_id: 4,
              workflow_id: 2,
              stale: false,
              kill_requested_at: null,
              kill_requested_by_user_id: null
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/processes?state=running"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin processes" })).toBeInTheDocument()
      expect(await screen.findByText("claude --print")).toBeInTheDocument()
      const disclosure = screen.getByText("Folders and filters").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("worker-a")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /State is Running/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Hostname enum" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Running 1" })).toHaveAttribute("href", "/app-shell/admin/processes?smart_folder_id=3")
      expect(screen.getByRole("link", { name: "Detail" })).toHaveAttribute("href", "/app-shell/admin/processes/8")
      expect(screen.getByRole("button", { name: "Kill" })).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/processes?state=running",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("shows an update button for admin process saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminProcessesPayloadWithSavedFolder({
      and: [ { field: "state", op: "is", value: "finished" } ]
    })))

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11&q=dGVzdA")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.getByRole("button", { name: "Update Live agents" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin process filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...payload,
      active_smart_folder_id: null,
      smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
    }))

    try {
      renderAppAt("/app-shell/admin/processes")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin process saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/processes") {
        return Promise.resolve(jsonResponse(adminProcessesPayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: "State is Running" }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "finished" } })

      await waitFor(() => {
        expect(fetchSpy.mock.calls.some(([path]) => {
          const url = new URL(String(path), "http://example.test")
          return url.pathname === "/api/v1/app/admin/processes" && url.searchParams.get("smart_folder_id") === "11" && url.searchParams.has("q")
        })).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Live agents" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin process saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter())))

    try {
      renderAppAt("/app-shell/admin/processes?smart_folder_id=11")

      expect(await screen.findByText("No processes match this filter.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Live agents" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("renders the admin process detail route with React transcript links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          id: 8,
          kind: "agent",
          command: "claude --print",
          workdir: "/work",
          hostname: "worker-a",
          pid: 123,
          pgid: 123,
          started_at: "2026-05-30T12:00:00Z",
          last_chunk_at: "2026-05-30T12:01:00Z",
          finished_at: null,
          duration_s: 65,
          exit_status: null,
          outcome: null,
          wall_timeout_s: 1800,
          silent_timeout_s: 300,
          run_id: 4,
          workflow_id: 2,
          workflow_slug: "WF-2",
          workflow_path: "/jobs/42?tab=workflows#workflow-2",
          stale: false,
          kill_requested_at: null,
          kill_requested_by_user_id: null,
          host_metrics: null
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/processes/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const processDetail = screen.getByRole("main", { name: "Admin process detail" })
    expect(processDetail).toBeInTheDocument()
    expect(await within(processDetail).findByText("claude --print")).toBeInTheDocument()
    expect(within(processDetail).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
    expect(within(processDetail).getByRole("link", { name: "#4" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript")
    expect(within(processDetail).getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-2")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/processes/8",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin users route from the app admin users API", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          filters: { gh_rate: "low" },
          filter: { and: [ { field: "gh_rate", op: "is", value: "low" } ] },
          controls: {
            filter_schema: [
              { field: "email", label: "Email", bucket: "string", operators: ["contains", "not_contains"], values: [] },
              {
                field: "gh_rate",
                label: "GH rate",
                bucket: "enum",
                operators: ["is"],
                values: [
                  { value: "low", label: "Low (<10%)" },
                  { value: "exhausted", label: "Exhausted" }
                ]
              }
            ]
          },
          count: 1,
          active_smart_folder_id: 5,
          smart_folders: [
            {
              id: 5,
              name: "Rate limit low",
              kind: "builtin",
              subject_type: "admin_user",
              visibility: "when_present",
              count: 1,
              active: true,
              path: "/admin/users?smart_folder_id=5"
            },
            {
              id: 6,
              name: "Admins",
              kind: "builtin",
              subject_type: "admin_user",
              visibility: "on_demand",
              count: 1,
              active: false,
              path: "/admin/users?smart_folder_id=6"
            }
          ],
          users: [
            {
              id: 5,
              email_address: "operator@example.com",
              name: "Operator",
              first_name: null,
              last_name: null,
              profile_bio: null,
              profile_location: null,
              profile_company: null,
              profile_website: null,
              display_name: "Operator",
              github_handle: "octo",
              admin: true,
              scheduling_paused: false,
              agent_provider: "codex",
              codex_auth_mode: "api_key",
              has_github_token: true,
              has_claude_token: false,
              has_codex_token: true,
              has_codex_api_key: true,
              has_codex_auth_json: false,
              has_api_token: true,
              agent_max_turns: 200,
              github_api_blocked: false,
              github_api_blocked_at: null,
              github_api_blocked_reason: null,
              github_rate_limit: {
                remaining: 5,
                limit: 5000,
                resource: "core",
                reset_at: null,
                observed_at: null,
                percent: 0.001
              },
              created_at: "2026-05-30T12:00:00Z",
              updated_at: "2026-05-30T12:00:00Z"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin/users?gh_rate=low"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.getByRole("main", { name: "Admin users" })).toBeInTheDocument()
      expect(await screen.findByText("Operator")).toBeInTheDocument()
      const disclosure = screen.getByText("Folders and filters").closest("details")
      expect(disclosure).not.toHaveAttribute("open")
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(disclosure).toHaveAttribute("open")
      expect(screen.getByText("operator@example.com")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: /GH rate is Low/ })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("button", { name: "+ Add filter" }))
      expect(screen.getByRole("button", { name: "Email string" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Operator" })).toHaveAttribute("href", "/app-shell/admin/users/5")
      expect(screen.getByRole("link", { name: "Rate limit low 1" })).toHaveAttribute("href", "/app-shell/admin/users?smart_folder_id=5")
      expect(screen.getByText("More")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/users?gh_rate=low",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreMedia()
    }
  })

  it("shows an update button for admin user saved folder filter drift", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminUsersPayloadWithSavedFolder({
      and: [ { field: "admin", op: "is", value: true } ]
    })))

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12&q=dGVzdA")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.getByRole("button", { name: "Update Low rate users" })).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Save as new folder" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the save form for admin user filters with no active folder", async () => {
    const restoreMedia = mockMediaQuery(false)
    const payload = adminUsersPayloadWithSavedFolder(currentAdminUserFilter())
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      ...payload,
      active_smart_folder_id: null,
      smart_folders: payload.smart_folders.map((folder) => ({ ...folder, active: false }))
    }))

    try {
      renderAppAt("/app-shell/admin/users")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Save as new folder" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("keeps an admin user saved folder active when applying filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const url = new URL(String(input), "http://example.test")
      if (url.pathname === "/api/v1/app/admin/users") {
        return Promise.resolve(jsonResponse(adminUsersPayloadFromSearch(url.searchParams)))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${url.pathname}`))
    })

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()

      fireEvent.click(screen.getByRole("button", { name: /GH rate is Low/ }))
      fireEvent.change(screen.getByLabelText("Value"), { target: { value: "exhausted" } })

      await waitFor(() => {
        expect(fetchSpy.mock.calls.some(([path]) => {
          const url = new URL(String(path), "http://example.test")
          return url.pathname === "/api/v1/app/admin/users" && url.searchParams.get("smart_folder_id") === "12" && url.searchParams.has("q")
        })).toBe(true)
      })
      expect(await screen.findByRole("button", { name: "Update Low rate users" })).toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("hides the update button for admin user saved folder matching filters", async () => {
    const restoreMedia = mockMediaQuery(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminUsersPayloadWithSavedFolder(currentAdminUserFilter())))

    try {
      renderAppAt("/app-shell/admin/users?smart_folder_id=12")

      expect(await screen.findByText("No users match these filters.")).toBeInTheDocument()
      fireEvent.click(screen.getByText("Folders and filters"))
      expect(screen.queryByRole("button", { name: "Update Low rate users" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
      restoreMedia()
    }
  })

  it("renders the admin transcript route from the app admin transcript API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          run_id: 4,
          job_id: 1,
          step_kind: "implement",
          workflow_trigger_kind: "initial",
          session_id: "abc-123",
          summary: {
            session_id: "abc-123",
            model: "claude-sonnet-4-6",
            cwd: "/workspace",
            total_turns: 1,
            total_tool_calls: 1,
            total_cost_usd: 0.01,
            exit_reason: "success",
            tool_call_counts: { Bash: 1 },
            mcp_tool_called: false,
            available_tools_at_init: ["Bash"]
          },
          pagination: {
            page: 2,
            per: 1,
            total_events: 3,
            total_pages: 3
          },
          events: [
            {
              kind: "tool_use",
              timestamp: "2026-05-30T12:00:00Z",
              data: { name: "Bash", input: { command: "ls" }, id: "u1" }
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript?page=2&per=1"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin transcript" })).toBeInTheDocument()
    expect(await screen.findByText("Run #4 · transcript")).toBeInTheDocument()
    expect(screen.getByText(/claude-sonnet-4-6/)).toBeInTheDocument()
    expect(screen.getAllByText("Bash").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "back to JOB-1" })).toHaveAttribute("href", "/app-shell/jobs/1")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript?page=3&per=1")
    expect(screen.getByRole("link", { name: "Download JSONL" })).toHaveAttribute("href", "/admin/runs/4/transcript/download")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/runs/4/transcript?page=2&per=1",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("keeps the transcript scrolled to the bottom when new events arrive at the bottom", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(transcriptPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("transcript-event-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 600 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 600 })

    act(() => {
      queryClient.setQueryData(["admin", "transcript", "4", { page: 1, per: 100 }], transcriptPayload({
        totalEvents: 2,
        events: [
          ...transcriptPayload().events,
          {
            kind: "assistant_text",
            timestamp: "2026-05-30T12:01:00Z",
            data: { text: "Fresh transcript event." }
          }
        ]
      }))
    })

    expect(await screen.findByText("Fresh transcript event.")).toBeInTheDocument()
    await waitFor(() => expect(stream.scrollTop).toBe(1200))
    expect(screen.queryByRole("button", { name: "New Messages" })).not.toBeInTheDocument()
  })

  it("shows a new messages button when transcript events arrive away from the bottom", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(transcriptPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("transcript-event-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 200 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1300, clientHeight: 400, scrollTop: 200 })

    act(() => {
      queryClient.setQueryData(["admin", "transcript", "4", { page: 1, per: 100 }], transcriptPayload({
        totalEvents: 3,
        events: [
          ...transcriptPayload().events,
          {
            kind: "assistant_text",
            timestamp: "2026-05-30T12:01:00Z",
            data: { text: "First fresh transcript event." }
          },
          {
            kind: "assistant_text",
            timestamp: "2026-05-30T12:02:00Z",
            data: { text: "Second fresh transcript event." }
          }
        ]
      }))
    })

    const button = await screen.findByRole("button", { name: "New Messages" })
    expect(stream.scrollTop).toBe(200)

    fireEvent.click(button)
    await waitFor(() => expect(stream.scrollTop).toBe(1300))
    expect(screen.queryByRole("button", { name: "New Messages" })).not.toBeInTheDocument()
  })

  it("renders the admin console route from the app admin console API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          settings: {
            polling_paused: false,
            runs_paused: true,
            signups_open: true,
            max_job_failures: 3,
            grade_max_iterations: 2,
            merge_train_enabled: false
          },
          users: [
            { id: 1, email_address: "operator@example.com", display_name: "Operator" }
          ],
          recent_admin_actions: [
            {
              id: 4,
              action: "pause_runs",
              performed_at: "2026-05-30T12:00:00Z",
              user_email: "operator@example.com",
              params: { source: "test" }
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/console"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin console" })).toBeInTheDocument()
    expect(screen.getByText("Operator Console")).toBeInTheDocument()
    expect(await screen.findByText("pause_runs")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Pause polling" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Resume runs" })).toBeInTheDocument()
    const reapButton = screen.getByRole("button", { name: "Reap now" })
    const reapPanel = screen.getByText("Reap stale Runs now").closest("section")
    expect(reapButton).toBeInTheDocument()
    expect(reapButton).toHaveClass("shrink-0")
    expect(reapPanel?.firstElementChild).toHaveClass("flex", "justify-between")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/console",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin installations route from the app admin installations API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          github_app_registered: true,
          github_app_slug: "operator-syrus",
          pat_owner_groups: [
            {
              owner: "globex",
              repository_count: 1,
              install_url: "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&repository_ids[]=201"
            }
          ],
          repositories: [
            {
              id: 2,
              slug: "globex/pat-repo",
              owner: "globex",
              name: "pat-repo",
              owner_user: {
                id: 9,
                email_address: "operator@example.com",
                admin: true
              },
              app_credential_active: false,
              credential_mode: "pat",
              account_login: "globex",
              installation_removed_at: null,
              github_owner_id: 101,
              github_repository_id: 201
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/installations"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin installations" })).toBeInTheDocument()
    expect(screen.getByText("GitHub App Installations")).toBeInTheDocument()
    expect(screen.getByText("Syrus uses the GitHub App for repositories with an active installation. Repositories without one use the owner's personal access token fallback.")).toBeInTheDocument()
    expect(await screen.findByText("globex/pat-repo")).toBeInTheDocument()
    expect(screen.getByText("operator@example.com")).toBeInTheDocument()
    expect(screen.getByText("Used when no active App installation exists")).toBeInTheDocument()
    expect(screen.getByText("No active installation")).toBeInTheDocument()
    expect(screen.getByText("Used as fallback")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Install on all PAT-only repos in this account" })).toHaveAttribute(
      "href",
      "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&repository_ids[]=201"
    )
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/installations",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the GitHub App registration route from the app admin API", async () => {
    const bounceUrl = "http://localhost:3000/admin/github_app/manifest?state=abc123&syrus_external=1"
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          github_app: {
            registered: true,
            id: 12345,
            slug: "operator-syrus",
            registered_at: "2026-05-30T12:00:00Z"
          },
          bounce_url: bounceUrl,
          submit_label: "Re-register GitHub App"
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/github_app/register"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const registration = screen.getByRole("main", { name: "GitHub App registration" })
    expect(registration).toBeInTheDocument()
    expect(within(registration).getByText("Register the singleton Syrus GitHub App. Repositories use App credentials only after the App is installed on their GitHub account or repository.")).toBeInTheDocument()
    expect(await within(registration).findByText("operator-syrus")).toBeInTheDocument()
    expect(within(registration).getByText("GitHub will create the App from the manifest, then redirect back here with temporary credentials. Registration alone does not grant repository access; install the App after registration.")).toBeInTheDocument()
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    fireEvent.click(within(registration).getByRole("button", { name: "Re-register GitHub App" }))
    expect(openSpy).toHaveBeenCalledWith(bounceUrl, "_blank")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/github_app/register",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the GitHub App confirmation route from the app admin API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          github_app: {
            registered: true,
            id: 12345,
            slug: "operator-syrus",
            registered_at: "2026-05-30T12:00:00Z"
          }
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/github_app/confirm"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const confirmation = screen.getByRole("main", { name: "GitHub App registered" })
    expect(confirmation).toBeInTheDocument()
    expect(await within(confirmation).findByText("operator-syrus")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/github_app/confirm",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the invitations route from the app admin invitations API and revokes invitations", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/invitations/9" && init?.method === "DELETE") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              invitations: [],
              message: "Invitation revoked."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            invitations: [
              {
                id: 9,
                email_address: "guest@example.com",
                token: "abc123",
                share_url: "http://example.test/users/new?token=abc123",
                expires_at: "2026-06-06T12:00:00Z",
                created_at: "2026-05-30T12:00:00Z",
                invited_by_email_address: "operator@example.com"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/invitations"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin invitations" })).toBeInTheDocument()
    expect(await screen.findByText("guest@example.com")).toBeInTheDocument()
    expect(screen.getByText("http://example.test/users/new?token=abc123")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }))

    expect(await screen.findByText("Revoke this invitation?")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Yes, revoke" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Yes, revoke" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/invitations/9",
        expect.objectContaining({
          method: "DELETE",
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    })
    expect(await screen.findByText("No pending invitations.")).toBeInTheDocument()
  })

  it("renders the app settings route from the app admin settings API and updates settings", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              settings: { signups_open: true, video_retention_days: 7, video_storage_budget_mb: 2048, clearable_secrets: [] },
              message: "Settings updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            settings: { signups_open: false, video_retention_days: 7, video_storage_budget_mb: 2048, clearable_secrets: [] }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin settings" })).toBeInTheDocument()
    await screen.findByRole("checkbox", { name: /Open signups/ })

    fireEvent.click(screen.getByRole("checkbox", { name: /Open signups/ }))
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            app_setting: { signups_open: true, video_retention_days: 7, video_storage_budget_mb: 2048 }
          })
        })
      )
    })
    expect(await screen.findByText("Settings updated.")).toBeInTheDocument()
  })

  it("renders the tags route from the app tags API and creates tags", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      const palette = [
        { key: "gray", label: "Gray", bg: "#f3f4f6", text: "#374151" },
        { key: "blue", label: "Blue", bg: "#dbeafe", text: "#1d4ed8" },
        { key: "indigo", label: "Indigo", bg: "#e0e7ff", text: "#3730a3" }
      ]

      if (path === "/api/v1/app/tags" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              palette,
              tags: [
                { id: 4, name: "epic:attachments", color: "indigo", jobs_count: 0 }
              ],
              message: "Tag created."
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            palette,
            tags: [
              { id: 2, name: "triage", color: "blue", jobs_count: 3 }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/tags"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Tags" })).toBeInTheDocument()
    expect(await screen.findByText("triage")).toBeInTheDocument()
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveClass("bg-blue-50")
    expect(screen.getByText("3")).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "epic:attachments" } })
    fireEvent.change(screen.getByLabelText("Color"), { target: { value: "indigo" } })
    fireEvent.click(screen.getByRole("button", { name: "Create" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/tags",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            tag: {
              name: "epic:attachments",
              color: "indigo"
            }
          })
        })
      )
    })
    expect(await screen.findByText("Tag created.")).toBeInTheDocument()
    expect(screen.getByText("epic:attachments")).toBeInTheDocument()
  })

  it("renders the cron templates route from the app API and links to detail", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          pr_pileup_policies: ["skip", "pile", "replace"],
          templates: [
            {
              id: 5,
              name: "Weekly dependency bump",
              description: "Keep dependencies moving.",
              cron_expression: "0 9 * * 1",
              pr_pileup_policy: "skip",
              enabled: true,
              applied_tasks_count: 2,
              created_at: "2026-05-30T12:00:00Z",
              updated_at: "2026-05-30T12:00:00Z"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/cron_templates"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Cron templates" })).toBeInTheDocument()
    expect(await screen.findByText("Weekly dependency bump")).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Templates" })).toHaveClass("bg-blue-50")
    expect(screen.getByRole("link", { name: "Weekly dependency bump" })).toHaveAttribute("href", "/app-shell/cron_templates/5")
    expect(screen.getByText("2 repos")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/cron_templates",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders cron template detail with React shell links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          template: {
            id: 5,
            name: "Weekly dependency bump",
            description: "Keep dependencies moving.",
            cron_expression: "0 9 * * 1",
            pr_pileup_policy: "skip",
            enabled: true,
            applied_tasks_count: 1,
            created_at: "2026-05-30T12:00:00Z",
            updated_at: "2026-05-30T12:00:00Z",
            prompt: "Update dependencies once a week."
          },
          pr_pileup_policies: ["skip", "pile", "replace"],
          repositories: [
            {
              id: 3,
              slug: "acme/widgets",
              new_scheduled_task_path: "/repositories/3/scheduled_tasks/new?from_template=5"
            }
          ],
          applied_tasks: [
            {
              id: 12,
              name: "Weekly tests",
              state: "scheduled",
              repository_id: 3,
              repository_slug: "acme/widgets",
              repository_path: "/repositories/3",
              scheduled_task_path: "/scheduled_tasks/12",
              last_fired_at: null
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/cron_templates/5"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Cron template detail" })).toBeInTheDocument()
    expect(await screen.findByText("Weekly dependency bump")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    expect(screen.getByRole("link", { name: "Weekly tests" })).toHaveAttribute("href", "/app-shell/scheduled_tasks/12")
    expect(screen.getAllByRole("link", { name: "acme/widgets" })[0]).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getAllByRole("link", { name: "acme/widgets" })[1]).toHaveAttribute("href", "/app-shell/repositories/3/scheduled_tasks/new?from_template=5")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/cron_templates/5",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders cron help text on the cron template form", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          pr_pileup_policies: ["skip", "pile", "replace"],
          templates: []
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/cron_templates/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "New cron template" })).toBeInTheDocument()
    expect(await screen.findByText("Five fields in UTC: minute hour day-of-month month day-of-week. Examples: 0 9 * * 1 for Mondays at 09:00; 30 14 * * * for every day at 14:30.")).toBeInTheDocument()
  })

  it("renders the scheduled tasks route from the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          active_tasks: [
            {
              id: 12,
              name: "Weekly tests",
              kind: "cron",
              state: "scheduled",
              repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
              schedule_label: "0 9 * * 1",
              last_fired_at: null,
              archived_at: null,
              consecutive_failure_count: 0,
              scheduled_task_path: "/scheduled_tasks/12"
            }
          ],
          fired_one_shots: [],
          archived_tasks: [],
          options: scheduledTaskOptions()
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/scheduled_tasks"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Scheduled tasks" })).toHaveClass("max-w-[96rem]")
    expect(await screen.findByText("Weekly tests")).toBeInTheDocument()
    expect(screen.getByText("0 9 * * 1")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Weekly tests" })).toHaveAttribute("href", "/app-shell/scheduled_tasks/12")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/scheduled_tasks",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders scheduled task detail and pauses the task", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/scheduled_tasks/12/pause" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(scheduledTaskDetailPayload({ state: "paused", message: "Paused." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(scheduledTaskDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/scheduled_tasks/12"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Scheduled task detail" })).toHaveClass("max-w-[96rem]")
    expect(await screen.findByText("Keep tests moving.")).toBeInTheDocument()
    expect(screen.queryByText("Effective cron")).not.toBeInTheDocument()
    expect(screen.getByText("0 9 * * 1")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "#44" })).toHaveAttribute("href", "/app-shell/jobs/44")
    fireEvent.click(screen.getByRole("button", { name: "Pause" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/scheduled_tasks/12/pause",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin"
        })
      )
    })
    expect(await screen.findByText("Paused.")).toBeInTheDocument()
  })

  it("renders the repository scheduled task form and creates a task", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/scheduled_tasks?from_template=9" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(scheduledTaskDetailPayload({ message: "Scheduled task created." })), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/scheduled_tasks/12") {
        return Promise.resolve(new Response(JSON.stringify(scheduledTaskDetailPayload({ message: "Scheduled task created." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            task: {
              id: null,
              name: "Weekly tests",
              kind: "cron",
              cron_expression: "0 9 * * 1",
              fire_at: null,
              pr_pileup_policy: "skip",
              auto_approve_mode: "never",
              prompt: "Keep tests moving.",
              cron_template_id: 9
            },
            repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
            from_template: { id: 9, name: "Template", cron_template_path: "/cron_templates/9" },
            options: scheduledTaskOptions()
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3/scheduled_tasks/new?from_template=9"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "New scheduled task" })).toBeInTheDocument()
    expect(await screen.findByDisplayValue("Weekly tests")).toBeInTheDocument()
    expect(screen.getByText("Five fields in UTC: minute hour day-of-month month day-of-week. Examples: 0 9 * * 1 for Mondays at 09:00; 30 14 * * * for every day at 14:30.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Create task" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/scheduled_tasks?from_template=9",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({
            scheduled_task: {
              name: "Weekly tests",
              prompt: "Keep tests moving.",
              kind: "cron",
              cron_expression: "0 9 * * 1",
              fire_at: "",
              pr_pileup_policy: "skip",
              auto_approve_mode: "never"
            }
          })
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Scheduled task detail" })).toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/scheduled_tasks/12",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
  })

  it("renders the repository scheduled tasks route and disables a task", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/scheduled_tasks/12" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(repositoryScheduledTasksPayload({ state: "paused", active: false, message: "Scheduled task disabled." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryScheduledTasksPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/repositories/3/scheduled_tasks"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const primaryNav = await screen.findByRole("navigation", { name: "Primary" })
      expect(within(primaryNav).getByRole("link", { name: "Repositories" })).toHaveClass("sm:bg-blue-50", "text-blue-700")
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).not.toHaveClass("bg-blue-50")
      expect(await screen.findByRole("main", { name: "Repository scheduled tasks" })).toHaveClass("max-w-[96rem]")
      const scheduledTabs = await screen.findByRole("navigation", { name: "Repository tabs" })
      expect(within(scheduledTabs).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/repositories/3")
      expect(within(scheduledTabs).queryByRole("link", { name: "Context" })).not.toBeInTheDocument()
      expect(within(scheduledTabs).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/repositories/3/documents")
      expect(within(scheduledTabs).getByRole("link", { name: "Scheduled Tasks" })).toHaveClass("border-blue-600")
      expect(screen.getByRole("heading", { level: 1, name: "acme/widgets" })).toHaveClass("text-3xl")
      expect(await screen.findByText("Daily review")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "New scheduled task" })).toHaveAttribute("href", "/app-shell/repositories/3/scheduled_tasks/new")
      fireEvent.click(screen.getByRole("button", { name: "Disable" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/repositories/3/scheduled_tasks/12",
          expect.objectContaining({
            method: "PATCH",
            credentials: "same-origin",
            body: JSON.stringify({ enabled: false })
          })
        )
      })
      expect(await screen.findByText("Scheduled task disabled.")).toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("renders the credentials route as provider cards and connects Claude through the setup flow", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ chatProvider: "codex", chatProviders: ["claude", "codex"] })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/test_claude_cli" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          credential_test: { credential: "claude_oauth_token", ok: false, message: "Claude is not authenticated on this machine yet.", details: {} }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/claude_oauth_start" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/claude_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          credential_test: {
            credential: "claude_oauth_token",
            ok: true,
            message: "Claude OAuth token is valid.",
            details: {}
          }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ chatProviders: ["claude", "codex"] })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Credentials" })).toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Settings tabs" })).not.toBeInTheDocument()
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveClass("bg-blue-50")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "/app-shell/notifications/settings")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).not.toHaveClass("bg-blue-50")

    // One card per provider, replacing the single monolithic form.
    expect(await screen.findByTestId("credential-card-github")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-claude")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-codex")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-gemini")).toBeInTheDocument()
    expect(screen.getByText("A personal access token is the fallback credential for repositories without an active Syrus GitHub App installation. If an admin registers and installs the App on a repository, Syrus uses the App for that repository instead.")).toBeInTheDocument()

    // Saved secrets read as saved — a summary, not an empty password field.
    const claudeCard = screen.getByTestId("credential-card-claude")
    expect(within(claudeCard).getByText("A Claude OAuth token is saved for Syrus runs.")).toBeInTheDocument()

    // Replace opens the same connect flow onboarding uses: preflight,
    // authorize, paste the code.
    fireEvent.click(within(claudeCard).getByRole("button", { name: "Replace" }))
    expect(within(claudeCard).getByLabelText("Authorization code from Claude")).toBeDisabled()
    expect(within(claudeCard).getByText("Paste a long-lived token instead")).toBeInTheDocument()
    expect(within(claudeCard).getByRole("link", { name: "Anthropic authentication docs" })).toHaveAttribute("href", "https://code.claude.com/docs/en/authentication#generate-a-long-lived-token")
    fireEvent.click(within(claudeCard).getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(openSpy).toHaveBeenCalledWith("https://claude.ai/oauth/authorize?state=abc", "_blank"))
    await waitFor(() => expect(within(claudeCard).getByLabelText("Authorization code from Claude")).toBeEnabled())
    fireEvent.change(within(claudeCard).getByLabelText("Authorization code from Claude"), { target: { value: "auth-code#state" } })
    fireEvent.click(within(claudeCard).getByRole("button", { name: "Connect" }))
    await waitFor(() => expect(screen.getAllByText("Claude OAuth token is valid.").length).toBeGreaterThan(0))
    const exchangeCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials/claude_oauth_exchange")
    expect(JSON.parse(String(exchangeCall?.[1]?.body))).toEqual({ code: "auth-code#state" })

    // The Codex auth-mode select lives inside its card; the chat provider
    // saves immediately as a partial PATCH — there is no global Save.
    expect(screen.getByLabelText("Codex authentication")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Chat provider"), { target: { value: "codex" } })
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ user: { chat_provider: "codex" } })
        })
      )
    })
    expect(await screen.findByText("Chat provider saved.")).toBeInTheDocument()

    expect(screen.queryByLabelText("Display name")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Max turns")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Pause scheduling")).not.toBeInTheDocument()
    expect(screen.queryByText("Personal documents")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Google Doc URL")).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Notifications" })).not.toBeInTheDocument()
  })

  it("renders notification settings as a sibling settings route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload({ job_failed: false, message: "Notification preferences updated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/notifications/settings"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Notification settings" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Notifications" })).toBeInTheDocument()
    expect(screen.queryByRole("main", { name: "Credentials" })).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/credentials", expect.anything())
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveClass("bg-blue-50")
    expect(screen.getByRole("group", { name: "Desktop Notifications" })).toBeInTheDocument()
    const jobFailedToggle = await screen.findByLabelText("Notify me when a job fails")
    expect(jobFailedToggle).toBeChecked()
    fireEvent.click(jobFailedToggle)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/notification_preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ notification_preferences: { job_failed: false } })
        })
      )
    })
    const desktopReadyToggle = screen.getByLabelText("Job ready for review")
    expect(desktopReadyToggle).toBeChecked()
    expect(screen.getByLabelText("Job failed")).toBeChecked()
    fireEvent.click(desktopReadyToggle)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/notification_preferences",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({ notification_preferences: { desktop_job_implemented: false } })
        })
      )
    })
    expect(await screen.findByText("Notification preferences updated.")).toBeInTheDocument()
  })

  it("tests a credential from the credentials route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/test_credential" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          credential_test: {
            credential: "github_token",
            ok: true,
            message: "GitHub token is valid for ada.",
            details: {
              login: "ada",
              scopes: ["repo", "workflow"]
            }
          },
          message: "GitHub token is valid for ada."
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Credentials" })).toBeInTheDocument()
    const githubCard = await screen.findByTestId("credential-card-github")
    fireEvent.click(within(githubCard).getByRole("button", { name: "Test" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/test_credential",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ credential: "github_token" })
        })
      )
    })
    expect((await screen.findAllByText(/GitHub token is valid for ada/)).length).toBeGreaterThan(0)
    expect(within(githubCard).getByText(/@ada · scopes: repo, workflow/)).toBeInTheDocument()
  })

  it("authorizes Codex ChatGPT login from the Codex card", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/codex_oauth_start" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/codex_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          credential_test: {
            credential: "codex_auth_json",
            ok: true,
            message: "Codex ChatGPT auth.json is valid.",
            details: {}
          },
          message: "Codex ChatGPT auth.json is valid."
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ codexAuthMode: "chatgpt_login" })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Credentials" })).toBeInTheDocument()
    const codexCard = await screen.findByTestId("credential-card-codex")
    expect(within(codexCard).getByLabelText("Codex authentication")).toHaveValue("chatgpt_login")
    fireEvent.click(within(codexCard).getByRole("button", { name: "Authorize with ChatGPT" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/codex_oauth_start",
        expect.objectContaining({ method: "POST", credentials: "same-origin" })
      )
    })
    expect(openSpy).toHaveBeenCalledWith("https://auth.openai.com/oauth/authorize?state=abc", "_blank")
    expect(within(codexCard).getByText("Paste auth.json manually")).toBeInTheDocument()

    fireEvent.change(within(codexCard).getByLabelText("ChatGPT authorization code"), { target: { value: "code#abc" } })
    fireEvent.click(within(codexCard).getByRole("button", { name: "Connect" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/codex_oauth_exchange",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ code: "code#abc" })
        })
      )
    })
    expect((await screen.findAllByText("Codex ChatGPT auth.json is valid.")).length).toBeGreaterThan(0)
  })

  it("automatically exchanges Codex OAuth callbacks received over ActionCable", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/codex_oauth_start" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/codex_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          credential_test: {
            credential: "codex_auth_json",
            ok: true,
            message: "Codex ChatGPT auth.json is valid.",
            details: {}
          },
          message: "Codex ChatGPT auth.json is valid."
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ codexAuthMode: "chatgpt_login" })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Credentials" })).toBeInTheDocument()
    const codexCard = await screen.findByTestId("credential-card-codex")
    fireEvent.click(within(codexCard).getByRole("button", { name: "Authorize with ChatGPT" }))

    await waitFor(() => {
      expect(openSpy).toHaveBeenCalledWith("https://auth.openai.com/oauth/authorize?state=abc", "_blank")
      expect(actionCable.createSubscription.mock.calls.length).toBeGreaterThan(1)
    })

    const callbacks = (actionCable.createSubscription.mock.calls as unknown[][])
      .map((call) => (call[1] as { received?: unknown } | undefined)?.received)
      .filter((received): received is (data: unknown) => void => typeof received === "function")
    callbacks.forEach((received) => received({
      type: "codex_oauth.callback",
      resource: "credential",
      payload: { code: "http://localhost:1455/auth/callback?code=auto-code&state=abc" }
    }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/codex_oauth_exchange",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ code: "http://localhost:1455/auth/callback?code=auto-code&state=abc" })
        })
      )
    })
    expect((await screen.findAllByText("Codex ChatGPT auth.json is valid.")).length).toBeGreaterThan(0)
  })

  it("renders /settings as the profile route without admin links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Profile" })).toBeInTheDocument()
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveAttribute("href", "/app-shell/profile")
    expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveClass("bg-blue-50")
    expect(await screen.findByLabelText("Display name")).toBeInTheDocument()
    expect(screen.queryByLabelText("GitHub personal access token")).not.toBeInTheDocument()
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "/app-shell/notifications/settings")
    expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveAttribute("href", "/app-shell/settings/hidden_chats")
    expect(within(settingsNav).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/documents")
    expect(within(settingsNav).getByRole("link", { name: "Templates" })).toHaveAttribute("href", "/app-shell/cron_templates")
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveAttribute("href", "/app-shell/tags")
    expect(screen.queryByRole("link", { name: "Invitations" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "App settings" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credentials", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("renders and saves the agent settings route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ agentProvider: "codex", message: "Credentials updated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings/agent"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Agent Settings" })).toBeInTheDocument()
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Agent Settings" })).toHaveClass("bg-blue-50")
    expect(screen.queryByLabelText("GitHub personal access token")).not.toBeInTheDocument()
    fireEvent.change(await screen.findByLabelText("Agent provider"), { target: { value: "codex" } })
    fireEvent.change(screen.getByLabelText("Max turns"), { target: { value: "42" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(expect.objectContaining({
        agent_provider: "codex",
        agent_max_turns: 42
      }))
    })
  })

  it("renders and saves the preferences route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ schedulingPaused: true, message: "Credentials updated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings/preferences"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Preferences" })).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Preferences" })).toHaveClass("bg-blue-50")
    expect(screen.queryByLabelText("Agent provider")).not.toBeInTheDocument()
    const pauseScheduling = await screen.findByLabelText("Pause scheduling")
    expect(screen.queryByRole("group", { name: "Desktop Notifications" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Job ready for review")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Job failed")).not.toBeInTheDocument()
    fireEvent.click(pauseScheduling)
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(expect.objectContaining({
        scheduling_paused: true
      }))
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).not.toHaveProperty("notification_preferences")
    })
  })

  it("renders a teammate profile from the profile API without credential details", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(profilePayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/profiles/2"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Ada Lovelace" })).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Team profile" })).toBeInTheDocument()
    expect(screen.getByText("@ada-lovelace")).toBeInTheDocument()
    expect(screen.getByText("Mathematician and operator.")).toBeInTheDocument()
    expect(screen.getByText("Add profile page")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Add profile page" })).toHaveAttribute("href", "/app-shell/jobs/55")
    expect(screen.getByRole("link", { name: "@ada-lovelace" })).toHaveAttribute("href", "https://github.com/ada-lovelace")
    expect(within(screen.getByRole("heading", { name: "Ada Lovelace" })).getByRole("link", { name: "Ada Lovelace" })).toHaveAttribute("href", "/app-shell/profiles/2")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getAllByText("acme/widgets").length).toBeGreaterThan(0)
    expect(screen.queryByText("GitHub token")).not.toBeInTheDocument()
    expect(screen.queryByText("ada@example.com")).not.toBeInTheDocument()
    expect(screen.queryByText("sk-profile-secret")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/profiles/2", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("renders useful empty states for profiles with no public details or work", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(profilePayload({
        github_handle: null,
        profile_bio: null,
        profile_company: null,
        profile_location: null,
        profile_website: null,
        counts: { repositories: 0, epics: 0, jobs: 0, open_jobs: 0 },
        repositories: [],
        epics: [],
        jobs: [],
        recent_activity: []
      })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/profiles/3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Ada Lovelace" })).toBeInTheDocument()
    expect(screen.queryByText("@ada-lovelace")).not.toBeInTheDocument()
    expect(screen.queryByText("Mathematician and operator.")).not.toBeInTheDocument()
    expect(screen.getByText("No active epics.")).toBeInTheDocument()
    expect(screen.getByText("No jobs.")).toBeInTheDocument()
    expect(screen.getByText("No active repositories.")).toBeInTheDocument()
    expect(screen.getByText("No activity yet.")).toBeInTheDocument()
  })

  it("rotates an admin API token from the credentials route", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/rotate_api_token" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ apiToken: true, newApiToken: "syrus_newtoken", message: "API token rotated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ apiToken: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Rotate token" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Rotate token" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/rotate_api_token",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin"
        })
      )
    })
    expect(await screen.findByText("syrus_newtoken")).toBeInTheDocument()
  })

  it("uploads a personal document from the documents settings route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/credentials/documents" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(personalDocumentsPayload({ documents: [{ id: 8, kind: "google_doc", google_doc_url: "https://docs.google.com/document/d/user/edit", filename: null, content_type: null, byte_size: null, created_at: "2026-05-30T12:00:00Z" }], message: "Document added." })), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(personalDocumentsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/documents"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Personal documents" })).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Documents" })).toHaveClass("bg-blue-50")
    fireEvent.change(await screen.findByLabelText("Google Doc URL"), { target: { value: "https://docs.google.com/document/d/user/edit" } })
    fireEvent.click(screen.getByRole("button", { name: "Add document" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/documents",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.any(FormData)
        })
      )
    })
    expect(await screen.findByText("Document added.")).toBeInTheDocument()
    expect(screen.getByText("https://docs.google.com/document/d/user/edit")).toBeInTheDocument()
  })

  it("renders repository documents and adds a Google Doc", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/documents" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(repositoryDocumentsPayload({
          documents: [
            {
              id: 9,
              kind: "google_doc",
              title: "Design brief",
              google_doc_url: "https://docs.google.com/document/d/design/edit",
              filename: null,
              content_type: null,
              byte_size: null,
              uploaded_by: "Operator",
              created_at: "2026-05-30T12:00:00Z"
            }
          ],
          message: "Document added."
        })), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryDocumentsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3/documents"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Repository documents" })).toHaveClass("max-w-[96rem]")
    expect(await screen.findByRole("heading", { level: 1, name: "acme/widgets" })).toHaveClass("text-3xl")
    const repositoryTabs = await screen.findByRole("navigation", { name: "Repository tabs" })
    expect(within(repositoryTabs).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(within(repositoryTabs).getByRole("link", { name: "GitHub Issues" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=github_issues")
    expect(within(repositoryTabs).queryByRole("link", { name: "Context" })).not.toBeInTheDocument()
    expect(within(repositoryTabs).getByRole("link", { name: "Documents" })).toHaveClass("border-blue-600")
    expect(within(repositoryTabs).getByRole("link", { name: "Scheduled Tasks" })).toHaveAttribute("href", "/app-shell/repositories/3/scheduled_tasks")
    const description = screen.getByText("Supporting documents available to agent runs for this repository.")
    expect(Boolean(repositoryTabs.compareDocumentPosition(description) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(await screen.findByText("No supporting documents yet. Upload a file or link a Google Doc to give the agent extra context.")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("URL"), { target: { value: "https://docs.google.com/document/d/design/edit" } })
    fireEvent.change(screen.getByLabelText("Document title"), { target: { value: "Design brief" } })
    fireEvent.click(screen.getByRole("button", { name: "Add Google Doc" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/documents",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.any(FormData)
        })
      )
    })
    expect(await screen.findByText("Document added.")).toBeInTheDocument()
    expect(screen.getByText("Design brief")).toBeInTheDocument()
  })

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
    expect(screen.getByRole("heading", { name: "New direct job" })).toHaveClass("dark:text-gray-100")
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
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...directJobFormPayload(),
        repositories: [],
        selected_repository_id: null
      }), { status: 200, headers: { "Content-Type": "application/json" } })
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
        return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
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
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
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

  it("renders repositories and polls one from the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/poll" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(repositoriesPayload({ message: "Polling acme/widgets now." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoriesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Repositories" })).toHaveClass("max-w-[96rem]")
    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Working repository" })).toBeInTheDocument()
    expect(screen.getByText("rails/rails")).toBeInTheDocument()
    expect(screen.getByText("old/repo")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Add" })).toHaveAttribute("href", "/app-shell/repositories/new")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/repositories/3/edit")
    fireEvent.click(screen.getByRole("button", { name: "Poll now" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/poll",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin"
        })
      )
    })
    expect(await screen.findByText("Polling acme/widgets now.")).toBeInTheDocument()
  })

  it("points an empty repositories index to the setup next action", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({ setupStatus: bootstrapSetupStatusPayload({ nextStep: "configure_credentials" }) }))
    document.body.appendChild(script)
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({
        ...repositoriesPayload(),
        active_repositories: [],
        archived_repositories: []
      }), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/repositories"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("heading", { name: "Connect credentials first" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Open credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    } finally {
      script.remove()
    }
  })

  it("renders the repository form with GitHub selectors and submits it to the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories" && init?.method === "POST") {
        return Promise.resolve(new Response(
          JSON.stringify({ error: { code: "validation_failed", message: "Owner has already been taken" } }),
          { status: 422, headers: { "Content-Type": "application/json" } }
        ))
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ user: "acme", orgs: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/repos?owner=acme&owner_type=user") {
        return Promise.resolve(new Response(JSON.stringify({
          repos: [
            { name: "widgets", github_repository_id: 456, github_owner_id: 123 }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/branches?owner=acme&name=widgets") {
        return Promise.resolve(new Response(JSON.stringify({ branches: ["trunk", "main"], default_branch: "trunk" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Add Repository" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Working repository" })).toBeInTheDocument()
    expect(screen.getByText("Syrus polls issues, creates branches, and opens PRs in this repository.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Upstream repository" })).toBeInTheDocument()
    expect(screen.getByText("Optional reference repo for fork context. Syrus still opens PRs in the working repository.")).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/repositories")
    expect(await screen.findByRole("option", { name: "acme" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Working owner"), { target: { value: "acme" } })
    expect(await screen.findByRole("option", { name: "widgets" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Working name"), { target: { value: "widgets" } })
    expect(await screen.findByRole("option", { name: "trunk" })).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Default branch"), { target: { value: "trunk" } })
    fireEvent.change(screen.getByLabelText("Upstream owner"), { target: { value: "rails" } })
    fireEvent.change(screen.getByLabelText("Upstream name"), { target: { value: "rails" } })
    fireEvent.change(screen.getByLabelText("Upstream default branch"), { target: { value: "main" } })
    fireEvent.change(screen.getByLabelText("Default agent"), { target: { value: "codex" } })
    fireEvent.change(screen.getByLabelText("Auto-approval fallback"), { target: { value: "if_graders_pass" } })
    fireEvent.click(screen.getByLabelText("Run prepare step on this repository's Workflows"))
    fireEvent.click(screen.getByLabelText("Auto-merge approved Syrus PRs"))
    fireEvent.click(screen.getByRole("button", { name: "Create Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({
            repository: {
              owner: "acme",
              name: "widgets",
              default_branch: "trunk",
              upstream_owner: "rails",
              upstream_name: "rails",
              upstream_default_branch: "main",
              trigger_label: "syrus",
              polling_enabled: true,
              prepare_enabled: false,
              pr_cost_footer_enabled: true,
              auto_merge_enabled: true,
              trust_clean_rebase_grade: false,
              agent_provider: "codex",
              auto_approve_mode: "if_graders_pass",
              github_owner_id: "123",
              github_repository_id: "456"
            }
          })
        })
      )
    })
    expect(await screen.findByText("Owner has already been taken")).toBeInTheDocument()
  })

  it("creates a repository and navigates within the React shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          message: "Repository created.",
          redirect_to: "/repositories/3",
          repository: {
            id: 3,
            slug: "acme/widgets",
            owner: "acme",
            name: "widgets",
            default_branch: "main",
            upstream_owner: null,
            upstream_name: null,
            upstream_default_branch: null,
            upstream_slug: null,
            trigger_label: "syrus",
            polling_enabled: true,
            archived: false,
            archived_at: null,
            agent_provider: "codex",
            agent_provider_label: "Codex",
            last_poll_status: null,
            last_poll_started_at: null,
            last_poll_error: null,
            repository_path: "/repositories/3",
            edit_repository_path: "/repositories/3/edit"
          }
        }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/3") {
        return Promise.resolve(new Response(JSON.stringify({
          ...repositoryDetailPayload(),
          message: "Repository created."
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ error: "no_token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByLabelText("Working owner"), { target: { value: "acme" } })
    fireEvent.change(screen.getByLabelText("Working name"), { target: { value: "widgets" } })
    fireEvent.click(screen.getByRole("button", { name: "Create Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.stringContaining('"owner":"acme"')
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Repository" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/repositories/3",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders the edit repository form and patches repository settings", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3" && init?.method === "PATCH") {
        return Promise.resolve(new Response(
          JSON.stringify({ error: { code: "validation_failed", message: "Trigger label can't be blank" } }),
          { status: 422, headers: { "Content-Type": "application/json" } }
        ))
      }
      if (path === "/api/v1/app/repositories/owners") {
        return Promise.resolve(new Response(JSON.stringify({ error: "no_token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryFormPayload({
        repository: {
          id: 3,
          owner: "acme",
          name: "widgets",
          slug: "acme/widgets",
          default_branch: "main",
          upstream_owner: "",
          upstream_name: "",
          upstream_default_branch: "",
          trigger_label: "syrus",
          polling_enabled: true,
          prepare_enabled: true,
          pr_cost_footer_enabled: true,
          auto_merge_enabled: false,
          trust_clean_rebase_grade: false,
          agent_provider: "",
          auto_approve_mode: "never",
          github_owner_id: null,
          github_repository_id: null,
          repository_path: "/repositories/3"
        }
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Edit Repository" })).toBeInTheDocument()
    expect(await screen.findByDisplayValue("acme")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Back to repository" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/repositories")
    fireEvent.change(screen.getByLabelText("Trigger label"), { target: { value: "delegate" } })
    fireEvent.click(screen.getByRole("button", { name: "Save Repository" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: expect.stringContaining('"trigger_label":"delegate"')
        })
      )
    })
    expect(await screen.findByText("Trigger label can't be blank")).toBeInTheDocument()
  })

  it("renders a repository detail overview from the app API", async () => {
    const basePayload = repositoryDetailPayload()
    const detailPayload = {
      ...basePayload,
      pagination: {
        ...basePayload.pagination,
        total_jobs: 25,
        total_pages: 2,
        next_path: "/repositories/3?page=2"
      }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(detailPayload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Repository" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "https://github.com/acme/widgets")
    expect(screen.getByText("polling enabled")).toBeInTheDocument()
    expect(screen.getByText("Working repo")).toBeInTheDocument()
    expect(screen.getByText("Upstream repo")).toBeInTheDocument()
    expect(screen.getByText("rails/rails:main")).toBeInTheDocument()
    expect(screen.queryByText("Repository context pinned.")).not.toBeInTheDocument()
    expect(screen.getByText("Fix forum")).toBeInTheDocument()
    expect(screen.getByText("Retry 1 failed with Codex")).toBeInTheDocument()
    expect(screen.getByText("Install Syrus App")).toHaveAttribute("href", "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&repository_ids[]=200")
    expect(screen.getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "GitHub Issues" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=github_issues")
    expect(screen.queryByRole("link", { name: "Context" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/repositories/3/documents")
    expect(screen.getByRole("link", { name: "Scheduled Tasks" })).toHaveAttribute("href", "/app-shell/repositories/3/scheduled_tasks")
    expect(screen.getByRole("link", { name: "New job" })).toHaveAttribute("href", "/app-shell/jobs/new?repository_id=3")
    const moreButton = screen.getByRole("button", { name: "More" })
    fireEvent.click(moreButton)
    expect(moreButton).toHaveAttribute("aria-expanded", "true")
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/repositories/3/edit")
    fireEvent.keyDown(window, { key: "Escape" })
    expect(moreButton).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByRole("link", { name: "Edit" })).not.toBeInTheDocument()
    fireEvent.click(moreButton)
    expect(screen.getByRole("link", { name: "Edit" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(moreButton).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByRole("link", { name: "Edit" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Fix forum" })).toHaveAttribute("href", "/app-shell/jobs/44")
    expect(screen.getByRole("link", { name: "View" })).toHaveAttribute("href", "/app-shell/jobs/44")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/repositories/3?page=2")
    expect(screen.getByText("1 running")).toBeInTheDocument()
    expect(screen.getByText("1 queued")).toBeInTheDocument()
    expect(screen.getByText("1 failed 7d")).toBeInTheDocument()
  })

  it("runs repository detail commands through the app API", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/poll" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...repositoryDetailPayload(),
          message: "Polling acme/widgets now."
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === "/api/v1/app/repositories/3/retry_failed_jobs" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...repositoryDetailPayload(),
          message: "Retry enqueued for 1 failed job with Codex.",
          retry_failed_jobs: {
            count: 0,
            agent_provider: "codex",
            agent_provider_label: "Codex",
            provider_circuit: closedProviderCircuit("codex")
          }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === "/api/v1/app/repositories/3/archive" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(repositoriesPayload({ message: "acme/widgets archived." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === "/api/v1/app/repositories") {
        return Promise.resolve(new Response(JSON.stringify(repositoriesPayload({ message: "acme/widgets archived." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Poll now" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/poll",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ return_to: "detail", page: 1 })
        })
      )
    })
    expect(await screen.findByText("Polling acme/widgets now.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Retry 1 failed with Codex" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/retry_failed_jobs",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ page: 1 })
        })
      )
    })
    expect(await screen.findByText("Retry enqueued for 1 failed job with Codex.")).toBeInTheDocument()

    fireEvent.click(screen.getByText("More"))
    fireEvent.click(screen.getByRole("button", { name: "Archive" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/archive",
        expect.objectContaining({ method: "POST", credentials: "same-origin" })
      )
    })
    expect(await screen.findByRole("main", { name: "Repositories" })).toBeInTheDocument()
  })

  it("renders repository GitHub issues and delegates one through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/issues/delegate" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(repositoryIssuesPayload({
          message: "Issue #7 delegated to Syrus.",
          delegated: true
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryIssuesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3?tab=github_issues&state=open"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Repository" })).toBeInTheDocument()
    expect(await screen.findByText("Fix the forum")).toBeInTheDocument()
    expect(screen.getByText("Trigger label:")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "View on GitHub" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues")
    expect(screen.getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "GitHub Issues" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=github_issues")
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=github_issues&state=open")
    expect(screen.getByRole("link", { name: "Closed" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=github_issues&state=closed")
    fireEvent.click(screen.getByRole("button", { name: "Delegate" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/issues/delegate",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ issue_number: 7, state: "open" })
        })
      )
    })
    expect(await screen.findByText("Issue #7 delegated to Syrus.")).toBeInTheDocument()
    expect(screen.getByText("Delegated")).toBeInTheDocument()
  })

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
        return Promise.resolve(new Response(JSON.stringify({
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
        }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/epics/7") {
        return Promise.resolve(new Response(JSON.stringify(epicDetailPayload({
          message: "Epic created."
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
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
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/epics/7",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders the edit Epic form with React shell links", async () => {
    const basePayload = epicFormPayload()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...basePayload,
        epic: {
          ...basePayload.epic,
          id: 7,
          title: "Raise the forum",
          repository_id: 3,
          epic_path: "/epics/7"
        }
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Edit Epic" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Edit Epic" })).toHaveClass("dark:text-gray-100")
    expect(screen.getByLabelText("Title")).toHaveClass("dark:bg-gray-950", "dark:text-gray-100")
    expect(await screen.findByRole("link", { name: "Back to Epic" })).toHaveAttribute("href", "/app-shell/epics/7")
    expect(screen.getByRole("link", { name: "Cancel" })).toHaveAttribute("href", "/app-shell/epics/7")
  })

  it("renders an Epic detail page and updates state through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/state" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(epicDetailPayload({
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
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(epicDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Epic" })).toBeInTheDocument()
    expect(await screen.findByText("EPIC-7")).toBeInTheDocument()
    expect(screen.getByText("Raise the forum")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: /EPIC-7/ })).toHaveClass("dark:text-gray-100")
    expect(screen.queryByRole("link", { name: "Back to Epics" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/epics/7/edit")
    expect(screen.getAllByRole("link", { name: "acme/widgets" }).every((el) => el.getAttribute("href") === "/app-shell/repositories/3")).toBe(true)
    expect(screen.getByRole("link", { name: "Survey forum" })).toHaveAttribute("href", "/app-shell/jobs/42")
    fireEvent.click(screen.getByRole("button", { name: "More actions" }))
    expect(screen.getByRole("menuitem", { name: "Move to backlog" })).toBeInTheDocument()
    expect(screen.getByText("columns")).toBeInTheDocument()
    expect(screen.getByText("(1 epic dep, 0 job blockers)")).toBeInTheDocument()
    expect(await screen.findByRole("img", { name: "Dependency graph" })).toBeInTheDocument()
    expect(screen.getByText("Dependency graph").closest("details")).toHaveClass("dark:bg-gray-900", "dark:border-gray-700")
    expect(document.querySelector("[data-controller='mermaid-graph']")).toBeNull()
    expect(screen.getByText("Survey forum")).toBeInTheDocument()
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

    expect(await screen.findByRole("heading", { name: "Dependencies" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Deliver marble" })).toHaveAttribute("href", "/app-shell/epics/6")
    expect(screen.getByText("Done")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Polish search UI" })).toHaveAttribute("href", "/app-shell/epics/8")

    fireEvent.click(screen.getByRole("button", { name: "Remove dependency on Deliver marble" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/dependencies/6",
        expect.objectContaining({ method: "DELETE", credentials: "same-origin" })
      )
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
        const options = query === "Cycle"
          ? [{ value: 10, label: "Cycle dependency" }]
          : query === "Index"
            ? [{ value: 9, label: "Index chat transcripts" }]
            : []
        return Promise.resolve(new Response(JSON.stringify({ options }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/epics/7/dependencies" && init?.method === "POST") {
        if (init.body === JSON.stringify({ depends_on_epic_id: 10 })) {
          return Promise.resolve(new Response(JSON.stringify({ error: { code: "validation_failed", message: "Depends on epic would create a cycle" } }), { status: 422, headers: { "Content-Type": "application/json" } }))
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

    await waitFor(() => expect(screen.getAllByText("None")).toHaveLength(2))

    fireEvent.change(screen.getByLabelText("Add dependency"), { target: { value: "Cycle" } })
    fireEvent.click(await screen.findByRole("button", { name: "Cycle dependency" }))
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Depends on epic would create a cycle")

    fireEvent.change(screen.getByLabelText("Add dependency"), { target: { value: "Index" } })
    fireEvent.click(await screen.findByRole("button", { name: "Index chat transcripts" }))
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/filters/fk_options?field=epic_id&q=Index",
        expect.objectContaining({ credentials: "same-origin" })
      )
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

  it("initializes the Epic dependency graph with Mermaid dark theme when dark mode is active", async () => {
    document.documentElement.classList.add("dark")
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(epicDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/epics/7"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("img", { name: "Dependency graph" })).toBeInTheDocument()
    expect(mermaidMock.initialize).toHaveBeenLastCalledWith(expect.objectContaining({ theme: "dark" }))
  })

  it("claims and unclaims an Epic from the detail controls", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/epics/7/claim" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(epicDetailPayload({
          message: "Epic claimed.",
          epic: {
            owner_user_id: 1,
            owner_status: "mine",
            owner_user: { id: 1, email_address: "operator@example.com" },
            owned_by_current_user: true
          },
          jobs: [
            {
              id: 42,
              label: "#12",
              title: "Survey forum",
              path: "/jobs/42",
              state: "closed",
              owner_user_id: 1,
              owner_user: { id: 1, email_address: "operator@example.com" },
              repository_slug: "acme/widgets"
            }
          ]
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/epics/7/unclaim" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(epicDetailPayload({
          message: "Epic unclaimed."
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(epicDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
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
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/claim",
        expect.objectContaining({ method: "PATCH", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Epic claimed.")).toBeInTheDocument()
    expect(screen.getByText(/Owner operator@example\.com/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Claim" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Unclaim" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Unclaim" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/epics/7/unclaim",
        expect.objectContaining({ method: "PATCH", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Epic unclaimed.")).toBeInTheDocument()
    expect(screen.getAllByText(/Unclaimed/).length).toBeGreaterThan(0)
  })

  it("does not show claim controls for an Epic owned by another user", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(epicDetailPayload({
      epic: {
        owner_user_id: 2,
        owner_status: "other_owned",
        owner_user: { id: 2, email_address: "teammate@example.com" },
        owned_by_current_user: false
      }
    })), { status: 200, headers: { "Content-Type": "application/json" } }))

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

  it("renders a Job detail page and runs commands through the app API", async () => {
    const payload = jobDetailPayload({
      landing_queue_entry: {
        position: 1,
        blocked_reason: "waiting for epic siblings to be approved",
        waiting_for_jobs: [
          { id: 43, label: "#43", title: "Approve sibling aqueduct", job_path: "/jobs/43" }
        ]
      },
      dependencies: [
        {
          id: 13,
          source: "parsed",
          manual: false,
          pending: false,
          succeeded: true,
          unresolved_slug: null,
          depends_on_job: {
            id: 44,
            kind: "issue",
            state: "closed",
            summary_state: "closed",
            repository_slug: "acme/widgets",
            issue_number: 84,
            issue_title: "Polish the dependency",
            branch_name: "syrus/issue-84",
            pr_number: 101,
            job_path: "/jobs/44"
          }
        }
      ],
      dependents: [
        {
          id: 12,
          source: "manual",
          job: {
            id: 41,
            kind: "issue",
            state: "open",
            summary_state: "implemented",
            repository_slug: "acme/widgets",
            issue_number: 11,
            issue_title: "Build hill",
            branch_name: "syrus/issue-11",
            pr_number: 76,
            job_path: "/jobs/41"
          }
        }
      ]
    })
    const gradeStep = payload.workflows[0].steps[0] as { kind: string; display_name: string; details: unknown; runs: Array<{ app_grade_log_path: string | null }> }
    gradeStep.kind = "grader"
    gradeStep.display_name = "tests"
    gradeStep.details = { name: "tests", command: "bin/rspec" }
    gradeStep.runs[0].app_grade_log_path = "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5"
    const clipboardWrite = mockClipboardWrite()
    let artifactFetchCount = 0
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/claim" && init?.method === "POST") {
        Object.assign(payload.job as Record<string, unknown>, {
          claimed_by_user: { id: 2, display_name: "Ada Lovelace", profile_path: "/profiles/2" },
          claimed_at: "2026-06-03T05:50:00Z",
          claimed_by_current_user: true
        })
        Object.assign(payload.actions as Record<string, unknown>, { can_claim: false, can_unclaim: true })
        return Promise.resolve(new Response(JSON.stringify({ message: "Job claimed.", job: payload.job }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/poll_feedback" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Checking PR feedback now..." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5") {
        return Promise.resolve(new Response(JSON.stringify({ job_id: 42, run_id: 9, name: "tests", contents: "rspec output\n" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts") {
        artifactFetchCount += 1
        return Promise.resolve(new Response(JSON.stringify({
          job_id: 42,
          run_id: 9,
          agent_diff: "diff --git a/app.rb b/app.rb\nindex 1111111..2222222 100644\n--- a/app.rb\n+++ b/app.rb\n@@ -1,2 +1,2 @@\n-puts 'old forum'\n+puts 'forum'\n context\n",
          agent_diff_bytes: 140,
          logs_count: artifactFetchCount > 1 ? 3 : 2,
          logs: [
            { id: 1, sequence: 0, kind: "assistant_text", chunk: "digging trench", created_at: "2026-05-30T10:02:00Z" },
            { id: 2, sequence: 1, kind: "tool_call", chunk: "found marble", created_at: "2026-05-30T10:03:00Z" },
            ...(artifactFetchCount > 1 ? [{ id: 3, sequence: 2, kind: "system", chunk: "new marble", created_at: "2026-05-30T10:04:00Z" }] : [])
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Job" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { level: 1, name: /Repair aqueduct/ })).toHaveClass("dark:text-gray-100")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/12")
    expect(screen.getByRole("link", { name: "#12" })).toHaveAttribute("target", "_blank")
    const copySlugButton = screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })
    expect(copySlugButton).toHaveTextContent("JOB-42")
    fireEvent.click(copySlugButton)
    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("JOB-42"))
    expect(screen.getByRole("link", { name: "acme/widgets JOB-41" })).toHaveAttribute("href", "/app-shell/jobs/41")
    expect(screen.getByText("Water should climb the hill.")).toBeInTheDocument()
    expect(screen.getByText("Moved the uphill water simulation.")).toBeInTheDocument()
    expect(screen.getByText(/In landing queue: position #1/)).toHaveTextContent("waiting for epic siblings to be approved")
    expect(screen.getByRole("link", { name: "#43 Approve sibling aqueduct" })).toHaveAttribute("href", "/app-shell/jobs/43")
    expect(screen.getByRole("link", { name: "acme/widgets JOB-44 (closed)" })).toHaveAttribute("href", "/app-shell/jobs/44")
    expect(screen.queryByRole("button", { name: /^Timeline/ })).not.toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Add tag")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add tag" })).toBeInTheDocument()
    expect(screen.getByText("Unclaimed")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Claim" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/claim",
        expect.objectContaining({ method: "POST", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Job claimed.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "⋯" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Check feedback" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/poll_feedback",
        expect.objectContaining({ method: "POST", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Checking PR feedback now...")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Workflows (1)" }))
    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    expect(screen.getByText("WF-5").closest("section")).toHaveClass("dark:bg-gray-900", "dark:border-gray-700")
    fireEvent.click(screen.getByRole("button", { name: /Grade/i }))
    fireEvent.click(screen.getByRole("button", { name: /tests/i }))
    expect(screen.getByText("Run #9")).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Add tag")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Transcript" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/runs/9/artifacts",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
    expect(await screen.findByText("digging trench")).toBeInTheDocument()
    expect(screen.getByText("Agent")).toBeInTheDocument()
    expect(screen.getByTestId("run-transcript-log-stream")).toHaveClass("dark:divide-gray-800")
    expect(screen.getByText("Tool")).toBeInTheDocument()
    expect(screen.queryByText("assistant_text")).not.toBeInTheDocument()
    expect(screen.queryByText("tool_call")).not.toBeInTheDocument()
    const transcriptStream = screen.getByTestId("run-transcript-log-stream")
    expect(transcriptStream.closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    expect(screen.getByRole("button", { name: "Close artifact viewer" })).toBeInTheDocument()
    setScrollMetrics(transcriptStream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 600 })
    fireEvent.scroll(transcriptStream)
    setScrollMetrics(transcriptStream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 600 })

    const subscriptionCalls = actionCable.createSubscription.mock.calls as unknown[][]
    const appEventSubscription = subscriptionCalls.at(-1)?.[1] as { received?: (event: unknown) => void } | undefined
    act(() => {
      appEventSubscription?.received?.({
        type: "job.updated",
        resource: "job",
        id: 42,
        changed: ["run.updated", "job_logs"],
        occurred_at: "2026-05-30T10:04:00.000Z"
      })
    })
    await waitFor(() => {
      expect(fetchSpy.mock.calls.filter(([path]) => String(path) === "/api/v1/app/jobs/42/runs/9/artifacts")).toHaveLength(2)
    })
    expect(await screen.findByText("new marble")).toBeInTheDocument()
    expect(screen.getByText("System")).toBeInTheDocument()
    expect(screen.queryByText("system")).not.toBeInTheDocument()
    await waitFor(() => expect(transcriptStream.scrollTop).toBe(1200))

    fireEvent.click(screen.getByRole("button", { name: "Diff" }))
    expect(await screen.findByText(/diff --git a\/app.rb b\/app.rb/)).toBeInTheDocument()
    expect(screen.getByTestId("agent-diff-viewer").closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    expect(screen.getByText("puts 'old forum'").closest("tr")).toHaveAttribute("data-diff-kind", "delete")
    expect(screen.getByText("puts 'forum'").closest("tr")).toHaveAttribute("data-diff-kind", "add")
    expect(screen.getByText("context").closest("tr")).toHaveAttribute("data-diff-kind", "context")

    fireEvent.click(screen.getByRole("button", { name: "Grade log" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/runs/9/grade_log?name=tests&workflow_id=5",
        expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
      )
    })
    expect(await screen.findByText("tests grade log")).toBeInTheDocument()
    expect(screen.getByText("rspec output")).toBeInTheDocument()
    const gradeLogStream = screen.getByTestId("run-grade-log-stream")
    expect(gradeLogStream.closest("section")).toHaveClass("max-md:fixed", "max-md:inset-0", "max-md:h-[100dvh]")
    fireEvent.click(screen.getByRole("button", { name: "Close artifact viewer" }))
    expect(screen.queryByText("rspec output")).not.toBeInTheDocument()
  }, 10_000)

  it("coalesces adjacent transcript chunks from the same command source", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts") {
        return Promise.resolve(new Response(JSON.stringify({
          job_id: 42,
          run_id: 9,
          agent_diff: null,
          agent_diff_bytes: 0,
          logs_count: 6,
          logs: [
            { id: 1, sequence: 0, kind: "system", chunk: "[prepare] (1/2) $ bundle install", created_at: "2026-05-30T10:02:00Z" },
            { id: 2, sequence: 1, kind: "system", chunk: "Fetching rack 3.2.6", created_at: "2026-05-30T10:02:01Z" },
            { id: 3, sequence: 2, kind: "system", chunk: "Fetching rack-session 2.1.2", created_at: "2026-05-30T10:02:02Z" },
            { id: 4, sequence: 3, kind: "system", chunk: "[prepare] (2/2) $ npm ci", created_at: "2026-05-30T10:02:03Z" },
            { id: 5, sequence: 4, kind: "system", chunk: "added 42 packages", created_at: "2026-05-30T10:02:04Z" },
            { id: 6, sequence: 5, kind: "tool_call", chunk: "bundle install", created_at: "2026-05-30T10:02:05Z" }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Workflows (1)" }))
    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    fireEvent.click(screen.getByRole("button", { name: "Transcript" }))

    expect(await screen.findByText((_, element) => (
      element?.tagName === "PRE" &&
      element.textContent === "[prepare] (1/2) $ bundle install\nFetching rack 3.2.6\nFetching rack-session 2.1.2"
    ))).toBeInTheDocument()
    expect(screen.getByText((_, element) => (
      element?.tagName === "PRE" &&
      element.textContent === "[prepare] (2/2) $ npm ci\nadded 42 packages"
    ))).toBeInTheDocument()
    expect(screen.queryByText((_, element) => (
      element?.tagName === "PRE" &&
      element.textContent === "[prepare] (1/2) $ bundle install\nFetching rack 3.2.6\nFetching rack-session 2.1.2\n[prepare] (2/2) $ npm ci\nadded 42 packages"
    ))).not.toBeInTheDocument()
    expect(screen.getAllByText("System")).toHaveLength(2)
    expect(screen.getByText("Tool")).toBeInTheDocument()
  })

  it("uses the job name as the Job detail title and moves source metadata below it", async () => {
    const payload = jobDetailPayload({
      job: {
        kind: "direct",
        issue_number: null,
        issue_title: "Investigate viewport report"
      }
    })
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { level: 1, name: /Investigate viewport report/ })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByText("Direct Job")).toBeInTheDocument()
    expect(screen.getAllByText("implemented").length).toBeGreaterThan(0)
    expect(screen.getByText("codex")).toBeInTheDocument()
    expect(screen.getByText("pat")).toBeInTheDocument()
  })

  it("links to the Epic from the Job detail summary when the Job belongs to one", async () => {
    const payload = jobDetailPayload({
      epic: {
        id: 7,
        number: 7,
        display_number: "EPIC-7",
        title: "Raise the aqueduct",
        state: "in_progress",
        epic_path: "/epics/7"
      }
    })
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "EPIC-7 Raise the aqueduct" })).toHaveAttribute("href", "/app-shell/epics/7")
  })

  it("keeps the admin-only Job timeline collapsed until opened", async () => {
    const payload = jobDetailPayload({ actions: { can_view_timeline: true } })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Timeline (1 run)" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("Workflow created")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/jobs/42/timeline",
      expect.objectContaining({ credentials: "same-origin" })
    )

    fireEvent.click(screen.getByRole("button", { name: "Timeline (1 run)" }))

    expect(await screen.findByText("Workflow created")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Workflow created" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("link", { name: "WF-5" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("button", { name: "Timeline (1 run)" })).toHaveAttribute("aria-expanded", "true")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/42/timeline",
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("renders workflow pagination on the Job detail workflows tab", async () => {
    const payload = jobDetailPayload({
      job: { workflows_count: 12 },
      workflows: [
        { ...jobDetailPayload().workflows[0], id: 15, slug: "WF-15", path: "/jobs/42?tab=workflows&workflows_page=2#workflow-15", trigger_kind: "retry", steps: [] },
        { ...jobDetailPayload().workflows[0], id: 16, slug: "WF-16", path: "/jobs/42?tab=workflows&workflows_page=2#workflow-16", trigger_kind: "pr_comment", steps: [] }
      ],
      workflows_pagination: {
        page: 2,
        per_page: 10,
        total_workflows: 12,
        total_pages: 2,
        first_item: 11,
        last_item: 12,
        previous_path: "/jobs/42?tab=workflows&workflows_page=1",
        next_path: null
      }
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows&workflows_page=2"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Workflows (12)" })).toBeInTheDocument()
    expect(screen.getByText("WF-15")).toBeInTheDocument()
    expect(screen.getByText("WF-16")).toBeInTheDocument()
    expect(screen.getAllByText("Showing 11-12 of 12")).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "Previous" })[0]).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows&workflows_page=1")
    expect(screen.getAllByText("Next")[0]).toHaveClass("text-gray-300")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/42?workflows_page=2",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders running Job, Step, and Run pills with progress spinners", async () => {
    const payload = jobDetailPayload({ job: { summary_state: "running" } })
    payload.workflows[0].state = "running"
    payload.workflows[0].steps[0].state = "running"
    payload.workflows[0].steps[0].runs[0].state = "running"

    vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    expect(screen.getAllByText("running")).toHaveLength(2)
    fireEvent.click(screen.getByRole("button", { name: /Implement/i }))
    const runningLabels = screen.getAllByText("running")

    expect(runningLabels).toHaveLength(3)
    const pillRunningLabels = runningLabels.filter(l => l.closest("[data-status-pill='true']"))
    expect(pillRunningLabels).toHaveLength(2)
    for (const label of pillRunningLabels) expectRunningPill(label)
  })

  it("renders the Job source browser from the app source API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/jobs/42/source?")) {
        return Promise.resolve(new Response(JSON.stringify(jobSourcePayload({ withFile: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/source") {
        return Promise.resolve(new Response(JSON.stringify(jobSourcePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=source"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const appDirectory = await screen.findByRole("button", { name: "app" })
    expect(appDirectory).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("user.rb")).not.toBeInTheDocument()

    fireEvent.click(appDirectory)
    expect(appDirectory).toHaveAttribute("aria-expanded", "true")
    fireEvent.click(screen.getByRole("button", { name: "models" }))
    fireEvent.click(screen.getByTitle("app/models/user.rb (512 B)"))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/source?ref=deadbeef12345678&path=app%2Fmodels%2Fuser.rb",
        expect.objectContaining({ credentials: "same-origin" })
      )
    })
    const keyword = await screen.findByText("class")
    expect(keyword.closest("code")).toHaveTextContent("class User")
  })

  it("switches the Job source browser into diff mode", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/source_diff") {
        return Promise.resolve(new Response(JSON.stringify(jobSourceDiffPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/jobs/42/source_diff?")) {
        return Promise.resolve(new Response(JSON.stringify(jobSourceDiffPayload({ baseRef: "deadbeef12345678", headRef: "aabbccdd1234567" })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/source") {
        return Promise.resolve(new Response(JSON.stringify(jobSourcePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=source"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "app" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Diff" }))

    expect(await screen.findByText("Select a file to view its diff.")).toBeInTheDocument()
    expect(screen.getByText("app/models/user.rb")).toBeInTheDocument()
    expect(screen.getByText("public/logo.png")).toBeInTheDocument()
    expect(screen.queryByText("README.md")).not.toBeInTheDocument()
    expect(screen.getByText("M")).toBeInTheDocument()
    expect(screen.getByText("A")).toBeInTheDocument()

    fireEvent.click(screen.getByText("app/models/user.rb"))
    expect(await screen.findByTestId("agent-diff-viewer")).toBeInTheDocument()
    expect(screen.getByText("old")).toBeInTheDocument()
    expect(screen.getByText("new")).toBeInTheDocument()

    fireEvent.click(screen.getByText("public/logo.png"))
    expect(screen.getByText("Diff not available (binary or very large file).")).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText("From"), { target: { value: "deadbeef12345678" } })
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/source_diff?base=deadbeef12345678",
        expect.objectContaining({ credentials: "same-origin" })
      )
    })
  })

  it("dispatches Job header commands through the app API", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    const commandPaths = new Map([
      ["/api/v1/app/jobs/42/start", "Initial workflow enqueued."],
      ["/api/v1/app/jobs/42/poll_feedback", "Feedback poll enqueued."],
      ["/api/v1/app/jobs/42/rebase", "Rebase workflow enqueued."],
      ["/api/v1/app/jobs/42/check_mergeability", "Checking mergeability now..."],
      ["/api/v1/app/jobs/42/run_again", "Retry workflow enqueued."],
      ["/api/v1/app/jobs/42/restart", "Started over."],
      ["/api/v1/app/jobs/42/approve", "Job approved."],
      ["/api/v1/app/jobs/42/unapprove", "Job unapproved."],
      ["/api/v1/app/jobs/42/cancel", "Cancellation requested."],
      ["/api/v1/app/jobs/42/reopen", "Thread reopened."],
      ["/api/v1/app/jobs/42/mark_valid", "Job marked valid and re-queued."],
      ["/api/v1/app/jobs/42/pin", "Job unpinned."]
    ])
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (commandPaths.has(path)) {
        return Promise.resolve(new Response(JSON.stringify({ message: commandPaths.get(path) }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        pinned: true,
        actions: {
          can_start: true,
          can_poll_feedback: true,
          can_rebase: true,
          can_check_mergeability: true,
          can_retry: true,
          retry_implementation_action: {
            key: "retry_implementation",
            label: "Retry implementation",
            path: "/api/v1/app/jobs/42/run_again"
          },
          retry_failed_step_action: null,
          can_restart: true,
          can_cancel: true,
          can_approve: true,
          can_unapprove: true,
          can_reopen: true,
          can_mark_valid: true
        }
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const visibleCommands = [
      ["Approve", "POST", "/api/v1/app/jobs/42/approve"]
    ]
    const overflowCommands = [
      ["Start Run", "POST", "/api/v1/app/jobs/42/start"],
      ["Check feedback", "POST", "/api/v1/app/jobs/42/poll_feedback"],
      ["Rebase now", "POST", "/api/v1/app/jobs/42/rebase"],
      ["Check mergeability", "POST", "/api/v1/app/jobs/42/check_mergeability"],
      ["Retry implementation", "POST", "/api/v1/app/jobs/42/run_again"],
      ["Start over", "POST", "/api/v1/app/jobs/42/restart"],
      ["Unapprove", "POST", "/api/v1/app/jobs/42/unapprove"],
      ["Cancel", "POST", "/api/v1/app/jobs/42/cancel"],
      ["Reopen", "POST", "/api/v1/app/jobs/42/reopen"],
      ["Mark valid", "POST", "/api/v1/app/jobs/42/mark_valid"],
      ["Unpin", "DELETE", "/api/v1/app/jobs/42/pin"]
    ]

    expect(await screen.findByRole("button", { name: "Approve" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Start Run" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "⋯" }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    expect(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Retry with feedback" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    await waitFor(() => {
      expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    })
    fireEvent.click(screen.getByRole("button", { name: "⋯" }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    await waitFor(() => {
      expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    })

    for (const [label, method, path] of visibleCommands) {
      fireEvent.click(screen.getByRole("button", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }

    for (const [label, method, path] of overflowCommands) {
      fireEvent.click(screen.getByRole("button", { name: "⋯" }))
      fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }
  }, 15000)

  it("labels approval as reapproval after a landing failure", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(jobDetailPayload({
      job: {
        landing_failure_reason: "auto_merge: PR mergeable_state is \"dirty\" and rebase cap reached"
      },
      actions: {
        can_approve: true,
        can_retry: false,
        can_poll_feedback: false,
        can_rebase: false,
        can_check_mergeability: false,
        can_restart: false,
        can_cancel: false
      }
    })), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Reapprove" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Approve" })).not.toBeInTheDocument()
  })

  it("sends retry feedback from the Job header More menu", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/run_again" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Retry workflow enqueued." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        actions: {
          can_retry: true,
          retry_implementation_action: {
            key: "retry_implementation",
            label: "Retry implementation",
            path: "/api/v1/app/jobs/42/run_again"
          },
          retry_failed_step_action: null,
          can_approve: false,
          can_poll_feedback: false,
          can_rebase: false,
          can_check_mergeability: false,
          can_restart: false,
          can_cancel: false
        }
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Retry implementation" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "⋯" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Retry with feedback" }))

    const dialog = screen.getByRole("dialog", { name: "Retry with feedback" })
    fireEvent.change(within(dialog).getByLabelText("Feedback"), { target: { value: "Please use the marble route this time." } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Retry" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/run_again",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ retry_context: "Please use the marble route this time." })
        })
      )
    })
    expect(await screen.findByText("Retry workflow enqueued.")).toBeInTheDocument()
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Retry with feedback" })).not.toBeInTheDocument()
    })
  })

  it("dispatches Job metadata controls through the app API", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/tags" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Tag added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/tags/4" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Tag removed." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/stack_base" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Stack base updated." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/dependencies" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Dependency added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/dependencies/9" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Dependency removed." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/dependencies/override" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Dependency gate overridden." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        actions: { can_override_dependencies: true },
        dependencies: [
          {
            id: 9,
            source: "manual",
            manual: true,
            pending: false,
            succeeded: false,
            unresolved_slug: null,
            depends_on_job: {
              id: 41,
              kind: "issue",
              state: "open",
              summary_state: "open",
              repository_slug: "acme/widgets",
              issue_number: 11,
              issue_title: "Build hill",
              branch_name: "syrus/issue-11",
              pr_number: null,
              job_path: "/jobs/41"
            }
          }
        ],
        unsatisfied_dependencies: [
          {
            id: 9,
            source: "manual",
            manual: true,
            pending: false,
            succeeded: false,
            unresolved_slug: null,
            depends_on_job: {
              id: 41,
              kind: "issue",
              state: "open",
              summary_state: "open",
              repository_slug: "acme/widgets",
              issue_number: 11,
              issue_title: "Build hill",
              branch_name: "syrus/issue-11",
              pr_number: null,
              job_path: "/jobs/41"
            }
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const dependencyLinks = await screen.findAllByRole("link", { name: "acme/widgets JOB-41 (open)" })
    expect(dependencyLinks).toHaveLength(2)
    dependencyLinks.forEach((link) => {
      expect(link).toHaveAttribute("href", "/app-shell/jobs/41")
    })

    fireEvent.click(await screen.findByRole("button", { name: "+ Add tag" }))
    fireEvent.change(screen.getByPlaceholderText("Add tag"), { target: { value: "urgent" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Add" })[0])
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/tags",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ tag_name: "urgent" }) })
      )
    })

    fireEvent.click(screen.getByTitle("Remove priority:forum"))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/tags/4", expect.objectContaining({ method: "DELETE" }))
    })

    fireEvent.change(screen.getByDisplayValue("auto"), { target: { value: "main" } })
    fireEvent.click(screen.getByRole("button", { name: "Update" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/stack_base",
        expect.objectContaining({ method: "PATCH", body: JSON.stringify({ stack_base: "main" }) })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "+ Add dependency" }))
    fireEvent.click(screen.getByRole("button", { name: "acme/widgets #11 - Build hill (JOB-41)" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/dependencies",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ dependency_target: "issue:3:11" }) })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "Remove" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/dependencies/9", expect.objectContaining({ method: "DELETE" }))
    })

    fireEvent.click(screen.getByRole("button", { name: "Override and force-run" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/dependencies/override", expect.objectContaining({ method: "POST" }))
    })
  })

  it("dispatches Job workflow and run commands through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/workflows/5/retry_step" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Retrying implement for WF-5..." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/workflows/5/push_commits" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Pushing commits to GitHub..." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/stop" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Run stopped." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/runs/9/diagnose" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Diagnostic queued." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/resume" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Resume workflow enqueued." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        workflows: [
          {
            ...jobDetailPayload().workflows[0],
            state: "failed",
            cleaned_up_at: null,
            retry_available: true,
            steps: [
              {
                ...jobDetailPayload().workflows[0].steps[0],
                state: "failed",
                display_status: "failed",
                runs: [
                  {
                    ...jobDetailPayload().workflows[0].steps[0].runs[0],
                    state: "failed",
                    can_stop: true,
                    can_diagnose: true,
                    can_resume: true
                  }
                ]
              }
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("WF-5")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /Implement/i }))
    const commands = [
      ["Retry failed step", "POST", "/api/v1/app/jobs/42/workflows/5/retry_step"],
      ["Push commits", "POST", "/api/v1/app/jobs/42/workflows/5/push_commits"],
      ["Stop", "POST", "/api/v1/app/jobs/42/runs/9/stop"],
      ["Diagnose", "POST", "/api/v1/app/jobs/42/runs/9/diagnose"]
    ]
    for (const [label, method, path] of commands) {
      fireEvent.click(screen.getByRole("button", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }

    fireEvent.click(screen.getByRole("button", { name: "Resume" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/resume",
        expect.objectContaining({ method: "POST", body: JSON.stringify({ source_run_id: 9 }) })
      )
    })
  })

  it("shows active retried runs before earlier failed runs on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const step = workflow.steps[0]
    const failedRun = {
      ...step.runs[0],
      id: 9,
      state: "failed",
      started_at: "2026-05-30T10:01:00Z",
      finished_at: "2026-05-30T10:15:00Z",
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T10:15:00Z"
    }
    const runningRun = {
      ...step.runs[0],
      id: 10,
      state: "running",
      started_at: "2026-05-30T10:20:00Z",
      finished_at: null,
      created_at: "2026-05-30T10:19:00Z",
      updated_at: "2026-05-30T10:20:00Z",
      can_stop: true,
      can_diagnose: false,
      can_resume: false
    }
    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        job: { state: "open", summary_state: "running", any_active_run: true },
        workflows: [
          {
            ...workflow,
            state: "running",
            finished_at: null,
            steps: [
              {
                ...step,
                state: "failed",
                display_status: "failed",
                finished_at: null,
                runs: [failedRun, runningRun]
              }
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.queryByText(/Run #10 is running/)).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    expect(await screen.findByText(/Run #10 is running/)).toBeInTheDocument()
    expect(screen.getByText("step failed")).toBeInTheDocument()
    expect(screen.getByText("Run #10").compareDocumentPosition(screen.getByText("Run #9"))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })

  it("shows a queued run as waiting for a worker, not a hang", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const step = workflow.steps[0] as JobStep
    const queuedRun = {
      ...step.runs[0],
      id: 30,
      state: "queued",
      started_at: null,
      finished_at: null,
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T10:00:00Z"
    }
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        job: { state: "open", summary_state: "running", any_active_run: true },
        workflows: [ { ...workflow, state: "running", finished_at: null, steps: [ { ...step, state: "queued", display_status: "queued", finished_at: null, runs: [queuedRun] } ] } ]
      })), { status: 200, headers: { "Content-Type": "application/json" } })))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    expect(await screen.findByText(/Run #30 is waiting for a worker/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /pending queue/i })).toHaveAttribute("href", "/app-shell/admin/queue/pending")
  })

  it("renders prepare failures as setup failures on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const prepareRun = {
      ...template.runs[0],
      id: 16,
      state: "failed",
      agent_provider: null,
      agent_outcome: null,
      agent_turns: 0,
      agent_summary: null,
      agent_diff_present: false,
      agent_diff_bytes: 0,
      failure_classification: {
        id: 17,
        classification: "application_error",
        confidence: 0.4,
        retryable: false,
        reason: "The run failed with an unclassified application error.",
        diagnostic_summary: "Steps::Base::StepFailed: prepare command failed",
        classified_at: "2026-05-30T10:03:00Z"
      }
    }
    const prepareFailure = {
      command: "npm ci",
      workdir: "/workflows/42/repo",
      exit_status: 1,
      timed_out: false,
      output_tail: "npm ERR! missing package-lock.json"
    }

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        job: { state: "open", summary_state: "failed" },
        workflows: [
          {
            ...workflow,
            state: "failed",
            failure_count: 1,
            steps: [
              {
                ...template,
                id: 15,
                kind: "prepare",
                display_name: "Prepare workspace",
                display_status: "failed",
                position: 0,
                state: "failed",
                details: { prepare_failure: prepareFailure },
                runs: [prepareRun]
              }
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /Prepare workspace/i }))

    expect(screen.getByText("Setup failed before the agent started")).toBeInTheDocument()
    expect(screen.getByText("npm ci")).toBeInTheDocument()
    expect(screen.getByText("/workflows/42/repo")).toBeInTheDocument()
    expect(screen.getByText("exit 1")).toBeInTheDocument()
    expect(screen.getByText("npm ERR! missing package-lock.json")).toBeInTheDocument()
  })

  it("groups grader setup and aggregation under one Grade step", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const step = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: null,
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        workflows: [
          {
            ...workflow,
            steps: [
              step({ id: 61, kind: "prepare", display_name: "Prepare workspace", display_status: "succeeded", position: 0, state: "succeeded" }),
              step({ id: 62, kind: "grader_fanout", display_name: "Plan graders", display_status: "succeeded", position: 1, loop_id: "grade-loop", iteration: 1, state: "succeeded" }),
              step({
                id: 63,
                kind: "grader",
                display_name: "rspec",
                display_status: "failed",
                position: 2,
                loop_id: "grade-loop",
                iteration: 1,
                state: "failed",
                details: { name: "rspec", required: true, exit_code: 1, duration_s: 2.4, log_bytes: 2048, description: "Full RSpec suite.", command: "bin/rspec" }
              }),
              step({ id: 64, kind: "grader_collect", display_name: "Aggregate graders", display_status: "failed", position: 3, loop_id: "grade-loop", iteration: 1, state: "failed" }),
              step({ id: 65, kind: "push", display_name: "Push", display_status: null, position: 4, state: "queued" })
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: /Prepare workspace/i })).toBeInTheDocument()
    const grade = screen.getByRole("button", { name: /Grade/i })
    expect(within(grade).getAllByText(/failed/i).length).toBeGreaterThan(0)
    expect(within(grade).getByText("1 failed")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Push/i })).toBeInTheDocument()
    expect(screen.queryByText("Plan graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Aggregate graders")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /rspec/i })).not.toBeInTheDocument()

    fireEvent.click(grade)

    // The redundant "Grade summary" table is gone; the per-grader phase
    // cards remain.
    expect(screen.queryByText("Grade summary")).not.toBeInTheDocument()
    expect(screen.queryByText("Open an individual grader below to view raw logs.")).not.toBeInTheDocument()
    expect(screen.queryByText("exit 1")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Result/i })).toBeInTheDocument()

    // Expanding a grader shows the compact details (no raw JSON).
    fireEvent.click(screen.getByRole("button", { name: /rspec/i }))
    expect(screen.getByText("required")).toBeInTheDocument()
    expect(screen.getByText("Full RSpec suite.")).toBeInTheDocument()
    expect(screen.getByText("bin/rspec")).toBeInTheDocument()
    expect(screen.queryByText(/"log_bytes"/)).not.toBeInTheDocument()
  })

  it("groups repeated loop iterations on the workflows tab", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const run = template.runs[0]
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        job: { state: "open", summary_state: "running", any_active_run: true },
        workflows: [
          {
            ...workflow,
            state: "running",
            finished_at: null,
            steps: [
              loopStep({
                id: 61,
                kind: "implement",
                display_name: "Implement",
                display_status: "succeeded",
                position: 1,
                iteration: 1,
                state: "succeeded",
                runs: [{ ...run, id: 91, state: "succeeded" }]
              }),
              loopStep({ id: 62, kind: "grader_fanout", display_name: "Plan graders", display_status: "succeeded", position: 2, iteration: 1, state: "succeeded" }),
              loopStep({ id: 63, kind: "grader", display_name: "rspec", display_status: "failed", position: 3, iteration: 1, state: "failed", details: { name: "rspec" } }),
              loopStep({ id: 64, kind: "grader_collect", display_name: "Aggregate graders", display_status: "failed", position: 4, iteration: 1, state: "failed" }),
              loopStep({
                id: 65,
                kind: "implement",
                display_name: "Implement",
                display_status: "running",
                position: 5,
                iteration: 2,
                state: "running",
                latest: true,
                runs: [{ ...run, id: 92, state: "running", started_at: "2026-05-30T10:20:00Z", finished_at: null }]
              }),
              loopStep({ id: 66, kind: "grader_fanout", display_name: "Plan graders", display_status: null, position: 6, iteration: 2, state: "queued" }),
              loopStep({ id: 67, kind: "grader", display_name: "rspec", display_status: null, position: 7, iteration: 2, state: "queued", details: { name: "rspec" } }),
              loopStep({ id: 68, kind: "grader_collect", display_name: "Aggregate graders", display_status: null, position: 8, iteration: 2, state: "queued" })
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: /Grade loop/ })).toBeInTheDocument()
    expect(within(screen.getByRole("button", { name: /Grade loop/ })).getByText(/running/i)).toBeInTheDocument()
    expect(screen.getByText("2 iterations")).toBeInTheDocument()
    expect(screen.queryByText("Iteration 1")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /rspec/i })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Grade loop/ }))

    expect(screen.getByText("Iteration 1")).toBeInTheDocument()
    expect(screen.getByText("Iteration 2")).toBeInTheDocument()
    expect(screen.queryByText("Plan graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Aggregate graders")).not.toBeInTheDocument()
    const iterationOne = screen.getByText("Iteration 1").closest("section")!
    fireEvent.click(within(iterationOne).getByRole("button", { name: /Grade/i }))
    expect(within(iterationOne).getByRole("button", { name: /rspec/i })).toBeInTheDocument()
    expect(within(iterationOne).getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(within(iterationOne).getByRole("button", { name: /Result/i })).toBeInTheDocument()
  })

  it("shows the grade loop status from the latest iteration", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const run = template.runs[0]
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        workflows: [
          {
            ...workflow,
            state: "succeeded",
            steps: [
              loopStep({ id: 61, kind: "implement", display_name: "Implement", display_status: "succeeded", position: 1, iteration: 1, state: "succeeded" }),
              loopStep({ id: 62, kind: "grader_fanout", display_name: "Plan graders", display_status: "succeeded", position: 2, iteration: 1, state: "succeeded" }),
              loopStep({ id: 63, kind: "grader", display_name: "rspec", display_status: "failed", position: 3, iteration: 1, state: "failed", details: { name: "rspec" } }),
              loopStep({ id: 64, kind: "grader_collect", display_name: "Aggregate graders", display_status: "failed", position: 4, iteration: 1, state: "failed" }),
              loopStep({ id: 65, kind: "implement", display_name: "Implement", display_status: "succeeded", position: 5, iteration: 2, state: "succeeded", runs: [{ ...run, id: 92, state: "succeeded" }] }),
              loopStep({ id: 66, kind: "grader_fanout", display_name: "Plan graders", display_status: "succeeded", position: 6, iteration: 2, state: "succeeded" }),
              loopStep({ id: 67, kind: "grader", display_name: "rspec", display_status: "succeeded", position: 7, iteration: 2, state: "succeeded", details: { name: "rspec" } }),
              loopStep({ id: 68, kind: "grader_collect", display_name: "Aggregate graders", display_status: "succeeded", position: 8, iteration: 2, state: "succeeded" })
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const gradeLoop = await screen.findByRole("button", { name: /Grade loop/ })
    expect(within(gradeLoop).getByText(/succeeded/i)).toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/failed/i)).not.toBeInTheDocument()
  })

  it("does not show a terminal grade loop status while the latest iteration is queued", async () => {
    const base = jobDetailPayload()
    const workflow = base.workflows[0]
    const template = workflow.steps[0] as JobStep
    const loopStep = (attrs: Partial<JobStep>): JobStep => ({
      ...template,
      loop_id: "loop-a",
      runs: [],
      details: null,
      latest: false,
      ...attrs
    })

    vi.spyOn(window, "fetch").mockImplementation(() => {
      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload({
        job: { state: "open", summary_state: "running", any_active_run: true },
        workflows: [
          {
            ...workflow,
            state: "running",
            finished_at: null,
            steps: [
              loopStep({ id: 61, kind: "implement", display_name: "Implement", display_status: "succeeded", position: 1, iteration: 1, state: "succeeded" }),
              loopStep({ id: 62, kind: "grader_fanout", display_name: "Plan graders", display_status: "succeeded", position: 2, iteration: 1, state: "succeeded" }),
              loopStep({ id: 63, kind: "grader", display_name: "rspec", display_status: "failed", position: 3, iteration: 1, state: "failed", details: { name: "rspec" } }),
              loopStep({ id: 64, kind: "grader_collect", display_name: "Aggregate graders", display_status: "failed", position: 4, iteration: 1, state: "failed" }),
              loopStep({ id: 65, kind: "implement", display_name: "Implement", display_status: "succeeded", position: 5, iteration: 2, state: "succeeded" }),
              loopStep({ id: 66, kind: "grader_fanout", display_name: "Plan graders", display_status: null, position: 6, iteration: 2, state: "queued" }),
              loopStep({ id: 67, kind: "grader", display_name: "rspec", display_status: null, position: 7, iteration: 2, state: "queued", details: { name: "rspec" } }),
              loopStep({ id: 68, kind: "grader_collect", display_name: "Aggregate graders", display_status: null, position: 8, iteration: 2, state: "queued" })
            ]
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=workflows"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const gradeLoop = await screen.findByRole("button", { name: /Grade loop/ })
    expect(within(gradeLoop).getByText(/queued/i)).toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/succeeded/i)).not.toBeInTheDocument()
    expect(within(gradeLoop).queryByText(/failed/i)).not.toBeInTheDocument()
  })

  it("adds and removes Job attachments through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/attachments" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Attachment added." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/attachments/8" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Attachment removed." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=attachments"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const file = new File(["notes"], "notes.md", { type: "text/markdown" })
    fireEvent.change(await screen.findByLabelText("Files"), { target: { files: [file] } })
    fireEvent.change(screen.getByLabelText("Google Doc URL"), { target: { value: "https://docs.google.com/document/d/context/edit" } })
    fireEvent.click(within(screen.getByRole("heading", { name: "Add attachment" }).closest("form")!).getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/attachments",
        expect.objectContaining({ method: "POST", body: expect.any(FormData) })
      )
    })
    const formData = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/jobs/42/attachments" && init?.method === "POST")?.[1]?.body as FormData
    expect(formData.get("job_attachment[google_doc_url]")).toBe("https://docs.google.com/document/d/context/edit")
    expect(formData.get("job_attachment[files][]")).toBe(file)

    fireEvent.click(screen.getByRole("button", { name: "Remove" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/attachments/8", expect.objectContaining({ method: "DELETE" }))
    })
  })

  it("renders a chat and sends a message from the app API", async () => {
    const invalidateSpy = vi.spyOn(QueryClient.prototype, "invalidateQueries")
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          message: "Message sent.",
          messages: [
            ...chatPayload().messages,
            {
              type: "message",
              id: 10,
              role: "user",
              text: "Now inspect proposals",
              bookmarkable: true
            }
          ],
          turnInFlight: true
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const chatMain = await screen.findByRole("main", { name: "Chat" })
    expect(chatMain).toBeInTheDocument()
    expect(chatMain).toHaveClass("h-full", "overflow-hidden")
    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Aqueduct planning" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream")).toHaveClass("h-full", "min-h-0", "overflow-y-auto")
    expect(screen.getByText("Discuss aqueducts.").closest(".chat-prose")).toHaveClass("dark:text-gray-100")
    expect(screen.getByText("Discuss aqueducts.").closest(".chat-prose")?.parentElement).toHaveClass("dark:bg-gray-900", "dark:border-gray-700")
    expect(screen.getByRole("complementary", { name: "Chat workspace" })).toHaveClass("min-h-0", "dark:bg-gray-900", "dark:border-gray-700")
    expect(screen.getByRole("navigation", { name: "Chat workspace tabs" })).toHaveClass("dark:border-gray-700")
    expect(screen.getByRole("button", { name: "Resize chat workspace" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Refresh repo" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reset workspace" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "acme/widgets" })).not.toBeInTheDocument()
    expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Fullscreen" }))
    expect(screen.getByRole("button", { name: "Exit fullscreen" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.queryByTestId("chat-message-stream")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Resize chat workspace" })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Chat workspace tabs" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Exit fullscreen" }))
    expect(screen.getByTestId("chat-message-stream")).toBeInTheDocument()
    expect(screen.getByRole("navigation", { name: "Chat workspace tabs" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Fullscreen" }))
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.getByRole("button", { name: "Fullscreen" })).toHaveAttribute("aria-pressed", "false")
    expect(screen.queryByText("Launch notes")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Context" }))
    expect(screen.getByText("Launch notes")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Attachments" })).toHaveClass("dark:text-gray-100")
    expect(screen.getByRole("button", { name: "acme/widgets" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "acme/widgets" })).toHaveClass("dark:bg-gray-800", "dark:text-gray-300")
    expect(screen.queryByRole("heading", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Type")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Chats" })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Recent chats" })).not.toBeInTheDocument()
    expect(screen.getByText("12.4k in", { exact: false })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Ask about this repository...")).toHaveClass("dark:bg-gray-950", "dark:text-gray-100")
    fireEvent.change(screen.getByPlaceholderText("Ask about this repository..."), { target: { value: "Now inspect proposals" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ chat_message: { text: "Now inspect proposals" } })
        })
      )
    })
    expect(await screen.findByText("Now inspect proposals")).toBeInTheDocument()
    expect(screen.getByText("Now inspect proposals").closest(".chat-prose")).toBeNull()
    expect(screen.getByText("Now inspect proposals")).toHaveClass("whitespace-pre-wrap", "dark:bg-blue-500")
    expect(screen.queryByText("Message sent.")).not.toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/mark_read", expect.objectContaining({ method: "PATCH" }))
    })
    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    })
  })

  it("renders a chat attachment add button in the composer", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ...chatPayload(), walkthroughs_enabled: true }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const addAttachment = screen.getByRole("button", { name: "Add attachment" })
    expect(addAttachment).toHaveTextContent("+")
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.getByLabelText("Chat attachments")).toHaveAttribute("accept", "image/*,application/pdf,video/webm,video/mp4,video/quicktime")
  })

  it("gates video intake behind the walkthroughs labs flag", async () => {
    // chatPayload() carries no walkthroughs_enabled — the flag-off default.
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ...chatPayload(), gemini_configured: true }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")

    // No video types offered by the picker, no Record entry in the + menu.
    expect(screen.getByLabelText("Chat attachments")).toHaveAttribute("accept", "image/*,application/pdf")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(await screen.findByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.queryByText("Record a walkthrough")).not.toBeInTheDocument()

    // A dropped video does NOT become a walkthrough draft.
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement
    const video = new File(["v"], "walkthrough.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [video] } })
    await waitFor(() => {
      expect(screen.queryByTestId("walkthrough-chip")).not.toBeInTheDocument()
    })
  })

  it("blocks sending a ready walkthrough alongside image attachments", async () => {
    // Gemini must be configured or the drop opens the setup sheet instead of
    // creating a walkthrough draft (chatPayload defaults gemini_configured off).
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ...chatPayload(), gemini_configured: true, walkthroughs_enabled: true }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    // jsdom implements neither media metadata nor URL.createObjectURL, so the
    // real measureVideoDuration would hang the intake await; resolve it here.
    vi.spyOn(videoWalkthroughs, "measureVideoDuration").mockResolvedValue(30)

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement

    // One drop carrying a video AND an image: the video becomes the walkthrough
    // draft, the image becomes a normal chat attachment — the exact combo the
    // review finding said must not be sendable together.
    const video = new File(["v"], "walkthrough.webm", { type: "video/webm" })
    const image = new File(["i"], "screenshot.png", { type: "image/png" })
    fireEvent.drop(form, { dataTransfer: { files: [video, image] } })

    // Walkthrough draft settles to "ready", image attachment chip appears.
    expect(await screen.findByTestId("walkthrough-chip")).toHaveTextContent("Ready")
    await screen.findByText("screenshot.png")

    const messageCallsBefore = fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/message")).length
    fireEvent.submit(form)

    // Explicit block, not a silent split: the copy from the en locale.
    expect(await screen.findByText(
      "Send the walkthrough on its own — remove image or file attachments and send them in a separate message."
    )).toBeInTheDocument()
    // Nothing was sent — no message POST, no upload attempt.
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/message")).length).toBe(messageCallsBefore)
  })

  it("blocks dropping a second walkthrough while the first is uploading", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ...chatPayload(), gemini_configured: true, walkthroughs_enabled: true }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    vi.spyOn(videoWalkthroughs, "measureVideoDuration").mockResolvedValue(30)
    // Hold the upload in-flight so the draft stays "uploading" — a settled
    // (ready/failed) draft is replaceable; only an in-flight one is guarded.
    const uploadSpy = vi.spyOn(videoWalkthroughs, "uploadVideoWalkthrough").mockReturnValue(new Promise(() => {}))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement

    const first = new File(["v1"], "first.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [first] } })
    expect(await screen.findByTestId("walkthrough-chip")).toHaveTextContent("Ready")

    // Send commits the walkthrough — the upload starts and hangs, so the draft
    // is now "uploading".
    fireEvent.submit(form)
    await waitFor(() => expect(uploadSpy).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.getByTestId("walkthrough-chip")).toHaveTextContent(/Uploading/))

    // Dropping a second video now must trip the one-at-a-time guard.
    const second = new File(["v2"], "second.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [second] } })

    expect(await screen.findByText(
      "A walkthrough is already being processed — wait for it to finish, then add another."
    )).toBeInTheDocument()
    // The in-flight draft was not replaced: still showing the first upload,
    // and no second upload was kicked off.
    expect(uploadSpy).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId("walkthrough-chip")).toHaveTextContent("first.webm")
  })

  it("renders a centered landing layout for an empty chat", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "What would you like to build?" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "What would you like to build?" }).closest("section")).toHaveClass("items-center", "justify-center")
    expect(screen.getByPlaceholderText("Ask about this repository...").closest("form")?.parentElement).toHaveClass("max-w-sm", "sm:max-w-2xl")
  })

  it("shows a removable attached repository chip in the empty chat landing compose area", async () => {
    const initialPayload = chatPayload({ messages: [] })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/attachments/2" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "acme/widgets detached.",
          attachment_groups: { ...initialPayload.attachment_groups, repositories: [] }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "What would you like to build?" })).toBeInTheDocument()
    const chip = screen.getByText("acme/widgets")
    const textarea = screen.getByPlaceholderText("Ask about this repository...")
    const composeForm = textarea.closest("form")
    // The textarea sits inside a relative wrapper (for the ghost-text
    // suggestion overlay); the compose row is one level further up.
    const composeRow = textarea.parentElement?.parentElement
    expect(chip).toBeInTheDocument()
    expect(chip.closest("div")).toHaveClass("w-full")
    expect(chip.compareDocumentPosition(textarea) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getByRole("button", { name: "Add attachment" }).parentElement).toBe(composeRow)
    expect(screen.getByRole("button", { name: "Send message" }).closest("div")?.parentElement).toBe(composeRow)
    expect(composeForm).not.toBeNull()
    fireEvent.click(screen.getByRole("button", { name: "Detach repository acme/widgets" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/attachments/2",
        expect.objectContaining({ method: "DELETE" })
      )
    })
    expect(within(composeForm as HTMLElement).queryByText("acme/widgets")).not.toBeInTheDocument()
  })

  it("moves the empty chat landing into the standard chat layout after the first send succeeds", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          messages: [
            {
              type: "message",
              id: 10,
              role: "user",
              text: "Build a planning console",
              bookmarkable: true
            }
          ]
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("heading", { name: "What would you like to build?" })).toBeInTheDocument()

    fireEvent.change(input, { target: { value: "Build a planning console" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ chat_message: { text: "Build a planning console" } })
        })
      )
    })
    expect(await screen.findByText("Build a planning console")).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole("heading", { name: "What would you like to build?" })).not.toBeInTheDocument())
    expect(screen.getByTestId("chat-message-stream").parentElement?.parentElement).toHaveClass("flex-1", "opacity-100")
    expect(within(input.closest("form") as HTMLElement).queryByText("acme/widgets")).not.toBeInTheDocument()
  })

  it("renders non-empty chats in the standard layout immediately", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "What would you like to build?" })).not.toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream").parentElement?.parentElement).toHaveClass("flex-1", "opacity-100")
  })

  it("opens and dismisses the chat attachment popover from the compose button", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Upload file" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Repo" })).toBeInTheDocument()

    fireEvent.keyDown(screen.getByRole("dialog", { name: "Add attachment" }), { key: "Escape" })
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
  })

  it("triggers the chat file input from the attachment popover", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const inputClickSpy = vi.spyOn(HTMLInputElement.prototype, "click").mockImplementation(() => undefined)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
      fireEvent.click(screen.getByRole("button", { name: "Upload file" }))

      expect(inputClickSpy).toHaveBeenCalled()
      expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    } finally {
      inputClickSpy.mockRestore()
    }
  })

  it("adds a searched repository from the chat attachment popover", async () => {
    const search = "?attachment_type=Repository&attachment_query=tools"
    const initialPayload = {
      ...chatPayload(),
      attachment_results: [{ type: "Repository", id: 4, label: "acme/tools" }]
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === `/api/v1/app/chats/8/attachments${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "acme/tools attached.",
          attachment_groups: {
            ...initialPayload.attachment_groups,
            repositories: [
              ...initialPayload.attachment_groups.repositories,
              { id: 4, label: "acme/tools", app_detach_path: "/api/v1/app/chats/8/attachments/4" }
            ]
          },
          attachment_results: []
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={[`/app-shell/chats/8${search}`]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(await screen.findByRole("button", { name: "acme/tools" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/attachments${search}`,
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ attachable_type: "Repository", attachable_id: 4 })
        })
      )
    })
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
  })

  it("adds a selected chat attachment chip with a remove button", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const file = new File(["chart"], "flow-chart.png", { type: "image/png" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [file] } })

    expect(await screen.findByText("flow-chart.png")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Remove flow-chart.png" })).toBeInTheDocument()
  })

  it("removes a selected chat attachment chip", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const file = new File(["pdf"], "brief.pdf", { type: "application/pdf" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [file] } })

    expect(await screen.findByText("brief.pdf")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Remove brief.pdf" }))
    expect(screen.queryByText("brief.pdf")).not.toBeInTheDocument()
  })

  it("sends chat message attachments in the JSON payload", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          messages: [
            ...chatPayload().messages,
            {
              type: "message",
              id: 10,
              role: "user",
              text: "Review this diagram",
              bookmarkable: true
            }
          ]
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [new File(["chart"], "flow-chart.png", { type: "image/png" })] } })
    expect(await screen.findByText("flow-chart.png")).toBeInTheDocument()
    fireEvent.change(input, { target: { value: "Review this diagram" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({
            chat_message: {
              text: "Review this diagram",
              attachments: [
                {
                  name: "flow-chart.png",
                  mime_type: "image/png",
                  data: "Y2hhcnQ="
                }
              ]
            }
          })
        })
      )
    })
    await waitFor(() => expect(screen.queryByText("flow-chart.png")).not.toBeInTheDocument())
  })

  it("blocks chat attachment submission when a file is larger than 5 MB", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    const oversized = new File([new Uint8Array((5 * 1024 * 1024) + 1)], "too-large.png", { type: "image/png" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [oversized] } })
    expect(await screen.findByText("Each attachment must be 5 MB or smaller.")).toBeInTheDocument()

    fireEvent.change(input, { target: { value: "Try sending this" } })
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("renders chat tabs above the chat panel on mobile", async () => {
    const restoreMedia = mockMediaQuery(false)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      expect(screen.queryByRole("heading", { name: "Aqueduct planning" })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
      const mobileTabs = screen.getByRole("navigation", { name: "Chat mobile tabs" })
      expect(mobileTabs.parentElement).not.toHaveClass("rounded")
      expect(mobileTabs.parentElement).not.toHaveClass("border")
      expect(mobileTabs.parentElement?.lastElementChild).not.toHaveClass("p-3")
      expect(within(mobileTabs).getByRole("button", { name: "Chat" })).toHaveClass("border-blue-600")
      expect(within(mobileTabs).getByRole("button", { name: "Whiteboard" })).toBeInTheDocument()
      expect(within(mobileTabs).getByRole("button", { name: "Context" })).toBeInTheDocument()
      expect(within(mobileTabs).queryByRole("button", { name: "Chats" })).not.toBeInTheDocument()
      expect(screen.queryByRole("navigation", { name: "Chat workspace tabs" })).not.toBeInTheDocument()
      expect(screen.getByTestId("chat-message-stream")).toHaveClass("h-full", "min-h-0", "overflow-y-auto", "p-3")
      expect(screen.getByPlaceholderText("Ask about this repository...")).toHaveClass("text-base", "sm:text-sm")

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Whiteboard" }))
      expect(within(mobileTabs).getByRole("button", { name: "Whiteboard" })).toHaveClass("border-blue-600")
      expect(screen.queryByTestId("chat-message-stream")).not.toBeInTheDocument()
      expect(screen.getByRole("complementary", { name: "Chat workspace" })).toHaveClass("h-full", "min-h-0", "w-full", "flex-1")
      expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Context" }))
      expect(within(mobileTabs).getByRole("button", { name: "Context" })).toHaveClass("border-blue-600")
      expect(screen.getByRole("complementary", { name: "Chat workspace" })).toHaveClass("h-full", "min-h-0", "w-full", "flex-1")
      expect(screen.getByText("Launch notes")).toBeInTheDocument()

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Chat" }))
      expect(screen.getByTestId("chat-message-stream")).toBeInTheDocument()
      expect(screen.getByPlaceholderText("Ask about this repository...")).toBeInTheDocument()
    } finally {
      restoreMedia()
    }
  })

  it("renders low chat token totals without rounding them down to 0k", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({
        cumulativeInputTokens: 12,
        cumulativeOutputTokens: 5,
        cumulativeCostUsd: 0.004321
      })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Tokens: 12 in / 5 out · $0.0043")).toBeInTheDocument()
  })

  it("resizes the chat shell from the visual viewport when the mobile keyboard opens", async () => {
    const viewport = stubVisualViewport(720)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const chatMain = await screen.findByRole("main", { name: "Chat" })
      expect(chatMain).toHaveStyle({ "--chat-visual-viewport-height": "720px" })

      viewport.setHeight(420)
      viewport.dispatch("resize")

      await waitFor(() => {
        expect(chatMain).toHaveStyle({ "--chat-visual-viewport-height": "420px" })
      })
    } finally {
      viewport.restore()
    }
  })

  it("keeps the chat scrolled to the bottom when new messages arrive at the bottom", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("chat-message-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 600 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 600 })

    act(() => {
      queryClient.setQueryData(["chats", "8", ""], chatPayload({
        messages: [
          ...chatPayload().messages,
          {
            type: "message",
            id: 10,
            role: "assistant",
            text: "The water still flows.",
            bookmarkable: true
          }
        ]
      }))
    })

    expect(await screen.findByText("The water still flows.")).toBeInTheDocument()
    await waitFor(() => expect(stream.scrollTop).toBe(1200))
    expect(screen.queryByRole("button", { name: /new messages?/ })).not.toBeInTheDocument()
  })

  it("shows a new message button when messages arrive away from the bottom", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("chat-message-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 200 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1300, clientHeight: 400, scrollTop: 200 })

    act(() => {
      queryClient.setQueryData(["chats", "8", ""], chatPayload({
        messages: [
          ...chatPayload().messages,
          {
            type: "message",
            id: 10,
            role: "assistant",
            text: "First new note.",
            bookmarkable: true
          },
          {
            type: "message",
            id: 11,
            role: "assistant",
            text: "Second new note.",
            bookmarkable: true
          }
        ]
      }))
    })

    const button = await screen.findByRole("button", { name: "2 new messages" })
    expect(stream.scrollTop).toBe(200)

    fireEvent.click(button)
    await waitFor(() => expect(stream.scrollTop).toBe(1300))
    expect(screen.queryByRole("button", { name: "2 new messages" })).not.toBeInTheDocument()
  })

  it("renders agent questions inline with stacked options and records the answer in the thread", async () => {
    const initialPayload = chatPayload({
      agentQuestions: [
        {
          id: 7,
          question: "Which route should I take?",
          options: ["Fast path", "Careful path"],
          asked_at: "2026-06-23T10:00:00Z",
          app_answer_path: "/api/v1/app/chats/8/agent_questions/7/answer"
        }
      ]
    })
    const answeredPayload = chatPayload({
      messages: [
        ...initialPayload.messages,
        {
          type: "message",
          id: 10,
          role: "user",
          tool_name: null,
          content: { text: "Careful path" },
          text: "Careful path",
          bookmarkable: true
        }
      ],
      agentQuestions: [],
      message: "Answer submitted."
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/agent_questions/7/answer" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(answeredPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      const questions = within(stream).getByRole("region", { name: "Agent questions" })
      expect(questions).toHaveClass("w-full", "max-w-3xl")
      expect(within(questions).getByText("Which route should I take?")).toBeInTheDocument()

      const fastButton = within(questions).getByRole("button", { name: "Fast path" })
      const carefulButton = within(questions).getByRole("button", { name: "Careful path" })
      expect(fastButton.parentElement).toHaveClass("flex-col")
      expect(fastButton).toHaveClass("flex", "w-full", "justify-start", "text-left")
      expect(carefulButton).toHaveClass("flex", "w-full", "justify-start", "text-left")
      expect(within(questions).getByLabelText("Custom answer")).toBeInTheDocument()
      expect(within(questions).getByRole("button", { name: "Decline to answer" })).toBeInTheDocument()

      fireEvent.click(carefulButton)

      expect(await screen.findByText("Answer submitted.")).toBeInTheDocument()
      expect(within(stream).getByText("Careful path")).toBeInTheDocument()
      expect(screen.queryByRole("region", { name: "Agent questions" })).not.toBeInTheDocument()
    } finally {
      fetchSpy.mockRestore()
    }
  })

  it("sends chat messages with Enter on desktop", async () => {
    const restoreViewport = setViewportWidth(1280)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          messages: [
            ...chatPayload().messages,
            {
              type: "message",
              id: 10,
              role: "user",
              text: "Send this with enter",
              bookmarkable: true
            }
          ]
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const input = await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.change(input, { target: { value: "Send this with enter" } })
      expect(fireEvent.keyDown(input, { key: "Enter" })).toBe(false)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/chats/8/message",
          expect.objectContaining({
            method: "POST",
            body: JSON.stringify({ chat_message: { text: "Send this with enter" } })
          })
        )
      })
      expect(await screen.findByText("Send this with enter")).toBeInTheDocument()
    } finally {
      restoreViewport()
    }
  })

  it("keeps Shift+Enter as a chat input newline on desktop", async () => {
    const restoreViewport = setViewportWidth(1280)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const input = await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.change(input, { target: { value: "Keep editing" } })
      expect(fireEvent.keyDown(input, { key: "Enter", shiftKey: true })).toBe(true)
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    } finally {
      restoreViewport()
    }
  })

  it("keeps Enter as a chat input newline on mobile", async () => {
    const restoreViewport = setViewportWidth(390)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const input = await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.change(input, { target: { value: "Keep editing on mobile" } })
      expect(fireEvent.keyDown(input, { key: "Enter" })).toBe(true)
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    } finally {
      restoreViewport()
    }
  })

  it("shows and completes slash command suggestions from the chat composer", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
    fireEvent.change(input, { target: { value: "/ren" } })

    const palette = await screen.findByRole("listbox", { name: "Slash commands" })
    expect(palette).toHaveClass("max-h-[calc(var(--chat-visual-viewport-height,100dvh)-9rem)]", "overflow-y-auto")
    expect(within(palette).getByRole("option", { name: /\/rename/ })).toHaveTextContent("Rename the current chat.")
    expect(within(palette).queryByRole("option", { name: /\/jobs/ })).toBeNull()

    fireEvent.keyDown(input, { key: "Tab" })
    expect(input.value).toBe("/rename ")
  })

  it("completes slash commands with Enter before submitting on desktop", async () => {
    const restoreViewport = setViewportWidth(1280)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const input = await screen.findByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
      fireEvent.change(input, { target: { value: "/jo" } })
      expect(fireEvent.keyDown(input, { key: "Enter" })).toBe(false)
      expect(input.value).toBe("/jobs ")
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    } finally {
      restoreViewport()
    }
  })

  it("intercepts registered system slash commands before posting chat messages", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/rename" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ message: "Chat renamed." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/rename Canal review" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(await screen.findByText("Chat renamed.")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/rename", expect.objectContaining({ method: "PATCH" }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("pins the current chat from the /pin system slash command", async () => {
    const pinnedPayload = chatPayload({ message: "Chat pinned", pinned: true })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(pinnedPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/pin" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(await screen.findByText("Chat pinned")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ chat: { pinned: true } })
    }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("copies a shared chat link from the share slash command", async () => {
    const clipboardWrite = mockClipboardWrite()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/share" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ share_url: "http://syrus.test/chats/shared/token-123" }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
    fireEvent.change(input, { target: { value: "/share" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("http://syrus.test/chats/shared/token-123"))
    expect(await screen.findByText("Share link copied to clipboard")).toBeInTheDocument()
    expect(input.value).toBe("")
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/share", expect.objectContaining({ method: "POST" }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("renders shared chats as read-only message streams", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        chat: { id: 8, title: "Aqueduct planning" },
        messages: [
          {
            type: "message",
            id: 10,
            role: "user",
            tool_name: null,
            content: { text: "Can the team view this?" },
            text: "Can the team view this?",
            bookmarkable: false
          },
          {
            type: "message",
            id: 11,
            role: "assistant",
            tool_name: null,
            content: { text: "Yes, this is read-only." },
            text: "Yes, this is read-only.",
            bookmarkable: false
          }
        ]
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/shared/token-123"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Aqueduct planning" })).toBeInTheDocument()
    expect(screen.getByText("View only")).toBeInTheDocument()
    expect(screen.getByText("Can the team view this?")).toBeInTheDocument()
    expect(screen.getByText("Yes, this is read-only.")).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Ask about this repository...")).toBeNull()
    expect(screen.queryByRole("button", { name: /Bookmark/ })).toBeNull()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/shared_chats/token-123", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("updates the v2 sidebar immediately after chat slash commands change chats", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const initialChat = sidebarChat({
      id: 8,
      title: "Aqueduct planning",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      last_message_at: "2026-06-01T10:00:00Z"
    })
    const newSidebarChat = sidebarChat({
      id: 9,
      title: null,
      title_pending: true,
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      last_message_at: null
    })
    let sidebarChats = [initialChat]
    const renamedPayload = chatPayload({ message: "Chat renamed." })
    renamedPayload.chat.title = "Canal review"
    const newPayload = chatPayload({ id: 9, chatPath: "/chats/9" })
    newPayload.chat.title_pending = true
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        if (init?.method === "POST") {
          sidebarChats = [newSidebarChat, { ...initialChat, title: "Canal review" }]
          return Promise.resolve(new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/9", chat: newPayload.chat }), { status: 201, headers: { "Content-Type": "application/json" } }))
        }

        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(sidebarChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/rename" && init?.method === "PATCH") {
        sidebarChats = [{ ...initialChat, title: "Canal review" }]
        return Promise.resolve(new Response(JSON.stringify(renamedPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/9") {
        return Promise.resolve(new Response(JSON.stringify(newPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      expect(await within(recentNav).findByRole("link", { name: "Aqueduct planning" })).toBeInTheDocument()

      const input = await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.change(input, { target: { value: "/rename Canal review" } })
      fireEvent.click(screen.getByRole("button", { name: "Send message" }))
      expect(await within(recentNav).findByRole("link", { name: "Canal review" })).toBeInTheDocument()

      fireEvent.change(input, { target: { value: "/new" } })
      fireEvent.click(screen.getByRole("button", { name: "Send message" }))
      expect(await within(recentNav).findByRole("link", { name: "New chat" })).toHaveAttribute("href", "/app-shell/chats/9")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("confirms clear before deleting chat history", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ message: "Chat history cleared.", messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/clear" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(await screen.findByText("Clear this chat's message history?")).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/messages", expect.objectContaining({ method: "DELETE" }))

    fireEvent.click(screen.getByRole("button", { name: "Clear" }))
    expect(await screen.findByText("Chat history cleared.")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/messages", expect.objectContaining({ method: "DELETE" }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("handles panel and attachment system slash commands in the app", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/attachments" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ message: "acme/tools attached." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/settings" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))
    expect(await screen.findByRole("dialog", { name: "Chat settings" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close chat settings" }))

    fireEvent.change(input, { target: { value: "/attach acme/tools" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))
    expect(await screen.findByText("acme/tools attached.")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/attachments", expect.objectContaining({
      method: "POST",
      body: JSON.stringify({ attachable_type: "Repository", repository_slug: "acme/tools" })
    }))
    expect(screen.getByRole("heading", { name: "Attachments" })).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("updates the chat provider from chat settings", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8" && init?.method === "PATCH") {
        const body = JSON.parse(String(init.body))
        const chatProvider = body.chat.chat_provider || null
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          chatProvider,
          effectiveChatProvider: chatProvider || "claude"
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/settings" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const select = await screen.findByLabelText("Chat provider")
    expect(within(select).getByRole("option", { name: "Default" })).toHaveValue("")
    expect(within(select).getByRole("option", { name: "Claude" })).toHaveValue("claude")
    expect(within(select).getByRole("option", { name: "Codex" })).toHaveValue("codex")

    fireEvent.change(select, { target: { value: "codex" } })
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ chat: { chat_provider: "codex" } })
    })))

    fireEvent.change(await screen.findByLabelText("Chat provider"), { target: { value: "claude" } })
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ chat: { chat_provider: "claude" } })
    })))

    fireEvent.change(await screen.findByLabelText("Chat provider"), { target: { value: "" } })
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ chat: { chat_provider: null } })
    })))
  })

  it("files GitHub issues from the report slash command", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/report_issue" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ issue_url: "https://github.com/tkadauke/syrus/issues/123" }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/report" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const dialog = await screen.findByRole("dialog", { name: "File a GitHub issue about Syrus" })
    const bodyInput = within(dialog).getByLabelText("Body") as HTMLTextAreaElement
    expect(bodyInput.value).toContain("Chat: Aqueduct planning")
    expect(bodyInput.value).toContain("URL: http://localhost:3000/app-shell/chats/8")

    fireEvent.change(within(dialog).getByLabelText("Title"), { target: { value: "Report from chat" } })
    fireEvent.change(bodyInput, { target: { value: "Filed from chat context." } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Submit" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/report_issue",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ title: "Report from chat", body: "Filed from chat context." })
        })
      )
    })
    expect(await screen.findByText("Issue filed — https://github.com/tkadauke/syrus/issues/123")).toBeInTheDocument()
    expect(screen.queryByRole("dialog", { name: "File a GitHub issue about Syrus" })).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("sends registered skill slash commands as generated prompts through the normal chat message path", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/canvas" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ chat_message: { text: "Call the `read_scene` MCP tool and describe the current whiteboard contents, including notable shapes, text, connections, frames, and empty-state if there is nothing on the canvas." } })
        })
      )
    })
  })

  it("requires inline confirmation before executing mutating system slash commands", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/cancel 1095" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const confirmation = await screen.findByText("Confirm /cancel")
    expect(confirmation).toBeInTheDocument()
    expect(screen.getAllByText("/cancel 1095").length).toBeGreaterThan(0)
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/jobs/1095/cancel", expect.objectContaining({ method: "POST" }))

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/1095/cancel",
        expect.objectContaining({
          method: "POST"
        })
      )
    })
  })

  it("cancels mutating skill slash command confirmation without sending", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
    fireEvent.change(input, { target: { value: "/discard proposal-17" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(await screen.findByText("Confirm /discard")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.queryByText("Confirm /discard")).not.toBeInTheDocument()
    expect(input.value).toBe("/discard proposal-17")
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("sends /propose as a guided proposal wizard prompt", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(input, { target: { value: "/propose" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining("Start the guided Job proposal wizard.")
        })
      )
    })
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/chats/8/message",
      expect.objectContaining({
        body: expect.stringContaining("call the propose_job tool")
      })
    )
  })

  it("shows an animated chat agent activity indicator", async () => {
    vi.spyOn(Math, "random").mockReturnValue(0)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ agentBusy: true, turnInFlight: false })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const status = await screen.findByRole("status", { name: "thinking it through" })
    expect(status).toHaveTextContent("Cogitans")
    expect(screen.getByTitle("thinking it through")).toHaveTextContent("Cogitans")
  })

  it("enqueues and edits follow-up messages while the agent is busy", async () => {
    let queuedMessages: Array<Record<string, unknown>> = [
      {
        id: 14,
        text: "Already queued",
        created_at: "2026-06-01T10:05:00Z",
        app_update_path: "/api/v1/app/chats/8/queued_messages/14",
        app_delete_path: "/api/v1/app/chats/8/queued_messages/14"
      }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/queued_messages" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ agentBusy: true, queuedMessages })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/queued_messages/14" && init?.method === "PATCH") {
        queuedMessages = []
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ agentBusy: true, queuedMessages })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ agentBusy: true, turnInFlight: false, queuedMessages })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Queue a follow-up message...")
    fireEvent.change(input, { target: { value: "Check the forum routes" } })
    fireEvent.click(screen.getByRole("button", { name: "Enqueue message" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/queued_messages", expect.objectContaining({ method: "POST" })))

    fireEvent.click(screen.getByText("Already queued"))
    const editor = await screen.findByLabelText("Edit queued message 1")
    fireEvent.change(editor, { target: { value: "Check the aqueduct routes" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/queued_messages/14", expect.objectContaining({ method: "PATCH" })))

    const stop = await screen.findByRole("button", { name: "Stop agent" })
    expect(screen.queryByRole("button", { name: "Send message" })).not.toBeInTheDocument()
    expect(stop).toHaveClass("h-9", "px-3")
    expect(stop).not.toHaveClass("py-1.5", "px-4", "py-2")
  })

  it("shows a starting state before the chat agent process is running", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ agentBusy: false, turnInFlight: true })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const status = await screen.findByRole("status", { name: "girding itself" })
    expect(status).toHaveTextContent("Accingitur")
    expect(screen.getByTitle("girding itself")).toHaveTextContent("Accingitur")
  })

  it("keeps Stop acknowledged until chat controls broadcast completion", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/stop" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({
          agentBusy: true,
          stopRequestedAt: "2026-07-01T12:00:00Z"
        })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload({ agentBusy: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stop = await screen.findByRole("button", { name: "Stop agent" })
    fireEvent.click(stop)

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/stop", expect.objectContaining({ method: "POST" })))
    await waitFor(() => expect(stop).toBeDisabled())

    const subscriptionCalls = actionCable.createSubscription.mock.calls as unknown[][]
    const appEventSubscription = subscriptionCalls.at(-1)?.[1] as { received?: (event: unknown) => void } | undefined
    act(() => {
      appEventSubscription?.received?.({
        type: "chat.updated",
        resource: "chat",
        id: 8,
        changed: ["controls"],
        occurred_at: "2026-07-01T12:00:01.000Z",
        payload: {
          action: "update_controls",
          turn_in_flight: false,
          agent_busy: false,
          stop_requested_at: null,
          queued_messages: []
        }
      })
    })

    await waitFor(() => expect(screen.queryByRole("button", { name: "Stop agent" })).not.toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Send message" })).toBeInTheDocument()
  })

  it("grows the chat input up to five rows", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    input.style.lineHeight = "20px"
    input.style.paddingTop = "8px"
    input.style.paddingBottom = "8px"
    input.style.borderTopWidth = "1px"
    input.style.borderBottomWidth = "1px"

    Object.defineProperty(input, "scrollHeight", { configurable: true, value: 68 })
    fireEvent.change(input, { target: { value: "First line\nSecond line\nThird line" } })
    await waitFor(() => {
      expect(input).toHaveStyle({ height: "68px", overflowY: "hidden" })
    })

    Object.defineProperty(input, "scrollHeight", { configurable: true, value: 180 })
    fireEvent.change(input, { target: { value: "One\nTwo\nThree\nFour\nFive\nSix\nSeven" } })
    await waitFor(() => {
      expect(input).toHaveStyle({ height: "118px", overflowY: "auto" })
    })
  })

  it("saves chat whiteboard changes through the app API", async () => {
    excalidrawMock.updateScene.mockClear()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({
          scene_json: {
            elements: [{ id: "shape-react", type: "image", fileId: "file-react", version: 1 }],
            appState: { viewBackgroundColor: "#ffffff" },
            files: {
              "file-react": {
                id: "file-react",
                dataURL: "data:image/png;base64,abc",
                mimeType: "image/png",
                created: 1
              }
            }
          },
          version: 3
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Draw on whiteboard" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/whiteboard",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          body: JSON.stringify({
            elements: [
              { id: "box-1", type: "rectangle" },
              { id: "shape-react", type: "image", fileId: "file-react", version: 1 }
            ],
            appState: { viewBackgroundColor: "#ffffff" },
            files: {
              "file-react": {
                id: "file-react",
                dataURL: "data:image/png;base64,abc",
                mimeType: "image/png",
                created: 1
              }
            },
            expected_version: 2
          })
        })
      )
    })
    await waitFor(() => {
      expect(excalidrawMock.addFiles).toHaveBeenCalledWith([
        {
          id: "file-react",
          dataURL: "data:image/png;base64,abc",
          mimeType: "image/png",
          created: 1
        }
      ])
      expect(excalidrawMock.updateScene).toHaveBeenCalledWith({
        elements: [{ id: "shape-react", type: "image", fileId: "file-react", version: 1 }],
        appState: { viewBackgroundColor: "#ffffff" }
      })
    })
    expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()
  })

  it("shows whiteboard snapshots in media and loads one onto the canvas", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots" && init?.method == null) {
        return Promise.resolve(new Response(JSON.stringify({
          whiteboard_snapshots: [{
            id: 12,
            name: "Important milestone with a long enough title to truncate",
            snapshot_kind: "manual",
            element_count: 1,
            created_at: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString()
          }]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots/12") {
        return Promise.resolve(new Response(JSON.stringify({
          id: 12,
          name: "Important milestone",
          snapshot_kind: "manual",
          element_count: 1,
          created_at: "2026-06-26T10:00:00Z",
          scene_json: {
            elements: [{ id: "snapshot-box", type: "rectangle", boundElements: [{ id: "snapshot-label", type: "text" }] }],
            appState: { viewBackgroundColor: "#fff8" },
            files: { "file-snapshot": { id: "file-snapshot", mimeType: "image/png" } }
          }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method == null) {
        return Promise.resolve(new Response(JSON.stringify({
          scene_json: { elements: [{ id: "box-1", type: "rectangle" }], appState: {}, files: {} },
          version: 2
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          id: 13,
          name: "Before load",
          snapshot_kind: "auto_before_load",
          element_count: 1,
          created_at: "2026-06-26T11:00:00Z",
          scene_json: { elements: [{ id: "box-1", type: "rectangle" }], appState: {}, files: {} }
        }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({
          scene_json: {
            elements: [{ id: "box-1", type: "rectangle" }, { id: "fresh-snapshot-box", type: "rectangle", boundElements: [{ id: "fresh-snapshot-label", type: "text" }] }],
            appState: {},
            files: { "file-snapshot": { id: "file-snapshot", mimeType: "image/png" } }
          },
          version: 3
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Media" }))

    expect(await screen.findByText("Whiteboard Snapshots")).toBeInTheDocument()
    expect(screen.getByText("Saved")).toBeInTheDocument()
    expect(screen.getByText("1 element")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load" }))

    await waitFor(() => expect(screen.getByText("Loaded Important milestone onto canvas")).toBeInTheDocument())
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/whiteboard_snapshots",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining("\"snapshot_kind\":\"auto_before_load\"")
        })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/whiteboard",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining("\"expected_version\":2")
        })
      )
    })
  })

  it("does not push the initial whiteboard scene back through the imperative API", async () => {
    excalidrawMock.updateScene.mockClear()
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Draw on whiteboard" })).toBeInTheDocument()
    expect(excalidrawMock.updateScene).not.toHaveBeenCalled()
  })

  it("strips serialized collaborators before mounting the whiteboard", async () => {
    const payload = chatPayload()
    payload.whiteboard.appState = {
      viewBackgroundColor: "#ffffff",
      collaborators: {},
      selectedElementIds: { "box-1": true }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Draw on whiteboard" })).toBeInTheDocument()
    expect(excalidrawMock.lastInitialData?.appState).toEqual({ viewBackgroundColor: "#ffffff" })
  })

  it("keeps the chat visible when the whiteboard render fails", async () => {
    excalidrawMock.throwOnRender = true
    vi.spyOn(console, "error").mockImplementation(() => {})
    const preventExpectedCanvasError = (event: ErrorEvent) => {
      if (event.error instanceof Error && event.error.message === "Canvas crashed") event.preventDefault()
    }
    window.addEventListener("error", preventExpectedCanvasError)
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      expect(await screen.findByText("Whiteboard unavailable.")).toBeInTheDocument()
      expect(screen.getByPlaceholderText("Ask about this repository...")).toBeInTheDocument()
    } finally {
      excalidrawMock.throwOnRender = false
      window.removeEventListener("error", preventExpectedCanvasError)
    }
  })

  it("renders raw chat messages on the frontend", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({
        messages: [
          {
            type: "message",
            id: 10,
            role: "tool_use",
            tool_name: "Read",
            content: { input: { file_path: "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/models/chat.rb" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 11,
            role: "tool_result",
            tool_name: "Read",
            content: { result: [{ type: "text", text: "class Chat\nend" }] },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 20,
            role: "tool_use",
            tool_name: "Read",
            content: { input: { file_path: "/syrus-home/.syrus/workflows/5185/spec/rails_helper.rb" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 21,
            role: "tool_result",
            tool_name: "Read",
            content: { result: [{ type: "text", text: "1  # RSpec config\n2  RSpec.configure do |config|\n3    config.expect_with :rspec do |expectations|\n4      expectations.include_chain_clauses_in_custom_matcher_descriptions = true\n5    end\n6  end" }] },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 19,
            role: "tool_use",
            tool_name: "Bash",
            content: { input: { command: "rg queue_as /syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/jobs" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 22,
            role: "tool_use",
            tool_name: "Bash",
            content: { input: { command: "bin/rspec /syrus-home/.syrus/workflows/5185/spec/models/job_spec.rb" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 23,
            role: "tool_use",
            tool_name: "Bash",
            content: { input: { command: "rg perform /syrus-home/.syrus/workflows/42/app/jobs" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 24,
            role: "tool_use",
            tool_name: "Glob",
            content: { input: { pattern: "**/*.rb" } },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 25,
            role: "tool_result",
            tool_name: "Glob",
            content: {
              result: [{
                type: "text",
                text: [
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/models/chat.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/models/job.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/models/run.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/jobs/chat_turn_job.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/jobs/run_job.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/services/chat_workspace.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/services/workflow_workspace.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/spec/jobs/chat_turn_job_spec.rb",
                  "/syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/spec/services/chat_workspace_spec.rb"
                ].join("\n")
              }]
            },
            text: "",
            bookmarkable: false
          },
          {
            type: "message",
            id: 12,
            role: "system",
            tool_name: null,
            content: { text: "[result] subtype=success, is_error=false, turns=4, duration_ms=170223, total_cost_usd=0.37236969999999997" },
            text: "[result] subtype=success, is_error=false, turns=4, duration_ms=170223, total_cost_usd=0.37236969999999997",
            bookmarkable: false
          },
          {
            type: "message",
            id: 13,
            role: "system",
            tool_name: null,
            content: { text: "[result] subtype=error_max_turns, is_error=true, turns=50, duration_ms=1200" },
            text: "[result] subtype=error_max_turns, is_error=true, turns=50, duration_ms=1200",
            bookmarkable: false
          },
          {
            type: "message",
            id: 131,
            role: "system",
            tool_name: null,
            content: { text: "[result] subtype=success, is_error=true, turns=1, duration_ms=800" },
            text: "[result] subtype=success, is_error=true, turns=1, duration_ms=800",
            bookmarkable: false
          },
          {
            type: "message",
            id: 14,
            role: "system",
            tool_name: null,
            content: {
              text: "[mcp_servers] syrus-chat-sidecar=connected",
              mcp_health: [
                {
                  name: "syrus-chat-sidecar",
                  status: "connected",
                  available_tools: ["attach_repository", "propose_job", "repo_info"],
                  pending_tools: [],
                  unavailable_tools: []
                }
              ]
            },
            text: "[mcp_servers] syrus-chat-sidecar=connected",
            bookmarkable: false
          },
          {
            type: "message",
            id: 15,
            role: "system",
            tool_name: null,
            content: {
              text: "[mcp_servers] syrus-chat-sidecar=failed",
              mcp_health: [
                {
                  name: "syrus-chat-sidecar",
                  status: "failed",
                  available_tools: [],
                  pending_tools: [],
                  unavailable_tools: ["attach_repository", "propose_job", "repo_info"]
                }
              ]
            },
            text: "[mcp_servers] syrus-chat-sidecar=failed",
            bookmarkable: false
          },
          {
            type: "message",
            id: 16,
            role: "system",
            tool_name: null,
            content: {
              text: "[mcp_servers] syrus-chat-sidecar=pending",
              mcp_health: [
                {
                  name: "syrus-chat-sidecar",
                  status: "pending",
                  available_tools: [],
                  pending_tools: ["attach_repository", "propose_job", "repo_info"],
                  unavailable_tools: []
                }
              ]
            },
            text: "[mcp_servers] syrus-chat-sidecar=pending",
            bookmarkable: false
          },
          {
            type: "message",
            id: 17,
            role: "system",
            tool_name: null,
            content: { text: "[codex error] command timed out" },
            text: "[codex error] command timed out",
            bookmarkable: false
          },
          {
            type: "message",
            id: 18,
            role: "system",
            tool_name: null,
            content: { text: "Cancelled by operator." },
            text: "Cancelled by operator.",
            bookmarkable: false
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Read")).toBeInTheDocument()
    expect(screen.getAllByText(/app\/models\/chat\.rb/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/spec\/rails_helper\.rb/).length).toBeGreaterThan(0)
    expect(screen.getByText("# RSpec config")).toHaveClass("text-gray-400")
    expect(screen.getAllByText("do")[0]).toHaveClass("font-semibold", "text-blue-700")
    expect(screen.getByText(":rspec")).toHaveClass("text-violet-700")
    expect(screen.getByText("true")).toHaveClass("font-semibold", "text-blue-700")
    expect(screen.getByText("Bash")).toBeInTheDocument()
    expect(screen.getAllByText(/rg queue_as app\/jobs/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/bin\/rspec spec\/models\/job_spec\.rb/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/rg perform app\/jobs/).length).toBeGreaterThan(0)
    expect(screen.getByText("9 paths")).toBeInTheDocument()
    expect(screen.getByText(/spec\/services\/chat_workspace_spec\.rb/)).toBeInTheDocument()
    expect(screen.queryByText(/\/syrus-home\/\.syrus\/chat-workspaces/)).not.toBeInTheDocument()
    expect(screen.queryByText(/\/syrus-home\/\.syrus\/workflows/)).not.toBeInTheDocument()
    expect(screen.getAllByText("class")[0]).toHaveClass("font-semibold", "text-blue-700")
    expect(screen.getByText("Chat")).toHaveClass("text-cyan-700")
    expect(screen.getAllByText("end")[0]).toHaveClass("font-semibold", "text-blue-700")
    expect(screen.queryByText(/Agent run succeeded/)).not.toBeInTheDocument()
    expect(screen.queryByText(/MCP tools available: attach_repository, propose_job, repo_info/)).not.toBeInTheDocument()
    expect(screen.queryByText(/MCP still pending: syrus-chat-sidecar pending/)).not.toBeInTheDocument()
    expect(screen.queryByText(/check worker logs for chat sidecar startup/)).not.toBeInTheDocument()
    expect(screen.queryByText("Cancelled by operator.")).not.toBeInTheDocument()
    expect(screen.getByText(/Agent run failed: Error max turns/)).toBeInTheDocument()
    expect(screen.getByText(/^Agent run failed · 1 turn · 0\.8s$/)).toBeInTheDocument()
    expect(screen.queryByText(/Agent run failed: Success/)).not.toBeInTheDocument()
    expect(screen.getByText(/1\.2s/)).toBeInTheDocument()
    expect(screen.getByText(/MCP unavailable: syrus-chat-sidecar failed/)).toBeInTheDocument()
    expect(screen.getByText(/Retry the turn or check the chat sidecar logs/)).toBeInTheDocument()
    expect(screen.getByText("command timed out")).toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream")).toHaveClass("pt-12")
    fireEvent.click(screen.getByRole("button", { name: "Show 2 hidden system messages" }))
    expect(screen.getByText(/Agent run succeeded/)).toBeInTheDocument()
    expect(screen.getByText(/4 turns/)).toBeInTheDocument()
    expect(screen.getByText(/2\.8m/)).toBeInTheDocument()
    expect(screen.getByText(/\$0\.37/)).toBeInTheDocument()
    expect(screen.queryByText(/MCP tools available: attach_repository, propose_job, repo_info/)).not.toBeInTheDocument()
    expect(screen.getByText("Cancelled by operator.")).toBeInTheDocument()
  })

  it("keeps unmatched text tool results out of assistant message rendering", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({
        messages: [
          {
            type: "message",
            id: 10,
            role: "tool_result",
            tool_name: "tool_result",
            content: { result: [{ type: "text", text: "Perfect! Now I have all the information I need.\n\n## Queue setup\n\nThe report is ready." }] },
            text: "",
            bookmarkable: false
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("tool_result")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Queue setup" })).not.toBeInTheDocument()
  })

  it("renders Codex tool rows with descriptive tool labels", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({
        messages: [
          {
            type: "message",
            id: 10,
            role: "tool_use",
            tool_name: "mcp__syrus-chat-sidecar__repo_info",
            content: { input: { repository_id: 12, status: "started" } },
            text: "",
            bookmarkable: false
          }
        ]
      })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("repo_info")).toBeInTheDocument()
    expect(screen.queryByText("tool_use")).not.toBeInTheDocument()
  })

  it("runs chat commands through the app API", async () => {
    const search = "?attachment_type=Repository&attachment_query=tools"
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal proposed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "syrus_issue",
        kind_label: "Syrus issue",
        state: "proposed",
        state_label: "Proposed",
        title: "Map auth",
        slug: "auth-map",
        body: "Map the auth flow.",
        proposed: true,
        resolved: false,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependencies: [],
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null
      }
    }
    const pendingActionMessage = {
      ...chatPayload().messages[0],
      pending_action: {
        id: 7,
        label: "Cancel JOB-44",
        action: "cancel_job",
        state: "pending",
        resource_title: "Stop the aqueduct dig",
        resource_url: "/jobs/44",
        app_confirm_path: "/api/v1/app/chats/8/pending_actions/7/confirm",
        app_reject_path: "/api/v1/app/chats/8/pending_actions/7/reject"
      }
    }
    const initialPayload = {
      ...chatPayload({ messages: [pendingActionMessage, proposalMessage] }),
      attachment_results: [{ type: "Repository", id: 4, label: "acme/tools" }],
      pending_actions: []
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === `/api/v1/app/chats/8/bookmarks${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "Bookmarked Aqueduct marker.",
          bookmarks: [...initialPayload.bookmarks, { id: 2, label: "Aqueduct marker", chat_message_id: 9 }]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === `/api/v1/app/chats/8/attachments${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "acme/tools attached.",
          attachment_groups: {
            ...initialPayload.attachment_groups,
            repositories: [
              ...initialPayload.attachment_groups.repositories,
              { id: 4, label: "acme/tools", app_detach_path: "/api/v1/app/chats/8/attachments/4" }
            ]
          },
          attachment_results: []
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === `/api/v1/app/chats/8/attachments/2${search}` && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "acme/widgets detached.",
          attachment_groups: { ...initialPayload.attachment_groups, repositories: [] }
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === `/api/v1/app/chats/8/proposals/5/confirm${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "Proposal confirmed and filed as JOB-88.",
          messages: [initialPayload.messages[0], {
            ...proposalMessage,
            proposal: {
              ...proposalMessage.proposal,
              proposed: false,
              resolved: true,
              state: "confirmed",
              state_label: "Confirmed",
              materialized_label: "JOB-88",
              materialized_path: "/jobs/88",
              materialized: { kind: "job", job_id: 88, job_title: "Map auth", job_state: "open" }
            }
          }]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === `/api/v1/app/chats/8/pending_actions/7/confirm${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "Pending action confirmed.",
          messages: [{
            ...pendingActionMessage,
            pending_action: {
              ...pendingActionMessage.pending_action,
              state: "confirmed"
            }
          }, proposalMessage],
          pending_actions: []
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={[`/app-shell/chats/8${search}`]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Map auth")).toBeInTheDocument()
    const bookmarkButton = screen.getAllByRole("button", { name: "Bookmark" })[0]
    fireEvent.click(bookmarkButton)
    expect(screen.getByLabelText("Label")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByLabelText("Label")).not.toBeInTheDocument()
    fireEvent.click(bookmarkButton)
    expect(screen.getByLabelText("Label")).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByLabelText("Label")).not.toBeInTheDocument()
    fireEvent.click(bookmarkButton)
    fireEvent.change(screen.getByLabelText("Label"), { target: { value: "Aqueduct marker" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/bookmarks${search}`,
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ message_id: 9, chat_bookmark: { label: "Aqueduct marker" } })
        })
      )
    })
    expect(screen.queryByText("Bookmarked Aqueduct marker.")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(await screen.findByText("acme/tools"))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/attachments${search}`,
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ attachable_type: "Repository", attachable_id: 4 })
        })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "Context" }))
    fireEvent.click(screen.getByTitle("Detach acme/widgets"))
    expect(screen.getByRole("button", { name: "Detach acme/widgets?" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Detach acme/widgets?" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/attachments/2${search}`,
        expect.objectContaining({ method: "DELETE" })
      )
    })

    fireEvent.click(screen.getAllByRole("button", { name: "Confirm" })[1])
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/proposals/5/confirm${search}`,
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByRole("heading", { name: "Map auth" })).toBeInTheDocument()
    expect(screen.getAllByText("Confirmed").length).toBeGreaterThanOrEqual(2)
    expect(screen.getByRole("link", { name: "JOB-88" })).toHaveAttribute("href", "/app-shell/jobs/88")
    expect(screen.getByText((_, element) => element?.textContent === '→ JOB-88 "Map auth"')).toBeInTheDocument()
    const proposalNotice = await screen.findByRole("status")
    expect(proposalNotice).toHaveClass("fixed")
    expect(proposalNotice).toHaveTextContent("Proposal confirmed and filed as JOB-88.")
    fireEvent.click(within(proposalNotice).getByRole("button", { name: "Dismiss notification" }))
    await waitFor(() => {
      expect(screen.queryByText("Proposal confirmed and filed as JOB-88.")).not.toBeInTheDocument()
    })

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        `/api/v1/app/chats/8/pending_actions/7/confirm${search}`,
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByText("Pending action confirmed.")).toBeInTheDocument()
  })

  it("shows Copy button on chat messages and copies text to clipboard", async () => {
    const writeTextSpy = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", { value: { writeText: writeTextSpy }, configurable: true })

    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const copyButton = screen.getByRole("button", { name: "Copy" })
    expect(copyButton).toBeInTheDocument()
    fireEvent.click(copyButton)
    await waitFor(() => {
      expect(writeTextSpy).toHaveBeenCalledWith("Discuss aqueducts.")
    })
  })

  it("shows relative timestamp on chat message with created_at within the last hour", async () => {
    const recentCreatedAt = new Date(Date.now() - 4 * 60 * 1000).toISOString()
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "assistant",
          tool_name: null,
          content: { text: "Discuss aqueducts." },
          text: "Discuss aqueducts.",
          bookmarkable: true,
          created_at: recentCreatedAt
        }
      ]
    })), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent("4m ago")
    expect(timeEl).toHaveAttribute("dateTime", recentCreatedAt)
  })

  it("shows absolute timestamp on chat message with created_at more than 24 hours ago (same year)", async () => {
    const now = new Date()
    const pastDate = new Date(now.getFullYear(), 0, 15, 10, 29, 0)
    const oldCreatedAt = pastDate.toISOString()
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "assistant",
          tool_name: null,
          content: { text: "Discuss aqueducts." },
          text: "Discuss aqueducts.",
          bookmarkable: true,
          created_at: oldCreatedAt
        }
      ]
    })), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent("1/15 10:29am")
    expect(timeEl).toHaveAttribute("dateTime", oldCreatedAt)
  })

  it("shows year in timestamp on chat message with created_at from a previous year", async () => {
    const previousYearDate = new Date(new Date().getFullYear() - 1, 6, 5, 22, 29, 0)
    const oldCreatedAt = previousYearDate.toISOString()
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "assistant",
          tool_name: null,
          content: { text: "Discuss aqueducts." },
          text: "Discuss aqueducts.",
          bookmarkable: true,
          created_at: oldCreatedAt
        }
      ]
    })), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent(`7/5/${new Date().getFullYear() - 1} 10:29pm`)
    expect(timeEl).toHaveAttribute("dateTime", oldCreatedAt)
  })

  it("renders pending action cards inline in chat messages", async () => {
    const pendingMessage = {
      type: "message",
      id: 12,
      role: "assistant",
      tool_name: null,
      content: { text: "This needs confirmation." },
      text: "This needs confirmation.",
      bookmarkable: true,
      pending_action: {
        id: 7,
        label: "Cancel job",
        detail: "Cancel **this job** before it lands.\n\n- Notify reviewers.",
        action: "cancel_job",
        state: "pending",
        resource_title: "Refactor checkout flow",
        resource_url: "/jobs/44",
        app_confirm_path: "/api/v1/app/chats/8/pending_actions/7/confirm",
        app_reject_path: "/api/v1/app/chats/8/pending_actions/7/reject"
      }
    }
    const confirmedMessage = {
      type: "message",
      id: 13,
      role: "assistant",
      tool_name: null,
      content: { text: "Already handled." },
      text: "Already handled.",
      bookmarkable: true,
      pending_action: {
        id: 8,
        label: "Retry job",
        action: "retry_job",
        state: "confirmed",
        resource_title: "Retry flaky build",
        resource_url: "/jobs/45",
        app_confirm_path: "/api/v1/app/chats/8/pending_actions/8/confirm",
        app_reject_path: "/api/v1/app/chats/8/pending_actions/8/reject"
      }
    }
    const rejectedMessage = {
      type: "message",
      id: 14,
      role: "assistant",
      tool_name: null,
      content: { text: "No link action." },
      text: "No link action.",
      bookmarkable: true,
      pending_action: {
        id: 9,
        label: "Submit feedback",
        action: "submit_chat_feedback",
        state: "rejected",
        app_confirm_path: "/api/v1/app/chats/8/pending_actions/9/confirm",
        app_reject_path: "/api/v1/app/chats/8/pending_actions/9/reject"
      }
    }
    const payload = chatPayload({
      messages: [pendingMessage, confirmedMessage, rejectedMessage]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/pending_actions/7/reject" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...payload,
          messages: [{
            ...pendingMessage,
            pending_action: { ...pendingMessage.pending_action, state: "rejected" }
          }, confirmedMessage, rejectedMessage]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("This needs confirmation.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Cancel job" })).toBeInTheDocument()
    expect(screen.getByText((_content, element) => element?.tagName === "P" && element.textContent === "Cancel this job before it lands.")).toBeInTheDocument()
    expect(screen.getByText("this job").tagName).toBe("STRONG")
    expect(screen.getByText("Notify reviewers.").tagName).toBe("LI")
    expect(screen.getByRole("link", { name: "Refactor checkout flow" })).toHaveAttribute("href", "/jobs/44")
    expect(screen.getByRole("button", { name: "Confirm" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Decline" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Retry job" })).toBeInTheDocument()
    expect(screen.getAllByText("Confirmed").length).toBeGreaterThan(0)
    expect(screen.getByRole("heading", { name: "Submit feedback" })).toBeInTheDocument()
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    expect(screen.queryByRole("link", { name: "Submit feedback" })).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Decline" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/pending_actions/7/reject",
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("renders proposal dependency pills with confirmed and pending badges", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal proposed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "syrus_issue",
        kind_label: "Syrus issue",
        state: "proposed",
        state_label: "Proposed",
        title: "Search cards",
        slug: "search-cards",
        body: "Show dependency status.",
        proposed: true,
        resolved: false,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependency_slugs: ["chat-search-fts5", "agent-memory"],
        dependencies: [
          {
            slug: "chat-search-fts5",
            title: "Chat FTS5 infrastructure",
            state: "confirmed",
            confirmed: true,
            anchor_message_id: 9,
            materialized_path: "/jobs/41"
          },
          {
            slug: "agent-memory",
            title: "Agent Memory System",
            state: "proposed",
            confirmed: false,
            anchor_message_id: null,
            materialized_path: null
          },
          {
            slug: "foundation-epic",
            title: "foundation-epic",
            display_label: "foundation-epic",
            state: "unresolved",
            confirmed: false,
            anchor_message_id: null,
            materialized_path: null
          },
          {
            slug: "epic:42",
            title: "EPIC-42",
            display_label: "EPIC-42",
            state: "ready",
            confirmed: true,
            anchor_message_id: null,
            materialized_path: "/epics/42"
          }
        ],
        has_dependencies: true,
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null
      }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Depends on:")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Chat FTS5 infrastructure ✓" })).toHaveAttribute("href", "#message-9")
    expect(screen.getByText("Agent Memory System ⏳")).toBeInTheDocument()
    expect(screen.getByText("foundation-epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-42" })).toHaveAttribute("href", "/app-shell/epics/42")
  })

  it("renders a muted no-dependencies strip on proposal cards", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal proposed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "job",
        kind_label: "Job",
        state: "proposed",
        state_label: "Proposed",
        title: "Map auth",
        slug: "map-auth",
        body: "Map it.",
        proposed: true,
        resolved: false,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependency_slugs: [],
        dependencies: [],
        has_dependencies: false,
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null
      }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No dependencies")).toHaveClass("text-gray-500")
  })

  it("renders queued pending actions as waiting without action buttons", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...chatPayload({
          pendingActions: [
            pendingAction({ id: 7, label: "Send feedback to JOB-44", state: "queued" })
          ]
        })
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "JOB-44" })).toHaveAttribute("href", "/jobs/44")
    expect(screen.getByText("Waiting...")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument()
  })

  it("renders pending actions after their linked message in the stream", async () => {
    const userMessage = {
      type: "message",
      id: 11,
      role: "user",
      tool_name: null,
      content: { text: "Please send this feedback." },
      text: "Please send this feedback.",
      bookmarkable: true
    }
    const linkedMessage = {
      type: "message",
      id: 12,
      role: "assistant",
      tool_name: null,
      content: { text: "Feedback queued for confirmation." },
      text: "Feedback queued for confirmation.",
      bookmarkable: true
    }
    const laterMessage = {
      type: "message",
      id: 13,
      role: "assistant",
      tool_name: null,
      content: { text: "A later assistant message." },
      text: "A later assistant message.",
      bookmarkable: true
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...chatPayload({
          messages: [userMessage, linkedMessage, laterMessage],
          pendingActions: [
            pendingAction({ id: 7, label: "Send feedback to JOB-44", detail: "Please **tighten** this implementation.\n\n- Use focused tests.", chatMessageId: 12 })
          ]
        })
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const linkedText = await screen.findByText("Feedback queued for confirmation.")
    const actionHeading = screen.getByRole("heading", { name: "Send feedback to JOB-44" })
    const laterText = screen.getByText("A later assistant message.")
    const linkedArticle = linkedText.closest("article")!
    const actionCard = actionHeading.closest("article")!
    const laterArticle = laterText.closest("article")!

    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
    expect(linkedArticle.compareDocumentPosition(actionCard) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(actionCard.compareDocumentPosition(laterArticle) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getByRole("link", { name: "JOB-44" })).toHaveAttribute("href", "/jobs/44")
    expect(screen.getByText((_content, element) => element?.tagName === "P" && element.textContent === "Please tighten this implementation.")).toBeInTheDocument()
    expect(screen.getByText("tighten").tagName).toBe("STRONG")
    expect(screen.getByText("Use focused tests.").tagName).toBe("LI")
  })

  it("renders unanchored pending actions after the last message", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...chatPayload({
          messages: [
            { ...chatPayload().messages[0], id: 11, text: "First message.", content: { text: "First message." } },
            { ...chatPayload().messages[0], id: 12, text: "Last message.", content: { text: "Last message." } }
          ],
          pendingActions: [
            pendingAction({ id: 7, label: "Send feedback to JOB-44", chatMessageId: null })
          ]
        })
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const lastText = await screen.findByText("Last message.")
    const actionHeading = screen.getByRole("heading", { name: "Send feedback to JOB-44" })
    expect(lastText.closest("article")!.compareDocumentPosition(actionHeading.closest("article")!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
  })

  it("renders terminal pending actions as read-only badges", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...chatPayload({
          pendingActions: [
            pendingAction({ id: 7, label: "Cancel JOB-44", state: "confirmed" }),
            pendingAction({ id: 8, label: "Retry JOB-45", state: "rejected" }),
            pendingAction({ id: 9, label: "Rebase JOB-46", state: "cancelled" })
          ]
        })
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Cancel JOB-44")).toBeInTheDocument()
    expect(screen.getAllByText("Confirmed").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Cancelled").length).toBeGreaterThan(0)
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument()
  })

  it("links confirmed Epic proposals to the Epic detail route", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Epic proposal confirmed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "epic",
        kind_label: "Epic",
        state: "confirmed",
        state_label: "Confirmed",
        title: "Raise the forum",
        slug: "raise-the-forum",
        body: "Let the forum stand.",
        proposed: false,
        resolved: true,
        epic_bundle: true,
        scoped_repository_slug: "acme/widgets",
        dependencies: [],
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: "EPIC-11",
        materialized_path: "/epics/11",
        materialized: {
          kind: "epic",
          epic_id: 11,
          epic_title: "Raise the forum",
          child_jobs: [
            { job_id: 154, title: "Add inspection tools" },
            { job_id: 155, title: "Add trigger" }
          ]
        },
        active_children_count: 0,
        children: []
      }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "#11" })).toHaveAttribute("href", "/app-shell/epics/11")
    expect(screen.getByText((_, element) => element?.textContent === '→ Epic #11 "Raise the forum"')).toBeInTheDocument()
    expect(screen.getByText((_, element) => element?.textContent === 'Jobs: JOB-154 "Add inspection tools", JOB-155 "Add trigger"')).toBeInTheDocument()
  })

  it("shows rejected proposal state on proposal cards", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal rejected.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "job",
        kind_label: "Job",
        state: "rejected",
        state_label: "Rejected",
        title: "Map auth",
        slug: "map-auth",
        body: "Map it.",
        proposed: false,
        resolved: true,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependencies: [],
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null,
        materialized: { kind: "rejected", reason: "rejected" }
      }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Map auth" })).toBeInTheDocument()
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    expect(screen.queryByText(/Job\s+#/)).not.toBeInTheDocument()
  })

  it("loads older chat messages when scrolling near the top", async () => {
    const restoreSize = stubChatStreamSize({ scrollHeight: 1200, clientHeight: 600 })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(new Response(JSON.stringify({
          has_more_older: false,
          messages: [
            {
              type: "message",
              id: 4,
              role: "assistant",
              text: "Earlier **aqueduct** note.",
              bookmarkable: true
            }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload({ hasMoreOlder: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const stream = await screen.findByTestId("chat-message-stream")
      expect(screen.queryByRole("button", { name: "Load older messages" })).not.toBeInTheDocument()
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 600, scrollTop: 24 })
      fireEvent.scroll(stream)

      expect(await screen.findByText("aqueduct")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/messages?before=9",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreSize()
    }
  })

  it("loads older chat messages when the initial transcript does not fill the viewport", async () => {
    const restoreSize = stubChatStreamSize({ scrollHeight: 420, clientHeight: 600 })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(new Response(JSON.stringify({
          has_more_older: false,
          messages: [
            {
              type: "message",
              id: 4,
              role: "assistant",
              text: "Earlier **aqueduct** note.",
              bookmarkable: true
            }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload({ hasMoreOlder: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(screen.queryByRole("button", { name: "Load older messages" })).not.toBeInTheDocument()
      expect(await screen.findByText("aqueduct")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/messages?before=9",
        expect.objectContaining({
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    } finally {
      restoreSize()
    }
  })

  it("renders active chat bookmarks from the v2 sidebar cache", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView })
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const initialPayload = chatPayload({ hasMoreOlder: true })
    initialPayload.bookmarks = [
      { id: 7, label: "Earlier aqueduct note", chat_message_id: 4, anchor_message_id: 5 }
    ]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(new Response(JSON.stringify({
          has_more_older: false,
          messages: [
            {
              type: "message",
              id: 5,
              role: "assistant",
              text: "Earlier **aqueduct** note.",
              bookmarkable: true
            }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      fireEvent.click(await screen.findByRole("button", { name: "Chat actions for Aqueduct planning" }))
      expect(screen.getByText("Bookmarks")).toHaveClass("font-semibold")
      const bookmark = await screen.findByRole("link", { name: "Earlier aqueduct note" })
      expect(bookmark).toHaveAttribute("href", "#message-5")
      fireEvent.click(bookmark)
      expect(screen.queryByRole("link", { name: "Earlier aqueduct note" })).not.toBeInTheDocument()
      expect(scrollIntoView).not.toHaveBeenCalled()
      expect(fetchSpy).not.toHaveBeenCalledWith(
        "/api/v1/app/chats/8/messages?before=9",
        expect.anything()
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders inactive chat bookmarks from the v2 sidebar cache with chat deep links", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const inactivePayload = chatPayload({ id: 11, chatPath: "/chats/11" })
    inactivePayload.bookmarks = [
      { id: 12, label: "Inactive aqueduct note", chat_message_id: 13, anchor_message_id: 13 }
    ]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      }),
      sidebarChat({
        id: 11,
        title: "Canal follow-up",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      })
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    queryClient.setQueryData(["chats", "11", ""], inactivePayload)

    try {
      render(
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      fireEvent.click(await within(recentNav).findByRole("button", { name: "Chat actions for Canal follow-up" }))
      expect(within(recentNav).getByText("Bookmarks")).toHaveClass("font-semibold")
      expect(within(recentNav).queryByText("No bookmarks yet")).not.toBeInTheDocument()
      expect(within(recentNav).getByRole("link", { name: "Inactive aqueduct note" })).toHaveAttribute("href", "/app-shell/chats/11#message-13")
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("fetches inactive chat bookmarks from the v2 sidebar menu when uncached", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      current_user: {
        ...bootstrapPayload().current_user,
      },
      feature_flags: {
        v2_ui: true
      }
    }))
    document.body.appendChild(script)
    const inactivePayload = chatPayload({ id: 11, chatPath: "/chats/11" })
    inactivePayload.bookmarks = [
      { id: 12, label: "Inactive aqueduct note", chat_message_id: 13, anchor_message_id: 13 }
    ]
    const recentChats = [
      sidebarChat({
        id: 8,
        title: "Aqueduct planning",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-18T12:00:00Z"
      }),
      sidebarChat({
        id: 11,
        title: "Canal follow-up",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        last_message_at: "2026-06-17T12:00:00Z"
      })
    ]
    let resolveInactiveChat: (response: Response) => void = () => undefined
    const inactiveChatRequest = new Promise<Response>((resolve) => {
      resolveInactiveChat = resolve
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: sidebarGroups(recentChats), repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/11") {
        return inactiveChatRequest
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const recentNav = await screen.findByRole("navigation", { name: "Recent chats" })
      fireEvent.click(await within(recentNav).findByRole("button", { name: "Chat actions for Canal follow-up" }))
      expect(within(recentNav).getByText("Loading bookmarks...")).toBeInTheDocument()

      await act(async () => {
        resolveInactiveChat(new Response(JSON.stringify(inactivePayload), { status: 200, headers: { "Content-Type": "application/json" } }))
        await inactiveChatRequest
      })

      expect(await within(recentNav).findByRole("link", { name: "Inactive aqueduct note" })).toHaveAttribute("href", "/app-shell/chats/11#message-13")
      expect(within(recentNav).queryByText("Loading bookmarks...")).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/11",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("scrolls to a message_id deep link and clears it from the chat URL", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView })
    const initialPayload = chatPayload()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(new Response(JSON.stringify(initialPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8?message_id=9"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await waitFor(() => expect(scrollIntoView).toHaveBeenCalled())
      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8",
        expect.objectContaining({ credentials: "same-origin" })
      ))
    } finally {
      fetchSpy.mockRestore()
    }
  })

})

// A signed-in operator partway through onboarding: credentials + repo done,
// but the onboarding chat has not started and no Epic has landed.
function incompleteOnboardingBootstrap() {
  return bootstrapPayload({
    setup: setupStatusPayload({ complete: false, chat_started: false, next_step: "chat" }),
    setup_status: setupStatus({
      state: "ready_for_first_chat",
      next_step: "start_first_chat",
      next_step_path: "/onboarding",
      first_successful_job_completed: false,
      first_epic_created: false,
      first_epic_started: false,
      first_epic_landed: false,
      onboarding_chat_started: false
    })
  })
}

function bootstrapPayload(overrides: Record<string, unknown> & { setupStatus?: ReturnType<typeof bootstrapSetupStatusPayload> | null } = {}) {
  const {
    setupStatus: setupStatusOverride,
    setup_status: setupStatusPayloadOverride,
    ...payloadOverrides
  } = overrides

  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      name: "Operator",
      first_name: null,
      last_name: null,
      display_name: "Operator",
      admin: true,
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      agent_max_turns: 200,
      theme: "light",
    },
    team_user_count: 1,
    app: {
      revision: "dev",
      revision_url: null
    },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    navigation: {
      default_chat_path: "/chats/9"
    },
    setup: setupStatusPayload({
      complete: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: [
          { key: "credentials", label: "Add credentials", complete: true },
          { key: "repository", label: "Add a repository", complete: true },
          { key: "first_job", label: "Start the first Job", complete: true },
          { key: "watch_job", label: "Watch the first successful Job or PR", complete: true }
        ]
      }
    }),
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    setup_status: setupStatusOverride ?? (setupStatusPayloadOverride as ReturnType<typeof bootstrapSetupStatusPayload> | undefined) ?? defaultSetupStatus(),
    feature_flags: {},
    ...payloadOverrides
  }
}

function defaultSetupStatus() {
  return setupStatus()
}

function setupStatus(overrides: Record<string, unknown> = {}) {
  return {
    state: "first_successful_job",
    next_step: null,
    next_step_path: null,
    first_admin: true,
    credentials_configured: true,
    repository_configured: true,
    first_job_started: true,
    first_successful_job_completed: true,
    first_epic_created: true,
    first_epic_started: true,
    first_epic_landed: true,
    onboarding_chat_started: true,
    credential_status: {
      github: true,
      agent: true,
      active_agent_provider: "claude"
    },
    readiness: {
      status: "ok",
      checks: []
    },
    counts: {
      repositories: 1,
      jobs: 1,
      successful_jobs: 1
    },
    ...overrides
  }
}

function setupStatusPayload(overrides: Record<string, unknown> = {}) {
  return {
    complete: false,
    chat_started: false,
    onboarding_chat_path: null,
    next_step: "credentials",
    progress: {
      completed: 0,
      total: 4,
      steps: [
        { key: "credentials", label: "Add credentials", complete: false },
        { key: "repository", label: "Add a repository", complete: false },
        { key: "chat", label: "Meet Syrus in chat", complete: false },
        { key: "epic", label: "Land your first Epic", complete: false }
      ]
    },
    credentials: {
      github_token: false,
      selected_agent_provider: "claude",
      selected_agent_provider_configured: false,
      configured_agent_providers: [],
      ready: false
    },
    system: {
      data_root: "~/.syrus",
      revision: "dev",
      polling_paused: false,
      runs_paused: false,
      ready: true
    },
    github_app: {
      registered: false,
      explanation: "Repositories use a GitHub App installation when one is active for that owner. Syrus falls back to your GitHub PAT for repositories without an active installation.",
      register_path: "/admin/github_app/register",
      installations_path: "/admin/installations"
    },
    repositories: {
      active_count: 0,
      any_app_credential_active: false,
      any_pat_fallback: false,
      first: null
    },
    first_job: {
      any: false,
      successful: false,
      job: null
    },
    paths: {
      setup_path: "/setup",
      credentials_path: "/credentials",
      new_repository_path: "/repositories/new",
      repositories_path: "/repositories",
      new_job_path: "/jobs/new",
      dashboard_jobs_path: "/dashboard/jobs"
    },
    ...overrides
  }
}

// Marks the jsdom navigator as the desktop shell (isDesktopShell matches the
// SyrusDesktop/ UA token). Returns a restore function — call it in finally.
function stubDesktopUserAgent() {
  const original = window.navigator.userAgent
  Object.defineProperty(window.navigator, "userAgent", {
    value: `${original} SyrusDesktop/1.0`,
    configurable: true
  })
  return () => {
    Object.defineProperty(window.navigator, "userAgent", { value: original, configurable: true })
  }
}

function publicBootstrapPayload(overrides: Partial<BootstrapPayload["public"]> = {}) {
  return {
    ...bootstrapPayload(),
    current_user: null,
    navigation: {
      default_chat_path: "/session/new"
    },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose",
      ...overrides
    }
  }
}

function bootstrapSetupStatusPayload(overrides: { nextStep?: "configure_credentials" | "add_repository" | "start_first_job" | "watch_first_job" | null } = {}) {
  const nextStep = overrides.nextStep ?? "start_first_job"
  const nextStepPath = {
    configure_credentials: "/credentials",
    add_repository: "/repositories/new",
    start_first_job: "/jobs/new",
    watch_first_job: "/dashboard/jobs?view=list"
  }[nextStep || "start_first_job"] || null

  return {
    state: nextStep === "configure_credentials" ? "not_started" : nextStep === "add_repository" ? "credentials_only" : nextStep === "start_first_job" ? "ready_for_first_job" : nextStep === "watch_first_job" ? "first_job_started" : "first_successful_job",
    next_step: nextStep,
    next_step_path: nextStep ? nextStepPath : null,
    first_admin: false,
    credentials_configured: nextStep !== "configure_credentials",
    repository_configured: nextStep === "start_first_job" || nextStep === "watch_first_job" || nextStep === null,
    first_job_started: nextStep === "watch_first_job" || nextStep === null,
    first_successful_job_completed: nextStep === null,
    credential_status: {
      github: nextStep !== "configure_credentials",
      agent: nextStep !== "configure_credentials",
      active_agent_provider: "claude"
    },
    readiness: {
      status: "ok",
      checks: []
    },
    counts: {
      repositories: nextStep === "add_repository" || nextStep === "configure_credentials" ? 0 : 1,
      jobs: nextStep === "watch_first_job" || nextStep === null ? 1 : 0,
      successful_jobs: nextStep === null ? 1 : 0
    }
  }
}

function scheduledTaskOptions() {
  return {
    kinds: ["cron", "one_shot"],
    pr_pileup_policies: ["skip", "pile", "replace"],
    auto_approve_modes: [
      { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
      { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." }
    ]
  }
}

function scheduledTaskDetailPayload(overrides: { state?: string; message?: string } = {}) {
  return {
    task: {
      id: 12,
      name: "Weekly tests",
      kind: "cron",
      state: overrides.state || "scheduled",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      schedule_label: "0 9 * * 1",
      last_fired_at: null,
      archived_at: null,
      consecutive_failure_count: 0,
      scheduled_task_path: "/scheduled_tasks/12",
      prompt: "Keep tests moving.",
      cron_expression: "0 9 * * 1",
      hourly_cron_expression: "0 9 * * 1",
      fire_at: null,
      next_fire_at: "2026-05-31T09:17:00Z",
      pr_pileup_policy: "skip",
      auto_approve_mode: "never",
      auto_approve_preview: "No direct rule; Jobs can still inherit a repository or user default.",
      last_successful_fire_at: null,
      archived: false,
      fireable: true,
      pausable: overrides.state !== "paused",
      resumable: overrides.state === "paused",
      editable: true
    },
    recent_jobs: [
      {
        id: 44,
        state: "open",
        closure_reason: null,
        pr_number: 101,
        external_pr_number: null,
        created_at: "2026-05-30T12:00:00Z",
        job_path: "/jobs/44"
      }
    ],
    options: scheduledTaskOptions(),
    message: overrides.message
  }
}

function repositoryScheduledTasksPayload(overrides: { state?: string; active?: boolean; message?: string } = {}) {
  const detail = scheduledTaskDetailPayload({ state: overrides.state || "scheduled" }).task
  return {
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    tabs: repositoryTabsPayload(3),
    tasks: [
      {
        ...detail,
        name: "Daily review",
        prompt: "Review the project.",
        active: overrides.active ?? true
      }
    ],
    new_scheduled_task_path: "/repositories/3/scheduled_tasks/new",
    options: scheduledTaskOptions(),
    message: overrides.message
  }
}

function profilePayload(overrides: Record<string, unknown> = {}) {
  return {
    team_user_count: 2,
    profile: {
      id: 2,
      first_name: "Ada",
      last_name: "Lovelace",
      display_name: "Ada Lovelace",
      github_handle: "ada-lovelace",
      role_label: "Operator",
      profile_bio: "Mathematician and operator.",
      profile_location: "London",
      profile_company: "Analytical Engines Ltd",
      profile_website: "https://example.com/ada",
      avatar_url: null,
      counts: { repositories: 1, epics: 2, jobs: 3, open_jobs: 1 },
      profile_path: "/profiles/2",
      repositories: [
        { id: 3, slug: "acme/widgets", path: "/repositories/3" }
      ],
      epics: [],
      jobs: [
        {
          id: 55,
          title: "Add profile page",
          state: "running",
          kind: "issue",
          repository: { id: 3, slug: "acme/widgets", path: "/repositories/3" },
          updated_at: "2026-05-30T12:00:00Z",
          path: "/jobs/55",
          owner: {
            id: 2,
            display_name: "Ada Lovelace",
            profile_path: "/profiles/2"
          }
        }
      ],
      recent_activity: [],
      ...overrides
    }
  }
}

function credentialsPayload(overrides: {
  name?: string
  apiToken?: boolean
  newApiToken?: string
  message?: string
  agentProvider?: string
  chatProvider?: string | null
  chatProviders?: string[]
  codexAuthMode?: string
  codexAuthJson?: boolean
  schedulingPaused?: boolean
  desktopJobImplemented?: boolean
  desktopJobFailed?: boolean
} = {}) {
  return {
    user: {
      id: 1,
      email_address: "operator@example.com",
      name: overrides.name ?? "Operator",
      first_name: null,
      last_name: null,
      profile_bio: null,
      profile_location: null,
      profile_company: null,
      profile_website: null,
      display_name: overrides.name ?? "Operator",
      github_handle: "operator",
      admin: true,
      agent_provider: overrides.agentProvider ?? "claude",
      chat_provider: overrides.chatProvider ?? null,
      codex_auth_mode: overrides.codexAuthMode ?? "api_key",
      agent_max_turns: 200,
      scheduling_paused: overrides.schedulingPaused ?? false,
      auto_approve_mode: "never",
      notification_preferences: {
        desktop_job_implemented: overrides.desktopJobImplemented ?? true,
        desktop_job_failed: overrides.desktopJobFailed ?? true
      }
    },
    credential_status: {
      github_token: true,
      claude_oauth_token: true,
      codex_api_key: false,
      codex_auth_json: overrides.codexAuthJson ?? false,
      api_token: overrides.apiToken ?? false
    },
    github_rate_limit: {
      remaining: 4999,
      limit: 5000,
      resource: "core",
      reset_at: "2026-05-30T13:00:00Z",
      observed_at: "2026-05-30T12:00:00Z"
    },
    options: {
      agent_providers: ["claude", "codex"],
      chat_providers: overrides.chatProviders ?? ["claude"],
      codex_auth_modes: ["api_key", "chatgpt_login"],
      agent_max_turns: { min: 0, max: 1000 },
      clearable_credentials: [
        { value: "github_token", label: "GitHub token" },
        { value: "claude_oauth_token", label: "Claude OAuth token" }
      ],
      auto_approve_modes: [
        { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
        { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." }
      ]
    },
    message: overrides.message,
    new_api_token: overrides.newApiToken
  }
}

function notificationPreferencesPayload(overrides: Partial<Record<"job_failed" | "job_implemented" | "desktop_job_failed" | "desktop_job_implemented" | "pr_comment_addressed" | "pr_merged" | "epic_completed", boolean>> & { message?: string } = {}) {
  return {
    notification_preferences: {
      job_failed: overrides.job_failed ?? true,
      job_implemented: overrides.job_implemented ?? true,
      desktop_job_failed: overrides.desktop_job_failed ?? true,
      desktop_job_implemented: overrides.desktop_job_implemented ?? true,
      pr_comment_addressed: overrides.pr_comment_addressed ?? true,
      pr_merged: overrides.pr_merged ?? true,
      epic_completed: overrides.epic_completed ?? false
    },
    message: overrides.message
  }
}

function personalDocumentsPayload(overrides: {
  documents?: Array<Record<string, unknown>>
  message?: string
} = {}) {
  return {
    documents: overrides.documents || [],
    message: overrides.message
  }
}

function repositoryDocumentsPayload(overrides: {
  documents?: Array<Record<string, unknown>>
  message?: string
} = {}) {
  return {
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    tabs: repositoryTabsPayload(3),
    documents: overrides.documents || [],
    accepted_file_content_types: ["text/markdown", "application/pdf", "image/png"],
    message: overrides.message
  }
}

function directJobFormPayload() {
  return {
    repositories: [
      {
        id: 3,
        slug: "acme/widgets",
        repository_path: "/repositories/3",
        default_agent_provider: "codex",
        default_agent_provider_label: "Codex"
      }
    ],
    configured_agent_providers: [
      { value: "claude", label: "Claude Code" },
      { value: "codex", label: "Codex" }
    ],
    selected_repository_id: "3",
    selected_agent_provider: null,
    create_more: true,
    prompt_templates: [
      {
        id: "configure-syrus-prep",
        name: "Configure Syrus build dependencies",
        description: "Detect package managers and write .syrus.yml.",
        prompt: "Write a .syrus.yml setup file."
      }
    ],
    priorities: [
      { value: "high", label: "High", description: "Runs before medium and low" },
      { value: "medium", label: "Medium", description: "Default" },
      { value: "low", label: "Low", description: "Yields to higher-priority jobs" }
    ],
    accepted_file_content_types: ["text/markdown", "application/pdf", "image/png"],
    new_repository_path: "/repositories/new",
    dashboard_jobs_path: "/dashboard/jobs"
  }
}

function repositoriesPayload(overrides: {
  active_repositories?: Array<Record<string, unknown>>
  archived_repositories?: Array<Record<string, unknown>>
  message?: string
  setup?: Record<string, unknown>
} = {}) {
  return {
    active_repositories: overrides.active_repositories ?? [
      {
        id: 3,
        slug: "acme/widgets",
        owner: "acme",
        name: "widgets",
        owner_user: {
          id: 9,
          display_name: "Operator",
          email_address: "operator@example.com",
          admin: true,
          profile_path: "/profiles/9"
        },
        default_branch: "main",
        upstream_owner: "rails",
        upstream_name: "rails",
        upstream_default_branch: "main",
        upstream_slug: "rails/rails",
        trigger_label: "syrus",
        polling_enabled: true,
        archived: false,
        archived_at: null,
        agent_provider: "codex",
        agent_provider_label: "Codex",
        last_poll_status: "ok",
        last_poll_started_at: "2026-05-30T12:00:00Z",
        last_poll_error: null,
        repository_path: "/repositories/3",
        edit_repository_path: "/repositories/3/edit"
      }
    ],
    archived_repositories: overrides.archived_repositories ?? [
      {
        id: 4,
        slug: "old/repo",
        owner: "old",
        name: "repo",
        owner_user: {
          id: 9,
          display_name: "Operator",
          email_address: "operator@example.com",
          admin: true,
          profile_path: "/profiles/9"
        },
        default_branch: "main",
        upstream_owner: null,
        upstream_name: null,
        upstream_default_branch: null,
        upstream_slug: null,
        trigger_label: "syrus",
        polling_enabled: false,
        archived: true,
        archived_at: "2026-05-29T12:00:00Z",
        agent_provider: null,
        agent_provider_label: "default",
        last_poll_status: null,
        last_poll_started_at: null,
        last_poll_error: null,
        repository_path: "/repositories/4",
        edit_repository_path: "/repositories/4/edit"
      }
    ],
    new_repository_path: "/repositories/new",
    setup: overrides.setup ?? setupStatusPayload({
      complete: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: [
          { key: "credentials", label: "Add credentials", complete: true },
          { key: "repository", label: "Add a repository", complete: true },
          { key: "first_job", label: "Start the first Job", complete: true },
          { key: "watch_job", label: "Watch the first successful Job or PR", complete: true }
        ]
      },
      credentials: {
        github_token: true,
        selected_agent_provider: "codex",
        selected_agent_provider_configured: true,
        configured_agent_providers: ["codex"],
        ready: true
      },
      repositories: {
        active_count: 1,
        any_app_credential_active: false,
        any_pat_fallback: true,
        first: {
          id: 3,
          slug: "acme/widgets",
          trigger_label: "syrus",
          credential_mode: "pat",
          repository_path: "/repositories/3",
          issues_path: "/repositories/3?tab=github_issues"
        }
      }
    }),
    message: overrides.message
  }
}

function repositoryFormPayload(overrides: Partial<{
  repository: Record<string, unknown>
}> = {}) {
  return {
    repository: overrides.repository || {
      id: null,
      owner: "",
      name: "",
      slug: null,
      default_branch: "main",
      upstream_owner: "",
      upstream_name: "",
      upstream_default_branch: "",
      trigger_label: "syrus",
      polling_enabled: true,
      prepare_enabled: true,
      pr_cost_footer_enabled: true,
      auto_merge_enabled: false,
      trust_clean_rebase_grade: false,
      agent_provider: "",
      auto_approve_mode: "never",
      github_owner_id: null,
      github_repository_id: null,
      repository_path: null
    },
    configured_agent_providers: [
      { value: "claude", label: "Claude Code" },
      { value: "codex", label: "Codex" }
    ],
    user_agent_provider_label: "Claude Code",
    auto_approve_modes: [
      { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
      { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
      { value: "if_graders_pass_and_tagged_safe", label: "If graders pass and tagged safe", preview: "Jobs using this rule also need the safe tag before landing." }
    ],
    repositories_path: "/repositories"
  }
}

function closedProviderCircuit(provider: string) {
  return {
    provider,
    open: false,
    reason: null,
    retry_after: null,
    failure_count: 0,
    job_count: 0,
    signature: null
  }
}

function repositoryTabsPayload(repositoryId: number) {
  return [
    { key: "overview", label: "Overview", path: `/repositories/${repositoryId}` },
    { key: "github_issues", label: "GitHub Issues", path: `/repositories/${repositoryId}?tab=github_issues` },
    { key: "documents", label: "Documents", path: `/repositories/${repositoryId}/documents` },
    { key: "scheduled_tasks", label: "Scheduled Tasks", path: `/repositories/${repositoryId}/scheduled_tasks` }
  ]
}

function repositoryDetailPayload() {
  return {
    message: null,
    repository: {
      id: 3,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      upstream_owner: "rails",
      upstream_name: "rails",
      upstream_default_branch: "main",
      upstream_slug: "rails/rails",
      trigger_label: "syrus",
      polling_enabled: true,
      archived: false,
      agent_provider: "codex",
      agent_provider_label: "Codex",
      effective_agent_provider: "codex",
      effective_agent_provider_label: "Codex",
      github_url: "https://github.com/acme/widgets",
      created_at: "2026-05-30T12:00:00Z",
      owner_user: {
        id: 9,
        display_name: "Operator",
        email_address: "operator@example.com",
        admin: true,
        profile_path: "/profiles/9"
      },
      github_rate_limit: {
        remaining: 4990,
        limit: 5000,
        resource: "core",
        observed_at: "2026-05-30T12:00:00Z"
      }
    },
    tabs: repositoryTabsPayload(3),
    counts: {
      running: 1,
      queued: 1,
      failed_7d: 1
    },
    retry_failed_jobs: {
      count: 1,
      agent_provider: "codex",
      agent_provider_label: "Codex",
      provider_circuit: closedProviderCircuit("codex")
    },
    credential_status: {
      mode: "pat",
      label: "PAT fallback: no active App installation",
      installation_account: null,
      github_app_registered: true,
      install_url: "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&repository_ids[]=200",
      register_path: null,
      previous_installation_removed: false,
      missing_github_ids: false
    },
    jobs: [
      {
        id: 44,
        state: "open",
        priority: "high",
        issue_number: 1,
        issue_title: "Fix forum",
        job_path: "/jobs/44",
        source: {
          label: "#1",
          path: "https://github.com/acme/widgets/issues/1",
          external: true
        },
        pr_number: 12,
        pr_url: "https://github.com/acme/widgets/pull/12",
        external_pr_number: null,
        external_pr_url: null,
        current_step_caption: "currently: Implement (workflow: Initial)",
        runs_count: 2,
        updated_at: "2026-05-30T12:00:00Z"
      }
    ],
    pagination: {
      page: 1,
      per_page: 20,
      total_jobs: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    paths: {
      new_job_path: "/jobs/new?repository_id=3",
      edit_repository_path: "/repositories/3/edit",
      app_poll_repository_path: "/api/v1/app/repositories/3/poll",
      app_archive_repository_path: "/api/v1/app/repositories/3/archive",
      app_retry_failed_jobs_repository_path: "/api/v1/app/repositories/3/retry_failed_jobs",
      repositories_path: "/repositories",
      repository_documents_path: "/repositories/3/documents",
      repository_scheduled_tasks_path: "/repositories/3/scheduled_tasks"
    }
  }
}

function repositoryIssuesPayload(overrides: { message?: string; delegated?: boolean } = {}) {
  const detail = repositoryDetailPayload()
  return {
    message: overrides.message || null,
    error_message: null,
    repository: detail.repository,
    tabs: detail.tabs,
    state: "open",
    issue_count: 1,
    issues: [
      {
        number: 7,
        title: "Fix the forum",
        state: "open",
        html_url: "https://github.com/acme/widgets/issues/7",
        body_excerpt: "The forum is missing tasteful columns.",
        user_login: "alice",
        created_at: "2026-05-30T12:00:00Z",
        labels: [
          { name: "bug", color: "0075ca" }
        ],
        delegated: overrides.delegated || false
      }
    ],
    state_paths: {
      open: "/repositories/3?tab=github_issues&state=open",
      closed: "/repositories/3?tab=github_issues&state=closed"
    },
    paths: {
      github_issues_path: "https://github.com/acme/widgets/issues",
      app_comment_issue_path: "/api/v1/app/repositories/3/issues/comment",
      app_close_issue_path: "/api/v1/app/repositories/3/issues/close",
      app_delegate_issue_path: "/api/v1/app/repositories/3/issues/delegate",
      app_bulk_issues_path: "/api/v1/app/repositories/3/issues/bulk"
    }
  }
}

function epicFormPayload() {
  return {
    epic: {
      id: null,
      title: "",
      description: "",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository_id: null,
      github_issue_url: "",
      epic_path: null
    },
    repositories: [
      {
        id: 3,
        slug: "acme/widgets"
      }
    ],
    dashboard_epics_path: "/dashboard/epics"
  }
}

function dashboardPayload(overrides: Record<string, unknown> = {}) {
  const payload = {
    subject: "job",
    view: "list",
    page: 1,
    per_page: 25,
    total: 1,
    total_pages: 1,
    counts: {
      jobs: 4,
      epics: 2,
      workflows: 6
    },
    preferences: {
      sort: { column: "created_at", direction: "desc" },
      visible_columns: ["checkbox", "issue", "state", "repository", "latest", "workflows_count", "started"],
      kanban_lanes: ["queued", "running", "succeeded"],
      ownership_scope: "team",
      owner_user_id: null,
      owner_id: null,
      raw: {}
    },
    controls: {
      views: ["list", "kanban"],
      ownership_scopes: [
        { value: "mine", label: "Mine" },
        { value: "team", label: "Team" },
        { value: "claimable", label: "Claimable" },
        { value: "user", label: "User" }
      ],
      owners: [
        { id: 1, label: "Operator", current: true },
        { id: 2, label: "Teammate", current: false }
      ],
      sort_columns: ["title", "state", "repository", "created_at", "started_at"],
      sort_directions: ["asc", "desc"],
      columns: {
        required: [
          { key: "checkbox", title: "Checkbox" },
          { key: "issue", title: "Issue" }
        ],
        optional: [
          { key: "state", title: "State" },
          { key: "repository", title: "Repository" },
          { key: "owner", title: "Owner" },
          { key: "latest", title: "Latest" },
          { key: "workflows_count", title: "Workflows count" },
          { key: "started", title: "Started" },
          { key: "created_at", title: "Created at" },
          { key: "updated_at", title: "Updated at" }
        ]
      },
      kanban_lanes: [
        { key: "blocked", title: "Blocked" },
        { key: "queued", title: "Queued" },
        { key: "running", title: "Running" },
        { key: "succeeded", title: "Succeeded" },
        { key: "landing", title: "Landing" },
        { key: "failed", title: "Failed" }
      ],
      filter_suggestions: [],
      filter_schema: [
        {
          field: "state",
          label: "State",
          bucket: "enum",
          operators: ["is"],
          values: [
            { value: "open", label: "Any open" },
            { value: "closed", label: "Closed or merged" }
          ]
        },
        {
          field: "repository_id",
          label: "Repository",
          bucket: "fk",
          operators: ["is"],
          values: [
            { value: 3, label: "acme/widgets" }
          ]
        },
        {
          field: "kind",
          label: "Kind",
          bucket: "enum",
          operators: ["is"],
          values: ["issue", "cron", "direct"]
        },
        {
          field: "has_parent",
          label: "Has parent",
          bucket: "boolean",
          operators: ["is_true", "is_false"],
          values: []
        },
        {
          field: "attention",
          label: "Attention preset",
          bucket: "preset",
          operators: ["is"],
          values: [
            { value: "merged_this_week", label: "Merged this week" },
            { value: "inbox", label: "Inbox" }
          ]
        }
      ]
    },
    filter: { and: [] },
    landing_queue: {
      visible: false,
      paused: false,
      toggle_path: "/api/v1/app/dashboard/landing_pause"
    },
    ownership_scope: {
      scope: "team",
      owner_user_id: null,
      owner_user: null
    },
    ownership: {
      scope: "team",
      owner_id: null,
      team_user_count: 1,
      badges_visible: false
    },
    smart_folders: [
      {
        id: 7,
        name: "My work",
        kind: "user_defined",
        subject_type: "job",
        visibility: "user_defined",
        count: 1,
        active: false,
        path: "/dashboard/jobs?smart_folder_id=7"
      }
    ],
    active_smart_folder_id: null,
    items: [],
    lanes: [],
    kanban_limit: null,
    setup: setupStatusPayload({
      complete: true,
      next_step: "complete",
      progress: {
        completed: 4,
        total: 4,
        steps: [
          { key: "credentials", label: "Add credentials", complete: true },
          { key: "repository", label: "Add a repository", complete: true },
          { key: "first_job", label: "Start the first Job", complete: true },
          { key: "watch_job", label: "Watch the first successful Job or PR", complete: true }
        ]
      }
    }),
    paths: {
      dashboard_path: "/dashboard",
      dashboard_jobs_path: "/dashboard/jobs",
      dashboard_epics_path: "/dashboard/epics",
      dashboard_workflows_path: "/dashboard/workflows",
      new_epic_path: "/epics/new",
      new_job_path: "/jobs/new",
      app_dashboard_path: "/api/v1/app/dashboard"
    }
  }

  return {
    ...payload,
    ...overrides
  }
}

function decodeFilterQueryParam(q: string) {
  const normalized = q.replace(/-/g, "+").replace(/_/g, "/")
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")

  return JSON.parse(decodeURIComponent(escape(atob(padded)))) as { and: Array<{ field: string; op: string; value?: unknown }> }
}

function mockMediaQuery(matches: boolean) {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })

  return () => {
    if (original) {
      Object.defineProperty(window, "matchMedia", original)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  }
}

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

function decodeFilterQ(q: string) {
  const padded = q.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(q.length / 4) * 4, "=")
  return JSON.parse(decodeURIComponent(escape(atob(padded))))
}

function dashboardJobItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "job",
    id: 42,
    kind: "issue",
    title: "Repair aqueduct",
    state: "open",
    summary_state: "running",
    validity: "valid",
    priority: "high",
    total_cost_usd: 0,
    issue_number: 12,
    issue_url: "https://github.com/acme/widgets/issues/12",
    branch_name: "syrus/issue-12",
    pr_number: 34,
    active_workflow_trigger_kind: "rebase",
    latest_workflow_id: 77,
    latest_workflow_trigger_kind: "rebase",
    pr_url: "https://github.com/acme/widgets/pull/34",
    latest_workflow_state: "running",
    landing_queue_position: null,
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    started_at: "2026-05-30T10:01:00Z",
    finished_at: null,
    approved_at: null,
    claimed_at: null,
    claimed_by_user: { id: 2, display_name: "Ada Lovelace", profile_path: "/profiles/2" },
    claimed_by_current_user: false,
    dependencies_overridden_at: null,
    last_feedback_addressed_at: null,
    last_seen_comment_at: null,
    pr_mergeable_checked_at: null,
    workflows_count: 1,
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    epic: null,
    owner_user: { id: 1, name: "Operator", email_address: "operator@example.com" },
    owner_badge: null,
    tags: [{ id: 5, name: "urgent", color: "red" }],
    source_chat: null,
    paths: { job_path: "/jobs/42", source_path: "/jobs/42/source" },
    ...overrides
  }
}

function dashboardEpicItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "epic",
    id: 7,
    number: 7,
    display_number: "EPIC-7",
    title: "Raise the forum",
    description: "Build columns.",
    state: "ready",
    stuck: false,
    all_jobs_closed: false,
    owner: null,
    owned_by_current_user: false,
    claimable: true,
    owner_badge: null,
    auto_approve_mode: "never",
    owner_user_id: null,
    owner_status: "unclaimed",
    owner_user: null,
    jobs_count: 1,
    landed_jobs_count: 0,
    job_state_counts: {},
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    done_at: null,
    archived_at: null,
    repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
    paths: {
      epic_path: "/epics/7",
      edit_epic_path: "/epics/7/edit",
      app_state_path: "/api/v1/app/epics/7/state"
    },
    ...overrides
  }
}

function dashboardWorkflowItem(overrides: Record<string, unknown> = {}) {
  return {
    type: "workflow",
    id: 9,
    slug: "WF-9",
    path: "/jobs/42?tab=workflows#workflow-9",
    state: "running",
    trigger_kind: "manual",
    agent_provider: "codex",
    created_at: "2026-05-30T10:00:00Z",
    updated_at: "2026-05-30T12:00:00Z",
    started_at: "2026-05-30T10:01:00Z",
    finished_at: "2026-05-30T10:04:00Z",
    cleaned_up_at: null,
    steps_count: 3,
    job: {
      id: 42,
      title: "Repair aqueduct",
      state: "open",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      owner_user: { id: 1, name: "Operator", email_address: "operator@example.com" },
      owner_badge: null,
      path: "/jobs/42"
    },
    ...overrides
  }
}

function renderAppAt(path: string) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(payload: unknown) {
  return new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
}

function currentAdminQueueFilter() {
  return { and: [ { field: "queue_name", op: "is", value: "runs" } ] }
}

function adminQueuePayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filter: currentAdminQueueFilter(),
    controls: {
      filter_schema: [
        {
          field: "queue_name",
          label: "Queue",
          bucket: "enum",
          operators: ["is"],
          values: [ { value: "runs", label: "Runs" }, { value: "chat", label: "Chat" } ]
        }
      ]
    },
    active_smart_folder_id: 10,
    smart_folders: [
      {
        id: 10,
        name: "Run repairs",
        position: 2,
        kind: "user_defined",
        subject_type: "admin_queue",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/queue/active?smart_folder_id=10"
      }
    ],
    jobs: []
  }
}

function adminQueuePayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminQueuePayloadWithSavedFolder(currentAdminQueueFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "10" ? 10 : null,
    filter: filterFromSearch(params, currentAdminQueueFilter())
  }
}

function currentAdminProcessFilter() {
  return { and: [ { field: "state", op: "is", value: "running" } ] }
}

function adminProcessesPayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filter: currentAdminProcessFilter(),
    controls: {
      filter_schema: [
        {
          field: "state",
          label: "State",
          bucket: "enum",
          operators: ["is"],
          values: [ { value: "running", label: "Running" }, { value: "finished", label: "Finished" } ]
        }
      ]
    },
    active_smart_folder_id: 11,
    smart_folders: [
      {
        id: 11,
        name: "Live agents",
        position: 3,
        kind: "user_defined",
        subject_type: "spawned_process",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/processes?smart_folder_id=11"
      }
    ],
    running_total: 0,
    processes: []
  }
}

function adminProcessesPayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "11" ? 11 : null,
    filter: filterFromSearch(params, currentAdminProcessFilter())
  }
}

function currentAdminUserFilter() {
  return { and: [ { field: "gh_rate", op: "is", value: "low" } ] }
}

function adminUsersPayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filters: { gh_rate: "low" },
    filter: currentAdminUserFilter(),
    controls: {
      filter_schema: [
        {
          field: "gh_rate",
          label: "GH rate",
          bucket: "enum",
          operators: ["is"],
          values: [ { value: "low", label: "Low (<10%)" }, { value: "exhausted", label: "Exhausted" } ]
        }
      ]
    },
    count: 0,
    active_smart_folder_id: 12,
    smart_folders: [
      {
        id: 12,
        name: "Low rate users",
        position: 4,
        kind: "user_defined",
        subject_type: "admin_user",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/users?smart_folder_id=12"
      }
    ],
    users: []
  }
}

function adminUsersPayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminUsersPayloadWithSavedFolder(currentAdminUserFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "12" ? 12 : null,
    filter: filterFromSearch(params, currentAdminUserFilter())
  }
}

function filterFromSearch(params: URLSearchParams, fallback: Record<string, unknown>) {
  const encoded = params.get("q")
  if (!encoded) return fallback

  const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")
  return JSON.parse(decodeURIComponent(escape(window.atob(padded)))) as Record<string, unknown>
}

function epicDetailPayload(overrides: {
  message?: string
  state?: string
  stateTransitions?: Array<Record<string, unknown>>
  epic?: Record<string, unknown>
  dependencies?: Array<Record<string, unknown>>
  dependents?: Array<Record<string, unknown>>
  jobs?: Array<Record<string, unknown>>
} = {}) {
  return {
    message: overrides.message,
    epic: {
      id: 7,
      number: 7,
      display_number: "EPIC-7",
      title: "Raise the forum",
      description: "Build **columns**.",
      state: overrides.state || "ready",
      stuck: false,
      owner: null,
      owned_by_current_user: false,
      claimable: true,
      claimed_at: null,
      github_issue_url: "https://github.com/acme/widgets/issues/12",
      updated_at: "2026-05-30T12:00:00Z",
      archived: false,
      jobs_count: 1,
      epic_path: "/epics/7",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository: {
        id: 3,
        slug: "acme/widgets",
        repository_path: "/repositories/3"
      },
      ...overrides.epic
    },
    summary: {
      done_jobs_count: 1,
      total_jobs_count: 1,
      dependency_edge_count: 1,
      blocked: false,
      blocked_reason: null
    },
    state_transitions: overrides.stateTransitions || [
      { label: "Move to backlog", target_state: "backlog", confirm: null },
      { label: "Start", target_state: "in_progress", confirm: null },
      { label: "Archive", target_state: "archived", confirm: "Archive this Epic?" }
    ],
    graph: {
      empty: false,
      definition: "flowchart LR\n  epic_7[\"EPIC-7 Raise the forum\"]\n  epic_6[\"EPIC-6 Deliver marble\"]\n  epic_7 --> epic_6",
      node_count: 2,
      epic_dependency_count: 1,
      job_blocker_count: 0,
      initially_open: true
    },
    dependencies: overrides.dependencies || [
      { epic_id: 6, title: "Deliver marble", state: "done", url: "/epics/6" }
    ],
    dependents: overrides.dependents || [],
    jobs: overrides.jobs || [
      {
        id: 42,
        label: "#12",
        title: "Survey forum",
        path: "/jobs/42",
        state: "closed",
        owner_user_id: null,
        owner_user: null,
        repository_slug: "acme/widgets"
      }
    ],
    paths: {
      dashboard_epics_path: "/dashboard/epics",
      edit_epic_path: "/epics/7/edit",
      app_state_path: "/api/v1/app/epics/7/state",
      app_archive_path: "/api/v1/app/epics/7/archive",
      app_claim_path: "/api/v1/app/epics/7/claim",
      app_unclaim_path: "/api/v1/app/epics/7/unclaim",
      app_reassign_path: "/api/v1/app/epics/7/reassign",
      app_dependencies_path: "/api/v1/app/epics/7/dependencies"
    }
  }
}

function jobDetailPayload(overrides: Record<string, unknown> = {}) {
  const payload = {
    job: {
      id: 42,
      kind: "issue",
      state: "open",
      summary_state: "implemented",
      priority: "medium",
      validity: "valid",
      credential_mode: "pat",
      agent_provider: "codex",
      stack_base: "auto",
      issue_number: 12,
      issue_url: "https://github.com/acme/widgets/issues/12",
      issue_title: "Repair aqueduct",
      issue_body: "Water should climb the hill.",
      branch_name: "syrus/issue-12",
      pr_number: 77,
      pr_url: "https://github.com/acme/widgets/pull/77",
      external_pr_number: null,
      external_pr_url: null,
      pr_mergeable: true,
      pr_mergeable_checked_at: "2026-05-30T12:00:00Z",
      closure_reason: null,
      landing_failure_reason: null,
      approved_at: null,
      approved_via: null,
      claimed_at: null,
      claimed_by_user: null,
      claimed_by_current_user: false,
      total_cost_usd: 0.1234,
      billed_runs_count: 1,
      workflows_count: 1,
      runs_count: 1,
      any_active_run: false,
      prepare_skipped: false,
      prepare_skip_reason: null,
      created_at: "2026-05-30T10:00:00Z",
      updated_at: "2026-05-30T12:00:00Z",
      started_at: "2026-05-30T10:01:00Z",
      finished_at: null
    },
    repository: {
      id: 3,
      slug: "acme/widgets",
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      repository_path: "/repositories/3"
    },
    epic: null,
    pinned: false,
    tags: [{ id: 4, name: "priority:forum", color: "gray" }],
    tag_options: [{ id: 4, name: "priority:forum", color: "gray" }],
    dependencies: [],
    dependents: [],
    unsatisfied_dependencies: [],
    dependency_target_options: [{ label: "acme/widgets #11 - Build hill (JOB-41)", value: "issue:3:11" }],
    attachments: [
      {
        id: 8,
        kind: "google_doc",
        attachment_type: "google_doc_link",
        title: "Hydraulic notes",
        filename: null,
        content_type: null,
        byte_size: null,
        google_doc_url: "https://docs.google.com/document/d/aqueduct/edit",
        uploaded_file: false,
        file_path: null,
        created_at: "2026-05-30T10:02:00Z",
        app_delete_path: "/api/v1/app/jobs/42/attachments/8"
      }
    ],
    summary: {
      run_id: 9,
      text: "Moved the uphill water simulation.",
      finished_at: "2026-05-30T12:00:00Z"
    },
    test_plan: null,
    landing_queue_entry: null,
    workflows: [
      {
        id: 5,
        slug: "WF-5",
        path: "/jobs/42?tab=workflows#workflow-5",
        trigger_kind: "initial",
        agent_provider: "codex",
        state: "succeeded",
        failure_count: 0,
        artifacts: {},
        cleaned_up_at: null,
        retry_available: false,
        started_at: "2026-05-30T10:01:00Z",
        finished_at: "2026-05-30T12:00:00Z",
        created_at: "2026-05-30T10:00:00Z",
        updated_at: "2026-05-30T12:00:00Z",
        app_retry_step_path: "/api/v1/app/jobs/42/workflows/5/retry_step",
        app_push_commits_path: "/api/v1/app/jobs/42/workflows/5/push_commits",
        app_force_push_branch_path: "/api/v1/app/jobs/42/workflows/5/force_push_branch",
        app_discard_branch_output_path: "/api/v1/app/jobs/42/workflows/5/discard_branch_output",
        steps: [
          {
            id: 6,
            kind: "implement",
            display_name: "Implement",
            display_status: "succeeded",
            position: 1,
            iteration: null,
            loop_id: null,
            state: "succeeded",
            started_at: "2026-05-30T10:01:00Z",
            finished_at: "2026-05-30T12:00:00Z",
            created_at: "2026-05-30T10:00:00Z",
            updated_at: "2026-05-30T12:00:00Z",
            details: null,
            latest: true,
            runs: [
              {
                id: 9,
                state: "succeeded",
                trigger_kind: "initial",
                agent_provider: "codex",
                agent_outcome: "success",
                agent_turns: 4,
                agent_pr_title: "Repair aqueduct",
                agent_summary: "Moved the uphill water simulation.",
                parent_session_id: null,
                head_sha: "deadbeef",
                iteration: null,
                started_at: "2026-05-30T10:01:00Z",
                last_heartbeat_at: "2026-05-30T11:59:00Z",
                finished_at: "2026-05-30T12:00:00Z",
                created_at: "2026-05-30T10:00:00Z",
                updated_at: "2026-05-30T12:00:00Z",
                cost_usd: 0.1234,
                input_tokens: 1200,
                output_tokens: 300,
                agent_diff_present: true,
                agent_diff_bytes: 2048,
                job_log_count: 12,
                rate_limited: false,
                run_diagnostic: null,
                health_snapshots: [],
                agent_session: { session_id: "session-9", provider: "codex", transcript_pruned: false, transcript_bytes: 1024, transcript_lines: 12 },
                can_stop: false,
                can_diagnose: false,
                can_resume: false,
                app_artifacts_path: "/api/v1/app/jobs/42/runs/9/artifacts",
                app_stop_path: "/api/v1/app/jobs/42/runs/9/stop",
                app_diagnose_path: "/api/v1/app/jobs/42/runs/9/diagnose",
                app_resume_path: "/api/v1/app/jobs/42/resume",
                app_grade_log_path: null
              }
            ]
          }
        ]
      }
    ],
    workflows_pagination: {
      page: 1,
      per_page: 10,
      total_workflows: 1,
      total_pages: 1,
      first_item: 1,
      last_item: 1,
      previous_path: null,
      next_path: null
    },
    actions: {
      can_start: false,
      can_poll_feedback: true,
      can_rebase: true,
      can_check_mergeability: true,
      can_retry: true,
      can_retry_from_failed_step: false,
      can_restart: true,
      can_cancel: true,
      can_approve: true,
      can_unapprove: false,
      can_reopen: false,
      can_mark_valid: false,
      can_claim: true,
      can_unclaim: false,
      can_override_dependencies: false,
      can_view_timeline: false,
      can_manage_tags: true,
      feedback_agent_options: [],
      rebase_agent_options: [],
      retry_agent_options: []
    },
    paths: {
      job_path: "/jobs/42",
      source_path: "/jobs/42/source",
      app_detail_path: "/api/v1/app/jobs/42",
      app_source_path: "/api/v1/app/jobs/42/source",
      app_timeline_path: "/api/v1/app/jobs/42/timeline",
      app_start_path: "/api/v1/app/jobs/42/start",
      app_run_again_path: "/api/v1/app/jobs/42/run_again",
      app_restart_path: "/api/v1/app/jobs/42/restart",
      app_cancel_path: "/api/v1/app/jobs/42/cancel",
      app_approve_path: "/api/v1/app/jobs/42/approve",
      app_unapprove_path: "/api/v1/app/jobs/42/unapprove",
      app_reopen_path: "/api/v1/app/jobs/42/reopen",
      app_poll_feedback_path: "/api/v1/app/jobs/42/poll_feedback",
      app_rebase_path: "/api/v1/app/jobs/42/rebase",
      app_check_mergeability_path: "/api/v1/app/jobs/42/check_mergeability",
      app_resume_path: "/api/v1/app/jobs/42/resume",
      app_tags_path: "/api/v1/app/jobs/42/tags",
      app_claim_path: "/api/v1/app/jobs/42/claim",
      app_dependencies_path: "/api/v1/app/jobs/42/dependencies",
      app_dependency_override_path: "/api/v1/app/jobs/42/dependencies/override",
      app_stack_base_path: "/api/v1/app/jobs/42/stack_base",
      app_mark_valid_path: "/api/v1/app/jobs/42/mark_valid",
      app_attachments_path: "/api/v1/app/jobs/42/attachments",
      app_pin_path: "/api/v1/app/jobs/42/pin"
    }
  }

  return {
    ...payload,
    ...overrides,
    job: { ...payload.job, ...objectOverrides(overrides.job) },
    repository: { ...payload.repository, ...objectOverrides(overrides.repository) },
    summary: overrides.summary === undefined ? payload.summary : overrides.summary,
    landing_queue_entry: overrides.landing_queue_entry === undefined ? payload.landing_queue_entry : overrides.landing_queue_entry,
    workflows_pagination: { ...payload.workflows_pagination, ...objectOverrides(overrides.workflows_pagination) },
    actions: { ...payload.actions, ...objectOverrides(overrides.actions) },
    paths: { ...payload.paths, ...objectOverrides(overrides.paths) }
  }
}

function objectOverrides(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

function expectRunningPill(label: HTMLElement) {
  const pill = label.closest("[data-status-pill='true']")

  expect(pill).toHaveClass("bg-blue-50", "text-blue-700")
  expect(pill?.querySelector("[data-running-spinner='true']")).toHaveClass("animate-spin")
}

function jobTimelinePayload() {
  return {
    job_id: 42,
    events: [
      {
        at: "2026-05-30T10:00:00Z",
        kind: "created",
        source: "workflow",
        transition_source: null,
        title: "Workflow created",
        detail: "Initial workflow queued.",
        ref: { workflow_id: 5 },
        ref_label: "WF-5",
        workflow_path: "/jobs/42?tab=workflows#workflow-5"
      }
    ]
  }
}

function jobSourcePayload(overrides: { withFile?: boolean } = {}) {
  return {
    job_id: 42,
    repository: { id: 3, slug: "acme/widgets", default_branch: "main", repository_path: "/repositories/3" },
    branch_name: "syrus/issue-12",
    default_ref: "main",
    selected_ref: "deadbeef12345678",
    selected_path: overrides.withFile ? "app/models/user.rb" : null,
    merge_base_sha: "aabbccdd1234567",
    branch_commits: [
      { sha: "deadbeef12345678", short_sha: "deadbee", message: "Repair aqueduct", date: "2026-05-30T11:00:00Z" }
    ],
    tree_items: [
      { path: "app/models/user.rb", name: "user.rb", size: 512, language: "ruby" },
      { path: "README.md", name: "README.md", size: 128, language: "markdown" }
    ],
    tree_truncated: false,
    file: overrides.withFile ? { path: "app/models/user.rb", name: "user.rb", size: 15, language: "ruby", content: "class User\nend\n" } : null,
    source_error: null,
    file_error: null,
    paths: {
      job_path: "/jobs/42",
      source_path: "/jobs/42/source",
      app_source_path: "/api/v1/app/jobs/42/source"
    }
  }
}

function jobSourceDiffPayload(overrides: { baseRef?: string; headRef?: string } = {}) {
  return {
    job_id: 42,
    base_ref: overrides.baseRef || "aabbccdd1234567",
    head_ref: overrides.headRef || "deadbeef12345678",
    merge_base_sha: "aabbccdd1234567",
    default_ref: "main",
    branch_commits: [
      { sha: "deadbeef12345678", short_sha: "deadbee", message: "Repair aqueduct", date: "2026-05-30T11:00:00Z" }
    ],
    files: [
      { path: "app/models/user.rb", status: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" },
      { path: "public/logo.png", status: "added", additions: 0, deletions: 0, patch: null }
    ],
    truncated: false,
    diff_error: null
  }
}

function sidebarChat(overrides: {
  id: number
  title: string | null
  title_pending?: boolean
  pinned?: boolean
  repository: { id: number; slug: string; repository_path: string } | null
  last_message_at: string | null
  unread?: boolean
  turn_in_flight?: boolean
  agent_busy?: boolean
}) {
  return {
    id: overrides.id,
    title: overrides.title,
    title_pending: overrides.title_pending ?? false,
    pinned: overrides.pinned ?? false,
    pinned_context: null,
    chat_path: `/chats/${overrides.id}`,
    repository: overrides.repository,
    turn_in_flight: overrides.turn_in_flight ?? false,
    agent_busy: overrides.agent_busy ?? false,
    stop_requested_at: null,
    cumulative_input_tokens: 0,
    cumulative_output_tokens: 0,
    cumulative_cost_usd: 0,
    current: false,
    last_message_at: overrides.last_message_at,
    created_at: overrides.last_message_at || "2026-06-01T00:00:00Z",
    updated_at: overrides.last_message_at || "2026-06-01T00:00:00Z",
    unread: overrides.unread ?? false
  }
}

function sidebarGroups(chats: ReturnType<typeof sidebarChat>[], options: { hasMore?: Record<string, boolean> } = {}) {
  const groups = new Map<string, { key: string; label: string; repository_id: number | null; chats: ReturnType<typeof sidebarChat>[]; has_more: boolean }>()
  chats.forEach((chat) => {
    const key = chat.repository ? `repository-${chat.repository.id}` : "general"
    const group = groups.get(key) || {
      key,
      label: chat.repository?.slug || "General",
      repository_id: chat.repository?.id ?? null,
      chats: [],
      has_more: Boolean(options.hasMore?.[key])
    }
    group.chats.push(chat)
    groups.set(key, group)
  })

  return Array.from(groups.values())
}

function chatPayload(overrides: {
  id?: number
  chatPath?: string
  message?: string
  messages?: Array<Record<string, unknown>>
  queuedMessages?: Array<Record<string, unknown>>
  agentQuestions?: Array<Record<string, unknown>>
  pendingActions?: Array<Record<string, unknown>>
  cumulativeInputTokens?: number
  cumulativeOutputTokens?: number
  cumulativeCostUsd?: number
  turnInFlight?: boolean
  agentBusy?: boolean
  hasMoreOlder?: boolean
  pinned?: boolean
  stopRequestedAt?: string | null
  chatProvider?: string | null
  effectiveChatProvider?: string
  chatProviderOptions?: Array<Record<string, unknown>>
} = {}) {
  const chatProviderOptions = overrides.chatProviderOptions || [
    { value: null, label: "Default", configured: true, effective_provider: "claude", effective_label: "Claude" },
    { value: "claude", label: "Claude", configured: true, effective_provider: "claude", effective_label: "Claude" },
    { value: "codex", label: "Codex", configured: true, effective_provider: "codex", effective_label: "Codex" }
  ]
  const effectiveChatProvider = overrides.effectiveChatProvider ?? overrides.chatProvider ?? "claude"
  const effectiveChatProviderLabel = effectiveChatProvider === "codex" ? "Codex" : "Claude"
  return {
    message: overrides.message,
    chat: {
      id: overrides.id ?? 8,
      title: "Aqueduct planning",
      title_pending: false,
      pinned: overrides.pinned ?? false,
      pinned_context: null,
      chat_provider: overrides.chatProvider ?? null,
      effective_chat_provider: effectiveChatProvider,
      effective_chat_provider_label: effectiveChatProviderLabel,
      chat_provider_options: chatProviderOptions,
      chat_path: overrides.chatPath ?? "/chats/8",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      stop_requested_at: overrides.stopRequestedAt ?? null,
      cumulative_input_tokens: overrides.cumulativeInputTokens ?? 12400,
      cumulative_output_tokens: overrides.cumulativeOutputTokens ?? 3200,
      cumulative_cost_usd: overrides.cumulativeCostUsd ?? 0.0123
    },
    chat_available: true,
    turn_in_flight: overrides.turnInFlight ?? false,
    agent_busy: overrides.agentBusy ?? false,
    has_more_older: overrides.hasMoreOlder ?? false,
    messages: overrides.messages || [
      {
        type: "message",
        id: 9,
        role: "assistant",
        tool_name: null,
        content: { text: "Discuss aqueducts." },
        text: "Discuss aqueducts.",
        bookmarkable: true
      }
    ],
    bookmarks: [
      { id: 1, label: "Aqueducts", chat_message_id: 9, anchor_message_id: 9 }
    ],
    queued_messages: overrides.queuedMessages || [],
    recent_chats: [
      {
        id: 8,
        title: "Aqueduct planning",
        title_pending: false,
        pinned: overrides.pinned ?? false,
        pinned_context: null,
        chat_provider: overrides.chatProvider ?? null,
        effective_chat_provider: effectiveChatProvider,
        effective_chat_provider_label: effectiveChatProviderLabel,
        chat_provider_options: chatProviderOptions,
        chat_path: "/chats/8",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        stop_requested_at: null,
        cumulative_input_tokens: 12400,
        cumulative_output_tokens: 3200,
        cumulative_cost_usd: 0.0123,
        current: true,
        last_message_at: "2026-06-01T10:00:00Z",
        unread: false
      },
      {
        id: 4,
        title: "Road survey",
        title_pending: false,
        pinned: false,
        pinned_context: null,
        chat_provider: null,
        effective_chat_provider: "claude",
        effective_chat_provider_label: "Claude",
        chat_provider_options: chatProviderOptions,
        chat_path: "/chats/4",
        repository: { id: 4, slug: "acme/roads", repository_path: "/repositories/4" },
        stop_requested_at: null,
        cumulative_input_tokens: 2000,
        cumulative_output_tokens: 1000,
        cumulative_cost_usd: 0.001,
        current: false,
        last_message_at: "2026-05-31T10:00:00Z",
        unread: true
      }
    ],
    pending_actions: overrides.pendingActions || [],
    agent_questions: overrides.agentQuestions || [],
    attachment_groups: {
      repositories: [
        { id: 2, label: "acme/widgets", app_detach_path: "/api/v1/app/chats/8/attachments/2" }
      ],
      epics: [],
      jobs: [],
      documents: []
    },
    documents_in_scope: [
      { id: 5, title: "Launch notes", repository_slug: "acme/widgets" }
    ],
    attachment_results: [],
    whiteboard: {
      version: 2,
      elements: [{ id: "box-1", type: "rectangle" }],
      appState: {},
      files: {}
    },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/8/messages",
      app_message_path: "/api/v1/app/chats/8/message",
      app_rename_path: "/api/v1/app/chats/8/rename",
      app_clear_path: "/api/v1/app/chats/8/messages",
      app_share_path: "/api/v1/app/chats/8/share",
      app_enqueue_message_path: "/api/v1/app/chats/8/queued_messages",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard"
    }
  }
}

function pendingAction(overrides: {
  id?: number
  label?: string
  detail?: string | null
  state?: string
  action?: string | null
  actionType?: string | null
  confirmPath?: string
  cancelPath?: string
  chatMessageId?: number | null
} = {}) {
  const id = overrides.id ?? 7
  return {
    id,
    label: overrides.label ?? "Cancel JOB-44",
    detail: overrides.detail ?? null,
    state: overrides.state ?? "pending",
    action: overrides.action ?? "cancel_job",
    action_type: overrides.actionType ?? null,
    chat_message_id: overrides.chatMessageId,
    app_confirm_path: overrides.confirmPath ?? `/api/v1/app/chats/8/pending_actions/${id}/confirm`,
    app_reject_path: `/api/v1/app/chats/8/pending_actions/${id}/reject`,
    app_cancel_path: overrides.cancelPath ?? `/api/v1/app/chats/8/pending_actions/${id}`
  }
}

function transcriptPayload(overrides: {
  events?: Array<Record<string, unknown>>
  totalEvents?: number
} = {}) {
  const events = overrides.events || [
    {
      kind: "tool_use",
      timestamp: "2026-05-30T12:00:00Z",
      data: { name: "Bash", input: { command: "ls" }, id: "u1" }
    }
  ]

  return {
    run_id: 4,
    job_id: 1,
    step_kind: "implement",
    workflow_trigger_kind: "initial",
    session_id: "abc-123",
    summary: {
      session_id: "abc-123",
      model: "claude-sonnet-4-6",
      cwd: "/workspace",
      total_turns: 1,
      total_tool_calls: 1,
      total_cost_usd: 0.01,
      exit_reason: "success",
      tool_call_counts: { Bash: 1 },
      mcp_tool_called: false,
      available_tools_at_init: ["Bash"]
    },
    pagination: {
      page: 1,
      per: 100,
      total_events: overrides.totalEvents ?? events.length,
      total_pages: 1
    },
    events
  }
}

function setViewportWidth(width: number) {
  const originalWidth = window.innerWidth
  Object.defineProperty(window, "innerWidth", { configurable: true, writable: true, value: width })
  window.dispatchEvent(new Event("resize"))

  return () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, writable: true, value: originalWidth })
    window.dispatchEvent(new Event("resize"))
  }
}

function mockClipboardWrite() {
  const originalClipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard")
  const writeText = vi.fn().mockResolvedValue(undefined)

  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { writeText }
  })

  restoreClipboardMock = () => {
    if (originalClipboard) {
      Object.defineProperty(navigator, "clipboard", originalClipboard)
    } else {
      Reflect.deleteProperty(navigator, "clipboard")
    }
  }

  return writeText
}

function stubVisualViewport(initialHeight: number) {
  const original = Object.getOwnPropertyDescriptor(window, "visualViewport")
  const listeners = new Map<string, Set<EventListenerOrEventListenerObject>>()
  let height = initialHeight
  const viewport = {
    get height() {
      return height
    },
    addEventListener: vi.fn((type: string, listener: EventListenerOrEventListenerObject) => {
      const typeListeners = listeners.get(type) || new Set<EventListenerOrEventListenerObject>()
      typeListeners.add(listener)
      listeners.set(type, typeListeners)
    }),
    removeEventListener: vi.fn((type: string, listener: EventListenerOrEventListenerObject) => {
      listeners.get(type)?.delete(listener)
    })
  }

  Object.defineProperty(window, "visualViewport", {
    configurable: true,
    value: viewport
  })

  return {
    setHeight(nextHeight: number) {
      height = nextHeight
    },
    dispatch(type: string) {
      listeners.get(type)?.forEach((listener) => {
        if (typeof listener === "function") {
          listener(new Event(type))
        } else {
          listener.handleEvent(new Event(type))
        }
      })
    },
    restore() {
      if (original) {
        Object.defineProperty(window, "visualViewport", original)
      } else {
        Reflect.deleteProperty(window, "visualViewport")
      }
    }
  }
}

function setScrollMetrics(element: HTMLElement, metrics: { scrollHeight: number; clientHeight: number; scrollTop: number }) {
  Object.defineProperty(element, "scrollHeight", { configurable: true, value: metrics.scrollHeight })
  Object.defineProperty(element, "clientHeight", { configurable: true, value: metrics.clientHeight })
  Object.defineProperty(element, "scrollTop", { configurable: true, writable: true, value: metrics.scrollTop })
}

function expectSyrusBrandLink(href: string) {
  const brandLink = screen.getByRole("link", { name: "Syrus" })
  expect(brandLink).toHaveAttribute("href", href)
  expect(brandLink.querySelector('img[alt=""][src^="/icon.png?v="]')).not.toBeNull()
}

function stubChatStreamSize(metrics: { scrollHeight: number; clientHeight: number }) {
  const scrollHeightDescriptor = Object.getOwnPropertyDescriptor(window.HTMLElement.prototype, "scrollHeight")
  const clientHeightDescriptor = Object.getOwnPropertyDescriptor(window.HTMLElement.prototype, "clientHeight")

  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get() {
      return this instanceof HTMLElement && this.dataset.testid === "chat-message-stream" ? metrics.scrollHeight : 0
    }
  })
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get() {
      return this instanceof HTMLElement && this.dataset.testid === "chat-message-stream" ? metrics.clientHeight : 0
    }
  })

  return () => {
    if (scrollHeightDescriptor) {
      Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", scrollHeightDescriptor)
    } else {
      Reflect.deleteProperty(window.HTMLElement.prototype, "scrollHeight")
    }
    if (clientHeightDescriptor) {
      Object.defineProperty(window.HTMLElement.prototype, "clientHeight", clientHeightDescriptor)
    } else {
      Reflect.deleteProperty(window.HTMLElement.prototype, "clientHeight")
    }
  }
}

function chatSearchPayload() {
  return {
    results: [
      {
        chat_session_id: 77,
        chat_title: "Forum planning",
        best_snippet: "Best <b>needle</b> <i>ignored</i>",
        best_match_message_id: 11,
        top_matches: [
          chatSearchMatch({ message_id: 11, role: "assistant", snippet: "Best <b>needle</b> <i>ignored</i>", created_at: "2026-06-20T10:00:00Z" }),
          chatSearchMatch({ message_id: 13, role: "assistant", snippet: "Third <b>needle</b>", created_at: "2026-06-20T10:02:00Z" }),
          chatSearchMatch({ message_id: 14, role: "tool_result", snippet: "Fourth <b>needle</b>", created_at: "2026-06-20T10:03:00Z" })
        ],
        total_match_count: 4,
        has_more_matches: true
      }
    ],
    total: 1,
    page: 1,
    per_page: 20
  }
}

function unifiedSearchPayload() {
  return [
    {
      type: "chat",
      id: 11,
      title: "Forum planning",
      snippet: "Best <mark>needle</mark>",
      rank: 0,
      path: "/chats/77?message_id=11",
      state: null,
      repository_slug: null,
      created_at: "2026-06-20T10:00:00Z",
      grouped_matches: [
        { id: 12, snippet: "Second <mark>needle</mark>", path: "/chats/77?message_id=12", created_at: "2026-06-20T10:01:00Z" },
        { id: 13, snippet: "Third <mark>needle</mark>", path: "/chats/77?message_id=13", created_at: "2026-06-20T10:02:00Z" }
      ],
      total_match_count: 4,
      has_more_matches: true
    }
  ]
}

function chatSearchMatch(overrides: Record<string, unknown> = {}) {
  return {
    message_id: 11,
    role: "assistant",
    snippet: "Best <b>needle</b>",
    created_at: "2026-06-20T10:00:00Z",
    ...overrides
  }
}
