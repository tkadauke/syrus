import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import type { BootstrapPayload } from "../api/bootstrap"
import type { JobStep } from "../api/jobs"

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
  default: {
    initialize: vi.fn(),
    render: vi.fn(async (_id: string, definition: string) => ({
      svg: `<svg role="img" aria-label="Dependency graph"><text>${definition}</text></svg>`
    }))
  }
}))

let restoreClipboardMock: (() => void) | null = null

describe("App", () => {
  beforeEach(() => {
    document.getElementById("syrus-bootstrap-data")?.remove()
    window.localStorage.clear()
    excalidrawMock.throwOnRender = false
    excalidrawMock.addFiles.mockClear()
    excalidrawMock.lastInitialData = null
    excalidrawMock.updateScene.mockClear()
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
            agent_max_turns: 200
          },
          team_user_count: 1,
          app: {
            revision: "dev",
            revision_url: null
          },
          navigation: {
            default_chat_path: "/chats/new"
          },
          csrf_token: "csrf-token",
          feature_flags: {
            migrated_routes: []
          }
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Syrus SPA" })).toBeInTheDocument()
    const accountNav = await screen.findByRole("navigation", { name: "Account" })
    expect(within(accountNav).getByRole("link", { name: "admin" })).toHaveAttribute("href", "/app-shell/admin")
    expect(within(accountNav).getByRole("link", { name: "Account settings" })).toHaveAttribute("href", "/app-shell/settings")
    expect(within(accountNav).getByRole("button", { name: "operator@example.com" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByRole("link", { name: "Settings" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Sign out" })).not.toBeInTheDocument()
    fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
    expect(within(accountNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings")
    expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
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

  it("renders first-run landing CTA for a new instance", async () => {
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

    expect(await screen.findByRole("main", { name: "Syrus public landing" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Syrus turns GitHub issues into reviewed pull requests." })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Set up this Syrus instance" })).toHaveAttribute("href", "/users/new")
    expect(screen.getByText("No users exist yet. The first account becomes the administrator for this instance.")).toBeInTheDocument()
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
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/session/new")
    expect(screen.getByText("This instance is invitation-only. Ask the operator for an invitation if you need access.")).toBeInTheDocument()
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
    expect(screen.getByText("Open sign-ups are enabled for this instance.")).toBeInTheDocument()
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
    expect(screen.getByRole("link", { name: "Create account from invitation" })).toHaveAttribute("href", "/users/new?token=invite-123")
    expect(screen.getByText("Detected")).toBeInTheDocument()
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
    expect(screen.getByRole("link", { name: "Already have an account? Sign in" })).toHaveAttribute("href", "/app-shell/session/new")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/auth/signup",
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("renders the logged-out landing CTA from public bootstrap state", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify(publicBootstrapPayload({ first_signup: false, signups_open: false })),
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

      expect(await screen.findByRole("link", { name: "Repair aqueduct" })).toHaveAttribute("href", "/jobs/42")
      expect(screen.getByRole("main", { name: "Dashboard" })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus landing" })).not.toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/dashboard",
        expect.objectContaining({ credentials: "same-origin" })
      )
    } finally {
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

  it("renders the first-run setup checklist and links to the next action", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(setupStatusPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/setup"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "First-run setup" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Get to the first successful Job" })).toBeInTheDocument()
    expect(screen.getByText("0 of 4 complete")).toBeInTheDocument()
    expect(screen.getByText("GitHub PAT missing; Claude credentials missing.")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Open credentials" })[0]).toHaveAttribute("href", "/app-shell/credentials/edit")
    expect(screen.getByText(/falls back to your GitHub PAT/)).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/setup",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("redirects incomplete root visits to setup when bootstrap has setup state", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify({ ...bootstrapPayload(), setup: setupStatusPayload() })
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(setupStatusPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "First-run setup" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Setup" })).toHaveAttribute("href", "/app-shell/setup")
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/setup",
        expect.objectContaining({ credentials: "same-origin" })
      )
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
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)

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
      expect(screen.getByRole("link", { name: "Syrus" })).toHaveAttribute("href", "/app-shell/chats/9")
      expect(within(primaryNav).getByRole("link", { name: "Dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).toHaveClass("hidden", "sm:inline-flex")
      expect(within(primaryNav).queryByRole("link", { name: "Jobs" })).toBeNull()
      expect(within(primaryNav).queryByRole("link", { name: "Chat" })).toBeNull()
      expect(within(primaryNav).queryByRole("link", { name: "Admin" })).toBeNull()
      expect(within(accountNav).getByRole("link", { name: "admin" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(accountNav).getByRole("link", { name: "admin" })).toHaveClass("rounded")
      expect(within(accountNav).getByRole("link", { name: "Account settings" })).toHaveAttribute("href", "/app-shell/settings")
      expect(within(accountNav).getByRole("button", { name: "operator@example.com" })).toHaveAttribute("aria-expanded", "false")
      expect(within(accountNav).queryByRole("link", { name: "Settings" })).toBeNull()
      expect(within(accountNav).queryByRole("button", { name: "Sign out" })).toBeNull()
      fireEvent.click(within(accountNav).getByRole("button", { name: "operator@example.com" }))
      expect(within(accountNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings")
      expect(within(accountNav).getByRole("link", { name: "Admin" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(accountNav).getByRole("button", { name: "Sign out" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "9c0f8d15" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/commit/9c0f8d15")
      const footer = screen.getByRole("contentinfo")
      const quoteLink = within(footer).getByRole("link", { name: "A rolling stone gathers no moss." })
      expect(footer).toHaveClass("hidden", "lg:block")
      expect(quoteLink).toHaveAttribute("href", "https://en.wikipedia.org/wiki/Publilius_Syrus")
      expect(quoteLink).toHaveAttribute("target", "_blank")
      expect(quoteLink).toHaveAttribute("rel", "noopener")
      expect(fetchSpy).not.toHaveBeenCalled()
    } finally {
      randomSpy.mockRestore()
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
        next_step_path: "/credentials/edit",
        credentials_configured: false,
        repository_configured: false,
        first_job_started: false,
        first_successful_job_completed: false,
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
      expect(screen.getByRole("link", { name: "Configure GitHub" })).toHaveAttribute("href", "/credentials/edit")
      expect(fetchSpy).not.toHaveBeenCalled()
    } finally {
      script.remove()
    }
  })

  it("renders the next useful onboarding step for a job already in flight", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload({
      setup_status: setupStatus({
        state: "first_job_started",
        next_step: "watch_first_job",
        next_step_path: "/dashboard/jobs?view=list",
        first_job_started: true,
        first_successful_job_completed: false,
        counts: {
          repositories: 1,
          jobs: 1,
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
      expect(screen.getByText("5")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Watch jobs" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")
      expect(screen.queryByRole("link", { name: "Start direct job" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("shows completion on onboarding once the first successful job exists", async () => {
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

  it("omits the quote footer on chat routes", async () => {
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
      expect(screen.queryByRole("contentinfo")).not.toBeInTheDocument()
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
      expect(await screen.findByRole("dialog", { name: "Report a bug" })).toBeInTheDocument()
      expect(screen.getByLabelText("Title")).toHaveValue("Dashboard bug")
      expect(html2canvasMock).toHaveBeenCalledTimes(2)
      expect(screen.getByRole("radio", { name: "Viewport" })).toBeChecked()
      expect(screen.getByRole("radio", { name: "Full page" })).toBeInTheDocument()
      expect(screen.getByRole("radio", { name: "No screenshot" })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      fireEvent.change(screen.getByLabelText("Description"), { target: { value: "The aqueduct counter is off by one." } })
      fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls[0]?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The aqueduct counter is off by one.")
      expect((form.get("screenshot") as File).name).toBe("bug-report-full-page.png")
      expect(await screen.findByRole("status")).toHaveTextContent("Bug report queued.")
      expect(screen.queryByRole("dialog", { name: "Report a bug" })).not.toBeInTheDocument()
    } finally {
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
      const form = fetchSpy.mock.calls[0]?.[1]?.body as FormData
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
      const form = fetchSpy.mock.calls[0]?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The toga modal has fallen.")
    } finally {
      script.remove()
    }
  })

  it("renders the admin overview route from the app admin API", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          active_runs: { total: 2, by_trigger: { initial: 1, retry: 1 } },
          queued_runs: { total: 1 },
          recent_failures_24h: { total: 0, by_trigger: {} },
          github_rate_limits: [],
          github_api_blocked_users: [],
          provider_circuits: [],
          agent_session_capture_rate: { total: 3, captured: 3, rate: 1.0 },
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
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Active runs")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Admin overview" })).toBeInTheDocument()
    const adminNav = screen.getByRole("navigation", { name: "Admin navigation" })
    expect(within(adminNav).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/admin")
    expect(within(adminNav).getByRole("link", { name: "Stuck" })).toHaveAttribute("href", "/app-shell/admin/stuck")
    expect(within(adminNav).getByRole("link", { name: "Users" })).toHaveAttribute("href", "/app-shell/admin/users")
    expect(within(adminNav).getByRole("link", { name: "Queue" })).toHaveAttribute("href", "/app-shell/admin/queue/active")
    expect(within(adminNav).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
    expect(within(adminNav).getByRole("link", { name: "Console" })).toHaveAttribute("href", "/app-shell/admin/console")
    expect(within(adminNav).getByRole("link", { name: "GitHub App" })).toHaveAttribute("href", "/app-shell/admin/github_app/register")
    expect(within(adminNav).getByRole("link", { name: "Installations" })).toHaveAttribute("href", "/app-shell/admin/installations")
    expect(within(adminNav).getByRole("link", { name: "App settings" })).toHaveAttribute("href", "/app-shell/settings/edit")
    expect(within(adminNav).getByRole("link", { name: "Invitations" })).toHaveAttribute("href", "/app-shell/invitations")
    expect(screen.getByRole("link", { name: /Active runs/ })).toHaveAttribute("href", "/app-shell/admin/queue/active")
    expect(screen.getByRole("link", { name: /Stuck things/ })).toHaveAttribute("href", "/app-shell/admin/stuck")
    expect(screen.getByRole("link", { name: "Run #4 silent for 10m" })).toHaveAttribute("href", "/app-shell/jobs/1?tab=workflows#workflow-2")
    expect(screen.getByText("2")).toBeInTheDocument()
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
    expect(screen.getByRole("heading", { name: "Dashboard" }).closest("header")).not.toHaveClass("border-b")
    const subjectNav = screen.getByRole("navigation", { name: "Dashboard subjects" })
    expect(subjectNav.parentElement).toHaveClass("lg:grid-cols-[16rem_minmax(0,1fr)]")
    expect(subjectNav).toHaveClass("inline-flex", "w-max", "overflow-hidden", "rounded", "border", "border-gray-300", "bg-white")
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
    expect(screen.getByRole("link", { name: "Epics" })).toHaveAttribute("href", "/app-shell/dashboard/epics?view=list")
    expect(screen.getByRole("link", { name: "Jobs" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")
    expect(screen.getByRole("link", { name: "Jobs" })).toHaveClass("bg-blue-50", "text-blue-700", "ring-blue-600")
    expect(screen.getByRole("link", { name: "Workflows" })).toHaveAttribute("href", "/app-shell/dashboard/workflows?view=list")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveAttribute("href", "/app-shell/epics/new")
    expect(screen.getByRole("link", { name: "New Epic" })).toHaveClass("bg-blue-600", "text-white")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveAttribute("href", "/app-shell/jobs/new")
    expect(screen.getByRole("link", { name: "New Job" })).toHaveClass("bg-green-600", "text-white")
    expect(screen.getByRole("link", { name: "My work 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=7")
    expect(screen.queryByText("0 selected")).not.toBeInTheDocument()
    expect(screen.queryByText(/Sorted by/)).not.toBeInTheDocument()
    expect(within(screen.getByRole("button", { name: "Sort by Issue ascending" })).getByText("↓")).toBeInTheDocument()
    const latestWorkflowCell = screen.getByRole("cell", { name: "Latest workflow: rebase running" })
    expect(latestWorkflowCell).toBeInTheDocument()
    expect(within(latestWorkflowCell).getByText("running").closest("[data-status-pill='true']")?.parentElement).toHaveClass("items-start")
    expect(screen.getByText("Showing 11-20 of 25")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Previous" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=1")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&page=3")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/dashboard?view=list&subject=job",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
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

    const smartFoldersPanel = await screen.findByRole("complementary", { name: "Dashboard smart folders panel" })
    const folderNameInput = within(smartFoldersPanel).getByLabelText("Folder name")
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
            filter: JSON.stringify(latestFilterTree),
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
  })

  it("disambiguates GitHub issue numbers from Syrus Job ids on the dashboard", async () => {
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
    expect(screen.getByText("/JOB-594")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "#123" })).toHaveAttribute("href", "https://github.com/acme/widgets/issues/123")
    expect(screen.queryByText("#594")).not.toBeInTheDocument()
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

  it("renders dashboard ownership scope controls and useful owner badges", async () => {
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

    const scopeNav = await screen.findByRole("navigation", { name: "Dashboard ownership scope" })
    expect(within(scopeNav).getByRole("link", { name: "Mine" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&ownership_scope=mine")
    expect(within(scopeNav).getByRole("link", { name: "Team" })).toHaveClass("bg-gray-900", "text-white")
    expect(within(scopeNav).getByRole("link", { name: "Team" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list")
    expect(within(scopeNav).getByRole("link", { name: "User" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&ownership_scope=user&owner_id=1")
    expect(screen.getByText("Teammate")).toBeInTheDocument()
    expect(screen.queryByText("Operator")).not.toBeInTheDocument()
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
      expect(screen.getByRole("link", { name: "My work 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=7")
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
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
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
                  path: "/dashboard/jobs?view=list&smart_folder_id=7"
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
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
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
                    path: "/dashboard/jobs?view=list&smart_folder_id=1"
                  },
                  {
                    id: 2,
                    name: "Stale",
                    kind: "builtin",
                    subject_type: "job",
                    visibility: "on_demand",
                    count: 1,
                    active: false,
                    path: "/dashboard/jobs?view=list&smart_folder_id=2"
                  },
                  {
                    id: 3,
                    name: "Merged this week",
                    kind: "builtin",
                    subject_type: "job",
                    visibility: "on_demand",
                    count: 0,
                    active: true,
                    path: "/dashboard/jobs?view=list&smart_folder_id=3"
                  },
                  {
                    id: 4,
                    name: "Saved review",
                    kind: "user_defined",
                    subject_type: "job",
                    visibility: "user_defined",
                    count: 2,
                    active: false,
                    path: "/dashboard/jobs?view=list&smart_folder_id=4"
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

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/dashboard/jobs?view=list&smart_folder_id=3"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "Inbox 3" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=1")
    const moreGroup = screen.getByText("More").closest("details")
    expect(moreGroup).not.toBeNull()
    expect(within(moreGroup!).getByRole("link", { name: "Stale 1" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=2")
    expect(within(moreGroup!).getByRole("link", { name: "Merged this week 0" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=3")
    expect(screen.getByRole("button", { name: /Attention preset.*Merged this week/ })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Saved review 2" })).toHaveAttribute("href", "/app-shell/dashboard/jobs?view=list&smart_folder_id=4")
    expect(screen.getByRole("link", { name: "Manage" })).toHaveAttribute("href", "/app-shell/smart_folders?subject_type=job")
    expect(screen.queryByLabelText("Folder name")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save folder" })).not.toBeInTheDocument()
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
    expect(screen.getByRole("link", { name: "back to job #1" })).toHaveAttribute("href", "/app-shell/jobs/1")
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
            grade_max_iterations: 2
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
    const manifest = JSON.stringify({
      name: "operator-syrus",
      default_permissions: {
        issues: "write",
        pull_requests: "write",
        metadata: "read"
      }
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          github_app: {
            registered: true,
            id: 12345,
            slug: "operator-syrus",
            registered_at: "2026-05-30T12:00:00Z"
          },
          github_manifest_url: "https://github.com/settings/apps/new?state=abc123",
          manifest,
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
    const form = within(registration).getByRole("form", { name: "GitHub manifest registration" })
    expect(form).toHaveAttribute("action", "https://github.com/settings/apps/new?state=abc123")
    expect(form).toHaveAttribute("method", "post")
    expect(form).toHaveAttribute("target", "_blank")
    expect(form.querySelector("input[name='manifest']")).toHaveAttribute("value", manifest)
    expect(within(form).getByRole("button", { name: "Re-register GitHub App" })).toHaveAttribute("formtarget", "_blank")
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
              settings: {
                signups_open: true,
                clearable_secrets: [
                  { key: "telegram_bot_token", label: "Telegram bot token", set: true },
                  { key: "telegram_webhook_secret", label: "Telegram webhook secret", set: false }
                ]
              },
              message: "Settings updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            settings: {
              signups_open: false,
              clearable_secrets: [
                { key: "telegram_bot_token", label: "Telegram bot token", set: true },
                { key: "telegram_webhook_secret", label: "Telegram webhook secret", set: false }
              ]
            }
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
    expect((await screen.findAllByText("Telegram bot token")).length).toBeGreaterThan(0)
    expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("checkbox", { name: /Open signups/ }))
    fireEvent.change(screen.getByLabelText("Telegram bot token"), { target: { value: "bot-token" } })
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
            app_setting: {
              signups_open: true,
              telegram_bot_token: "bot-token",
              telegram_webhook_secret: ""
            }
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
    expect(within(settingsNav).getByRole("link", { name: "My credentials" })).toHaveAttribute("href", "/app-shell/credentials/edit")
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveClass("bg-gray-900")
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

  it("renders the smart folders route from the app API and updates folders", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/smart_folders/7" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              subject_type: "epic",
              subject_label: "Epic",
              dashboard_path: "/dashboard/epics",
              smart_folders: [
                {
                  id: 7,
                  name: "Ready Epics",
                  position: 3,
                  filter: { and: [{ field: "state", op: "is", value: "ready" }] }
                }
              ],
              message: "Smart folder updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            subject_type: "epic",
            subject_label: "Epic",
            dashboard_path: "/dashboard/epics",
            smart_folders: [
              {
                id: 7,
                name: "Ready Epics",
                position: 2,
                filter: { and: [{ field: "state", op: "is", value: "ready" }] }
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/smart_folders?subject_type=epic"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Smart folders" })).toBeInTheDocument()
    expect(await screen.findByDisplayValue("Ready Epics")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Back to dashboard" })).toHaveAttribute("href", "/app-shell/dashboard/epics")

    fireEvent.change(screen.getByLabelText("Position for Ready Epics"), { target: { value: "3" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

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
            smart_folder: {
              name: "Ready Epics",
              position: 3
            }
          })
        })
      )
    })
    expect(await screen.findByText("Smart folder updated.")).toBeInTheDocument()
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
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Templates" })).toHaveClass("bg-gray-900")
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
    expect(screen.getByRole("link", { name: "My credentials" })).toHaveAttribute("href", "/app-shell/credentials/edit")
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
              schedule_label: "17 9 * * 1",
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
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/scheduled_tasks/12",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
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
      expect(within(primaryNav).getByRole("link", { name: "Repos" })).toHaveClass("sm:bg-blue-50", "text-blue-700")
      expect(within(primaryNav).getByRole("link", { name: "Schedules" })).not.toHaveClass("bg-blue-50")
      expect(await screen.findByRole("main", { name: "Repository scheduled tasks" })).toHaveClass("max-w-[96rem]")
      const scheduledTabs = await screen.findByRole("navigation", { name: "Repository tabs" })
      expect(within(scheduledTabs).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/repositories/3")
      expect(within(scheduledTabs).getByRole("link", { name: "Context" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=context")
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

  it("renders the credentials route and updates account settings", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ name: "Ada Lovelace", message: "Credentials updated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "My credentials" })).toBeInTheDocument()
    expect(await screen.findByText("A personal access token is the fallback credential for repositories without an active Syrus GitHub App installation. If an admin registers and installs the App on a repository, Syrus uses the App for that repository instead.")).toBeInTheDocument()
    expect(screen.getByText("Keep a PAT configured for PAT-only repositories and GitHub owner/repository pickers.")).toBeInTheDocument()
    expect(screen.queryByText("Personal documents")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Google Doc URL")).not.toBeInTheDocument()
    fireEvent.change(await screen.findByLabelText("Display name"), { target: { value: "Ada Lovelace" } })
    fireEvent.change(screen.getByLabelText("First name"), { target: { value: "Ada" } })
    fireEvent.change(screen.getByLabelText("Last name"), { target: { value: "Lovelace" } })
    fireEvent.change(screen.getByLabelText("Profile bio"), { target: { value: "Mathematician and operator." } })
    fireEvent.change(screen.getByLabelText("Company"), { target: { value: "Analytical Engines Ltd" } })
    fireEvent.change(screen.getByLabelText("Location"), { target: { value: "London" } })
    fireEvent.change(screen.getByLabelText("Website"), { target: { value: "https://example.com/ada" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin"
        })
      )
    })
    const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
    const patchBody = JSON.parse(String(patchCall?.[1]?.body))
    expect(patchBody.user).toEqual(expect.objectContaining({
      name: "Ada Lovelace",
      first_name: "Ada",
      last_name: "Lovelace",
      profile_bio: "Mathematician and operator.",
      profile_company: "Analytical Engines Ltd",
      profile_location: "London",
      profile_website: "https://example.com/ada",
      claude_oauth_token: "",
      codex_api_key: "",
      codex_auth_json: "",
      github_token: ""
    }))
    expect(await screen.findByText("Credentials updated.")).toBeInTheDocument()
  })

  it("renders /settings as the credentials route without admin links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify(credentialsPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "My credentials" })).toBeInTheDocument()
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "My credentials" })).toHaveAttribute("href", "/app-shell/credentials/edit")
    expect(within(settingsNav).getByRole("link", { name: "My credentials" })).toHaveClass("bg-gray-900")
    expect(within(settingsNav).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/documents")
    expect(within(settingsNav).getByRole("link", { name: "Templates" })).toHaveAttribute("href", "/app-shell/cron_templates")
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveAttribute("href", "/app-shell/tags")
    expect(screen.queryByRole("link", { name: "Invitations" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "App settings" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credentials", expect.objectContaining({ credentials: "same-origin" }))
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
      if (path === "/api/v1/app/credentials/rotate_api_token" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ apiToken: true, newApiToken: "syrus_newtoken", message: "API token rotated." })), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(credentialsPayload({ apiToken: true })), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/credentials/edit"]}>
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
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Documents" })).toHaveClass("bg-gray-900")
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
    expect(within(repositoryTabs).getByRole("link", { name: "Context" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=context")
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
    expect(await screen.findByDisplayValue("acme/widgets")).toBeInTheDocument()
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
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/44",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
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
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        ...repositoriesPayload(),
        active_repositories: [],
        archived_repositories: []
      }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/repositories"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("heading", { name: "Connect credentials first" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Open credentials" })).toHaveAttribute("href", "/app-shell/credentials/edit")
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
    expect(screen.getByRole("link", { name: "Context" })).toHaveAttribute("href", "/app-shell/repositories/3?tab=context")
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

  it("runs repository note commands through the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/repositories/3/notes/11" && init?.method === "DELETE") {
        return Promise.resolve(new Response(JSON.stringify({
          ...repositoryDetailPayload(),
          message: "Repository context removed.",
          notes: []
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === "/api/v1/app/repositories/3/notes" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...repositoryDetailPayload(),
          message: "Repository context pinned.",
          notes: [
            {
              id: 12,
              body: "Use staging for smoke tests.",
              author: "operator",
              created_at: "2026-05-30T12:00:00Z",
              app_delete_path: "/api/v1/app/repositories/3/notes/12"
            }
          ]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(repositoryDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/repositories/3?tab=context"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Delete" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/notes/11",
        expect.objectContaining({ method: "DELETE", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Repository context removed.")).toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText("Pin repository context..."), { target: { value: "Use staging for smoke tests." } })
    fireEvent.click(screen.getByRole("button", { name: "Add note" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/repositories/3/notes",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ repository_note: { body: "Use staging for smoke tests." } })
        })
      )
    })
    expect(await screen.findByText("Use staging for smoke tests.")).toBeInTheDocument()
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
    expect(screen.queryByRole("link", { name: "Back to Epics" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Edit" })).toHaveAttribute("href", "/app-shell/epics/7/edit")
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByRole("link", { name: "Survey forum" })).toHaveAttribute("href", "/app-shell/jobs/42")
    expect(screen.getByRole("button", { name: "Move to backlog" })).toBeInTheDocument()
    expect(screen.getByText("columns")).toBeInTheDocument()
    expect(screen.getByText("(1 epic dep, 0 job blockers)")).toBeInTheDocument()
    expect(await screen.findByRole("img", { name: "Dependency graph" })).toBeInTheDocument()
    expect(document.querySelector("[data-controller='mermaid-graph']")).toBeNull()
    expect(screen.getByText("Survey forum")).toBeInTheDocument()
    expect(screen.getByText("1/1 done")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Start" }))

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
    const archiveButton = screen.getByRole("button", { name: "Archive" })
    expect([...archiveButton.parentElement!.querySelectorAll("a,button")].map((element) => element.textContent)).toEqual([
      "Move back to ready",
      "Edit",
      "Archive"
    ])
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
    expect(screen.getByText(/Unclaimed/)).toBeInTheDocument()
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
    expect(await screen.findByRole("heading", { level: 1, name: "Repair aqueduct" })).toBeInTheDocument()
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
    expect(screen.getByRole("link", { name: "acme/widgets #84 (closed)" })).toHaveAttribute("href", "/app-shell/jobs/44")
    expect(screen.queryByRole("button", { name: "Show timeline" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Add tag")).toBeInTheDocument()
    expect(screen.getByText("Unclaimed")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More" }))
    fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Claim" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/claim",
        expect.objectContaining({ method: "POST", credentials: "same-origin" })
      )
    })
    expect(await screen.findByText("Job claimed.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More" }))
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
  })

  it("coalesces adjacent transcript chunks with the same kind", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/runs/9/artifacts") {
        return Promise.resolve(new Response(JSON.stringify({
          job_id: 42,
          run_id: 9,
          agent_diff: null,
          agent_diff_bytes: 0,
          logs_count: 3,
          logs: [
            { id: 1, sequence: 0, kind: "system", chunk: "Fetching rack 3.2.6", created_at: "2026-05-30T10:02:00Z" },
            { id: 2, sequence: 1, kind: "system", chunk: "Fetching rack-session 2.1.2", created_at: "2026-05-30T10:02:01Z" },
            { id: 3, sequence: 2, kind: "tool_call", chunk: "bundle install", created_at: "2026-05-30T10:02:02Z" }
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
      element.textContent === "Fetching rack 3.2.6\nFetching rack-session 2.1.2"
    ))).toBeInTheDocument()
    expect(screen.getAllByText("System")).toHaveLength(1)
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

    expect(await screen.findByRole("heading", { level: 1, name: "Investigate viewport report" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.getByText("Direct Job")).toBeInTheDocument()
    expect(screen.getByText("implemented")).toBeInTheDocument()
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

    expect(await screen.findByRole("button", { name: "Show timeline" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("Workflow created")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/jobs/42/timeline",
      expect.objectContaining({ credentials: "same-origin" })
    )

    fireEvent.click(screen.getByRole("button", { name: "Show timeline" }))

    expect(await screen.findByText("Workflow created")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Workflow created" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("link", { name: "WF-5" })).toHaveAttribute("href", "/app-shell/jobs/42?tab=workflows#workflow-5")
    expect(screen.getByRole("button", { name: "Hide timeline" })).toHaveAttribute("aria-expanded", "true")
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
    for (const label of runningLabels) expectRunningPill(label)
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
    expect(await screen.findByText(/class User/)).toBeInTheDocument()
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
      ["Approve", "POST", "/api/v1/app/jobs/42/approve"],
      ["Retry", "POST", "/api/v1/app/jobs/42/run_again"]
    ]
    const overflowCommands = [
      ["Start Run", "POST", "/api/v1/app/jobs/42/start"],
      ["Check feedback", "POST", "/api/v1/app/jobs/42/poll_feedback"],
      ["Rebase now", "POST", "/api/v1/app/jobs/42/rebase"],
      ["Check mergeability", "POST", "/api/v1/app/jobs/42/check_mergeability"],
      ["Start over", "POST", "/api/v1/app/jobs/42/restart"],
      ["Unapprove", "POST", "/api/v1/app/jobs/42/unapprove"],
      ["Cancel", "POST", "/api/v1/app/jobs/42/cancel"],
      ["Reopen", "POST", "/api/v1/app/jobs/42/reopen"],
      ["Mark valid", "POST", "/api/v1/app/jobs/42/mark_valid"],
      ["Unpin", "DELETE", "/api/v1/app/jobs/42/pin"]
    ]

    expect(await screen.findByRole("button", { name: "Approve" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Start Run" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "More" }))
    expect(screen.getByRole("menu")).toBeInTheDocument()
    expect(within(screen.getByRole("menu")).getByRole("menuitem", { name: "Retry with feedback" })).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    await waitFor(() => {
      expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    })
    fireEvent.click(screen.getByRole("button", { name: "More" }))
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
      fireEvent.click(screen.getByRole("button", { name: "More" }))
      fireEvent.click(within(screen.getByRole("menu")).getByRole("menuitem", { name: label }))
      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(path, expect.objectContaining({ method }))
      })
    }
  })

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

    expect(await screen.findByRole("button", { name: "Retry" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "More" }))
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

    const dependencyLinks = await screen.findAllByRole("link", { name: "acme/widgets #11 (open)" })
    expect(dependencyLinks).toHaveLength(2)
    dependencyLinks.forEach((link) => {
      expect(link).toHaveAttribute("href", "/app-shell/jobs/41")
    })

    fireEvent.change(await screen.findByPlaceholderText("Add tag"), { target: { value: "urgent" } })
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

    fireEvent.change(screen.getByLabelText("Dependency"), { target: { value: "issue:3:11" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Add" })[1])
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

    expect(screen.queryByText("Active run #10")).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: /Implement/i }))
    expect(await screen.findByText("Active run #10")).toBeInTheDocument()
    expect(screen.getByText("is running")).toBeInTheDocument()
    expect(screen.getByText("step failed")).toBeInTheDocument()
    expect(screen.getByText("Run #10").compareDocumentPosition(screen.getByText("Run #9"))).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
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
              step({ id: 63, kind: "grader", display_name: "rspec", display_status: "failed", position: 2, loop_id: "grade-loop", iteration: 1, state: "failed", details: { name: "rspec" } }),
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
    expect(within(grade).getByText(/failed/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Push/i })).toBeInTheDocument()
    expect(screen.queryByText("Plan graders")).not.toBeInTheDocument()
    expect(screen.queryByText("Aggregate graders")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /rspec/i })).not.toBeInTheDocument()

    fireEvent.click(grade)

    expect(screen.getByRole("button", { name: /Setup/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /rspec/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Result/i })).toBeInTheDocument()
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
    expect(chatMain).toHaveClass("h-[calc(var(--chat-visual-viewport-height,100dvh)-4rem)]", "overflow-hidden")
    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Aqueduct planning" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream")).toHaveClass("h-full", "min-h-0", "overflow-y-auto")
    expect(screen.getByRole("complementary", { name: "Chat workspace" })).toHaveClass("min-h-0")
    expect(screen.getByRole("navigation", { name: "Chat workspace tabs" })).toBeInTheDocument()
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
    expect(screen.getByRole("button", { name: "acme/widgets" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Chats" }))
    expect(screen.getByRole("navigation", { name: "Recent chats" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Road survey/ })).toHaveAttribute("href", "/app-shell/chats/4")
    expect(screen.getByText("Bookmarks in this chat")).toBeInTheDocument()
    expect(screen.getByText("Aqueducts")).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText("Title, repo, or id"), { target: { value: "roads" } })
    expect(screen.queryByRole("link", { name: /Aqueduct planning/ })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: /Road survey/ })).toBeInTheDocument()
    expect(screen.getByText("12.4k in", { exact: false })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "New chat" }).map((link) => link.getAttribute("href"))).toContain("/app-shell/chats/new")
    fireEvent.change(screen.getByPlaceholderText("Ask about this repository..."), { target: { value: "Now inspect proposals" } })
    fireEvent.click(screen.getByRole("button", { name: "Send" }))

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
    expect(screen.queryByText("Message sent.")).not.toBeInTheDocument()
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
      expect(within(mobileTabs).getByRole("button", { name: "Chats" })).toBeInTheDocument()
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

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Chats" }))
      expect(screen.getByRole("link", { name: "New chat" })).toHaveAttribute("href", "/app-shell/chats/new")

      fireEvent.click(within(mobileTabs).getByRole("button", { name: "Chat" }))
      expect(screen.getByTestId("chat-message-stream")).toBeInTheDocument()
      expect(screen.getByPlaceholderText("Ask about this repository...")).toBeInTheDocument()
    } finally {
      restoreMedia()
    }
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

  it("shows an animated chat agent activity indicator", async () => {
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

    expect(await screen.findByRole("status", { name: "Agent is working" })).toHaveTextContent("Agent working")
  })

  it("hides chat Send and keeps Stop compact while the agent is busy", async () => {
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

    const stop = await screen.findByRole("button", { name: "Stop" })
    expect(screen.queryByRole("button", { name: "Send" })).not.toBeInTheDocument()
    expect(stop).toHaveClass("px-3", "py-1.5")
    expect(stop).not.toHaveClass("px-4", "py-2")
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

    expect(await screen.findByRole("status", { name: "Agent is starting" })).toHaveTextContent("Agent starting")
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
            id: 19,
            role: "tool_use",
            tool_name: "Bash",
            content: { input: { command: "rg queue_as /syrus-home/.syrus/chat-workspaces/5/repositories/tkadauke/syrus/app/jobs" } },
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
            id: 14,
            role: "system",
            tool_name: null,
            content: { text: "[mcp_servers] syrus-chat-sidecar=connected" },
            text: "[mcp_servers] syrus-chat-sidecar=connected",
            bookmarkable: false
          },
          {
            type: "message",
            id: 15,
            role: "system",
            tool_name: null,
            content: { text: "[mcp_servers] syrus-chat-sidecar=failed" },
            text: "[mcp_servers] syrus-chat-sidecar=failed",
            bookmarkable: false
          },
          {
            type: "message",
            id: 16,
            role: "system",
            tool_name: null,
            content: { text: "[mcp_servers] syrus-chat-sidecar=pending" },
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
    expect(screen.getAllByText("app/models/chat.rb").length).toBeGreaterThan(0)
    expect(screen.getByText("Bash")).toBeInTheDocument()
    expect(screen.getAllByText("rg queue_as app/jobs").length).toBeGreaterThan(0)
    expect(screen.queryByText(/\/syrus-home\/\.syrus\/chat-workspaces/)).not.toBeInTheDocument()
    expect(screen.getByText(/class Chat\s+end/)).toBeInTheDocument()
    expect(screen.queryByText(/Agent run succeeded/)).not.toBeInTheDocument()
    expect(screen.queryByText(/MCP connected: syrus-chat-sidecar/)).not.toBeInTheDocument()
    expect(screen.queryByText(/MCP starting: syrus-chat-sidecar/)).not.toBeInTheDocument()
    expect(screen.queryByText(/MCP issue: syrus-chat-sidecar pending/)).not.toBeInTheDocument()
    expect(screen.queryByText("Cancelled by operator.")).not.toBeInTheDocument()
    expect(screen.getByText(/Agent run failed: Error max turns/)).toBeInTheDocument()
    expect(screen.getByText(/1\.2s/)).toBeInTheDocument()
    expect(screen.getByText(/MCP issue: syrus-chat-sidecar failed/)).toBeInTheDocument()
    expect(screen.getByText("command timed out")).toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream")).toHaveClass("pt-12")
    fireEvent.click(screen.getByRole("button", { name: "Show 4 hidden system messages" }))
    expect(screen.getByText(/Agent run succeeded/)).toBeInTheDocument()
    expect(screen.getByText(/4 turns/)).toBeInTheDocument()
    expect(screen.getByText(/2\.8m/)).toBeInTheDocument()
    expect(screen.getByText(/\$0\.37/)).toBeInTheDocument()
    expect(screen.getByText(/MCP connected: syrus-chat-sidecar/)).toBeInTheDocument()
    expect(screen.getByText(/MCP starting: syrus-chat-sidecar/)).toBeInTheDocument()
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
    const initialPayload = {
      ...chatPayload({ messages: [...chatPayload().messages, proposalMessage] }),
      attachment_results: [{ type: "Repository", id: 4, label: "acme/tools" }],
      pending_actions: [
        {
          id: 7,
          label: "Cancel JOB-44",
          action: "cancel_job",
          action_type: null,
          app_confirm_path: "/api/v1/app/chats/8/pending_actions/7/confirm",
          app_cancel_path: "/api/v1/app/chats/8/pending_actions/7"
        }
      ]
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
            proposal: { ...proposalMessage.proposal, proposed: false, state: "confirmed", state_label: "Confirmed", materialized_label: "JOB-88", materialized_path: "/jobs/88" }
          }]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      if (path === `/api/v1/app/chats/8/pending_actions/7/confirm${search}` && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({
          ...initialPayload,
          message: "Pending action confirmed.",
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
    fireEvent.click(screen.getByRole("button", { name: "Chats" }))
    expect(await screen.findByRole("link", { name: "Aqueduct marker" })).toHaveAttribute("href", "#message-9")
    expect(screen.queryByText("Bookmarked Aqueduct marker.")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Context" }))
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

    fireEvent.click(screen.getByTitle("Detach acme/widgets"))
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
    expect(await screen.findByRole("link", { name: "JOB-88" })).toHaveAttribute("href", "/app-shell/jobs/88")
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

    expect(await screen.findByRole("link", { name: "EPIC-11" })).toHaveAttribute("href", "/app-shell/epics/11")
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

  it("loads and scrolls to chat bookmarks", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView })
    const initialPayload = chatPayload({ hasMoreOlder: true })
    initialPayload.bookmarks = [
      { id: 7, label: "Earlier aqueduct note", chat_message_id: 4, anchor_message_id: 5 }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
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

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: "Chats" }))
    const bookmark = await screen.findByRole("link", { name: "Earlier aqueduct note" })
    expect(bookmark).toHaveAttribute("href", "#message-5")
    fireEvent.click(bookmark)

    expect(await screen.findByText("aqueduct")).toBeInTheDocument()
    await waitFor(() => {
      expect(scrollIntoView).toHaveBeenCalledWith({ block: "start", behavior: "smooth" })
    })
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/chats/8/messages?before=9",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the new chat route and posts to the app API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats" && init?.method === "POST") {
        return Promise.resolve(new Response(
          JSON.stringify({ error: { code: "validation_failed", message: "Repository is not available." } }),
          { status: 422, headers: { "Content-Type": "application/json" } }
        ))
      }

      return Promise.resolve(new Response(JSON.stringify(chatFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "New chat" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Repositories" })).not.toBeInTheDocument()
    fireEvent.change(await screen.findByLabelText("Repository"), { target: { value: "3" } })
    fireEvent.change(screen.getByLabelText("First message"), { target: { value: "Map the forum" } })
    fireEvent.click(screen.getByRole("button", { name: "Create chat" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ repository_id: "3", chat_message: { text: "Map the forum" } })
        })
      )
    })
    expect(await screen.findByText("Repository is not available.")).toBeInTheDocument()
  })

  it("creates a new chat and navigates within the React shell", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/8", chat: chatPayload().chat }), { status: 201, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(chatFormPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/new"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByLabelText("Repository"), { target: { value: "3" } })
    fireEvent.click(screen.getByRole("button", { name: "Create chat" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: JSON.stringify({ repository_id: "3", chat_message: { text: "" } })
        })
      )
    })
    expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
  })
})

function bootstrapPayload(overrides: Record<string, unknown> & { setupStatus?: ReturnType<typeof bootstrapSetupStatusPayload> | null } = {}) {
  const { setupStatus: setupStatusOverride, ...payloadOverrides } = overrides

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
      agent_max_turns: 200
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
      evaluation_url: "https://syrus.dev/evaluate"
    },
    navigation: {
      default_chat_path: "/chats/9"
    },
    csrf_token: "csrf-token",
    setup_status: setupStatusOverride ?? (payloadOverrides.setup_status as ReturnType<typeof bootstrapSetupStatusPayload> | undefined) ?? setupStatus(),
    feature_flags: {
      migrated_routes: []
    },
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
    next_step: "credentials",
    progress: {
      completed: 0,
      total: 4,
      steps: [
        { key: "credentials", label: "Add credentials", complete: false },
        { key: "repository", label: "Add a repository", complete: false },
        { key: "first_job", label: "Start the first Job", complete: false },
        { key: "watch_job", label: "Watch the first successful Job or PR", complete: false }
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
      credentials_path: "/credentials/edit",
      new_repository_path: "/repositories/new",
      repositories_path: "/repositories",
      new_job_path: "/jobs/new",
      dashboard_jobs_path: "/dashboard/jobs"
    },
    ...overrides
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
      evaluation_url: "https://syrus.dev/evaluate",
      ...overrides
    }
  }
}

function bootstrapSetupStatusPayload(overrides: { nextStep?: "configure_credentials" | "add_repository" | "start_first_job" | "watch_first_job" | null } = {}) {
  const nextStep = overrides.nextStep ?? "start_first_job"
  const nextStepPath = {
    configure_credentials: "/credentials/edit",
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
      schedule_label: "17 9 * * 1",
      last_fired_at: null,
      archived_at: null,
      consecutive_failure_count: 0,
      scheduled_task_path: "/scheduled_tasks/12",
      prompt: "Keep tests moving.",
      cron_expression: "0 9 * * 1",
      hourly_cron_expression: "17 9 * * 1",
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
      agent_provider: "claude",
      codex_auth_mode: "api_key",
      agent_max_turns: 200,
      scheduling_paused: false,
      auto_approve_mode: "never"
    },
    credential_status: {
      github_token: true,
      claude_oauth_token: true,
      codex_api_key: false,
      codex_auth_json: false,
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
    tabs: [
      { key: "overview", label: "Overview", path: "/repositories/3" },
      { key: "github_issues", label: "GitHub Issues", path: "/repositories/3?tab=github_issues" },
      { key: "context", label: "Context", path: "/repositories/3?tab=context" },
      { key: "documents", label: "Documents", path: "/repositories/3/documents" },
      { key: "scheduled_tasks", label: "Scheduled Tasks", path: "/repositories/3/scheduled_tasks" }
    ],
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
    notes: [
      {
        id: 11,
        body: "Repository context pinned.",
        author: "operator",
        created_at: "2026-05-30T12:00:00Z",
        app_delete_path: "/api/v1/app/repositories/3/notes/11"
      }
    ],
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
      app_repository_notes_path: "/api/v1/app/repositories/3/notes",
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
        path: "/dashboard/jobs?view=list&smart_folder_id=7"
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
    owner: null,
    owned_by_current_user: false,
    claimable: true,
    owner_badge: null,
    auto_approve_mode: "never",
    owner_user_id: null,
    owner_status: "unclaimed",
    owner_user: null,
    jobs_count: 1,
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

function epicDetailPayload(overrides: {
  message?: string
  state?: string
  stateTransitions?: Array<Record<string, unknown>>
  epic?: Record<string, unknown>
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
      blocked: false
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
      app_reassign_path: "/api/v1/app/epics/7/reassign"
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

function chatPayload(overrides: {
  message?: string
  messages?: Array<Record<string, unknown>>
  turnInFlight?: boolean
  agentBusy?: boolean
  hasMoreOlder?: boolean
} = {}) {
  return {
    message: overrides.message,
    chat: {
      id: 8,
      title: "Aqueduct planning",
      chat_path: "/chats/8",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      stop_requested_at: null,
      cumulative_input_tokens: 12400,
      cumulative_output_tokens: 3200,
      cumulative_cost_usd: 0.0123
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
    recent_chats: [
      {
        id: 8,
        title: "Aqueduct planning",
        chat_path: "/chats/8",
        repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
        stop_requested_at: null,
        cumulative_input_tokens: 12400,
        cumulative_output_tokens: 3200,
        cumulative_cost_usd: 0.0123,
        current: true,
        last_message_at: "2026-06-01T10:00:00Z"
      },
      {
        id: 4,
        title: "Road survey",
        chat_path: "/chats/4",
        repository: { id: 4, slug: "acme/roads", repository_path: "/repositories/4" },
        stop_requested_at: null,
        cumulative_input_tokens: 2000,
        cumulative_output_tokens: 1000,
        cumulative_cost_usd: 0.001,
        current: false,
        last_message_at: "2026-05-31T10:00:00Z"
      }
    ],
    pending_actions: [],
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
      new_chat_path: "/chats/new",
      credentials_path: "/credentials/edit",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/8/messages",
      app_message_path: "/api/v1/app/chats/8/message",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard"
    }
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

function chatFormPayload() {
  return {
    repositories: [
      {
        id: 3,
        slug: "acme/widgets"
      }
    ],
    repositories_path: "/repositories"
  }
}
