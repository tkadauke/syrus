import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { appendBootstrapScript, publicBootstrapPayload, stubDesktopUserAgent } from "../test/app/bootstrap"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App public and auth routes", () => {
  installAppTestLifecycle()

  it("renders a minimal first-run welcome for a new instance", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
    expect(screen.getByRole("heading", { name: "Syrus" })).toBeInTheDocument()
    // Theme-aware mark: an inline SVG painted from semantic color tokens
    // rather than the static /icon.png artwork, so it follows the active
    // color theme instead of needing its own cache-busted asset URL.
    const mark = welcome.querySelector('[data-testid="syrus-mark"]')
    expect(mark).not.toBeNull()
    expect(mark?.tagName.toLowerCase()).toBe("svg")
    expect(mark).toHaveAttribute("aria-hidden", "true")
    expect(mark).toHaveAttribute("viewBox", "0 0 512 512")
    // The actual theme-driven behavior: backdrop and glyph are painted from
    // the semantic color tokens, not literal colors, so switching themes
    // (built-in or custom) recolors the mark via these CSS custom properties.
    expect(mark?.querySelector('g > rect[width="512"]')).toHaveAttribute("fill", "var(--color-brand)")
    const glyph = mark?.querySelector("path")
    expect(glyph).toHaveAttribute("fill", "var(--color-on-brand)")
    expect(glyph).toHaveAttribute("fill-rule", "evenodd")
    expect(screen.getByRole("link", { name: "Set up this Syrus instance" })).toHaveAttribute("href", "/users/new")
    expect(screen.getByText("No users exist yet. The first account becomes the administrator for this instance.")).toBeInTheDocument()
    // No "Sign in" when there are no users yet — there's nobody to sign in as.
    expect(screen.queryByRole("link", { name: "Sign in" })).not.toBeInTheDocument()
    // The marketing pitch stays off the first-run screen.
    expect(screen.queryByRole("region", { name: "Workflow" })).not.toBeInTheDocument()
    expect(screen.queryByText("Syrus turns GitHub issues into reviewed pull requests.")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/bootstrap", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("does not load signed-in plugin sidebar routes on the public landing page", async () => {
    const script = appendBootstrapScript(publicBootstrapPayload({ first_signup: false, signups_open: false }))
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      if (String(input) === "/api/v1/app/sidebar_pages") {
        return new Response(JSON.stringify({ error: { code: "unauthorized", message: "Sign in required." } }), {
          status: 401,
          headers: { "Content-Type": "application/json" }
        })
      }

      return new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } })
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/?token=invite-123"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Syrus instance access" })).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "Create account from invitation" })).toHaveAttribute("href", "/users/new?token=invite-123")
      expect(screen.queryByTestId("desktop-sidebar")).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "New chat" })).not.toBeInTheDocument()
      expect(screen.queryByRole("button", { name: "Search" })).not.toBeInTheDocument()
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/sidebar_pages", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("renders invitation-only landing CTA for locked instances", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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

    expect(await screen.findByRole("main", { name: "Syrus instance access" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/session/new")
    expect(screen.getByText("This instance is invitation-only. Ask the operator for an invitation if you need access.")).toBeInTheDocument()
    expect(screen.queryByText("Live work path")).not.toBeInTheDocument()
    expect(screen.queryByText("Why self-host")).not.toBeInTheDocument()
    expect(screen.queryByText("Read the setup docs")).not.toBeInTheDocument()
  })

  it("renders account creation CTA when signups are open", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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

    expect(await screen.findByRole("main", { name: "Syrus instance access" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Create account" })).toHaveAttribute("href", "/users/new")
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/session/new")
    expect(screen.getByText("Open sign-ups are enabled for this instance.")).toBeInTheDocument()
  })

  it("renders account creation CTA when an invitation token is present", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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

    expect(await screen.findByRole("main", { name: "Syrus instance access" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Create account from invitation" })).toHaveAttribute("href", "/users/new?token=invite-123")
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/session/new")
    expect(screen.getByText("Use the invitation in this link to create your account.")).toBeInTheDocument()
  })

  it("skips the marketing landing inside the desktop shell and lands on sign-in", async () => {
    // Desktop users who are merely signed out already installed the app —
    // they need the sign-in form, not the self-hosting pitch.
    const restoreUserAgent = stubDesktopUserAgent()
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
      expect(screen.queryByRole("main", { name: "Syrus instance access" })).not.toBeInTheDocument()
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

      expect(await screen.findByRole("main", { name: "Create account" }, { timeout: 15000 })).toBeInTheDocument()
      expect(await screen.findByText("Accepting an invitation from admin@example.com.", undefined, { timeout: 15000 })).toBeInTheDocument()
      expect(screen.queryByRole("main", { name: "Syrus public landing" })).not.toBeInTheDocument()
      // The token must survive the desktop redirect — the signup page's state
      // fetch carries it as the query string.
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/auth/signup?token=invite-123", expect.objectContaining({ credentials: "same-origin" }))
    } finally {
      restoreUserAgent()
    }
  }, 15000)

  it("keeps the first-run welcome inside the desktop shell", async () => {
    // First run IS the desktop first-run screen — no redirect to sign-in
    // (there is nobody to sign in as yet).
    const restoreUserAgent = stubDesktopUserAgent()
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify({ error: { code: "invalid_credentials", message: "Try another email address or password." } }), {
          status: 422,
          headers: { "Content-Type": "application/json" }
        })
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
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/auth/signup", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("shows the sign-in link on the sign-up route once users exist", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify({ allowed: true, first_signup: false, signups_open: true, invitation: null }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
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
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(async () => new Response(JSON.stringify(publicBootstrapPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/?token=invite-token"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Syrus instance access" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "Create account from invitation" })).toHaveAttribute("href", "/users/new?token=invite-token")
    expect(screen.getByRole("link", { name: "Sign in" })).toHaveAttribute("href", "/session/new")
    expect(screen.getByText("Use the invitation in this link to create your account.")).toBeInTheDocument()
    expect(screen.queryByText("Invitation-only")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/bootstrap",
      expect.objectContaining({ credentials: "same-origin", headers: { Accept: "application/json" } })
    )
  })

  it("renders the password request route and shows the API response message", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
})
