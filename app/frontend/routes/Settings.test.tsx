import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import * as useConfirmModule from "../hooks/useConfirm"
import { actionCable } from "../test/app/appMocks"
import { credentialsPayload, notificationPreferencesPayload, personalDocumentsPayload } from "../test/app/settingsPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App settings routes", () => {
  installAppTestLifecycle()

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
              tags: [{ id: 4, name: "epic:attachments", color: "indigo", jobs_count: 0 }],
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
            tags: [{ id: 2, name: "triage", color: "blue", jobs_count: 3 }]
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
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveClass("bg-brand/10")
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

  it("renders the credentials route as provider cards and connects Claude through the setup flow", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify(credentialsPayload({ chatProvider: "codex", chatProviders: ["claude", "codex"] })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/credentials/test_claude_cli" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              credential_test: { credential: "claude_oauth_token", ok: false, message: "Claude is not authenticated on this machine yet.", details: {} }
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/credentials/claude_oauth_start" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/credentials/claude_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              credential_test: {
                credential: "claude_oauth_token",
                ok: true,
                message: "Claude OAuth token is valid.",
                details: {}
              }
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(credentialsPayload({ chatProviders: ["claude", "codex"] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
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
    expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveClass("bg-brand/10")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "/app-shell/notifications/settings")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).not.toHaveClass("bg-brand/10")

    // One card per provider, replacing the single monolithic form.
    expect(await screen.findByTestId("credential-card-github")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-claude")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-codex")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-gemini")).toBeInTheDocument()
    expect(
      screen.getByText(
        "A personal access token is the fallback credential for repositories without an active Syrus GitHub App installation. If an admin registers and installs the App on a repository, Syrus uses the App for that repository instead."
      )
    ).toBeInTheDocument()

    // Saved secrets read as saved — a summary, not an empty password field.
    const claudeCard = screen.getByTestId("credential-card-claude")
    expect(within(claudeCard).getByText("A Claude OAuth token is saved for Syrus runs.")).toBeInTheDocument()

    // Replace opens the same connect flow onboarding uses: preflight,
    // authorize, paste the code.
    fireEvent.click(within(claudeCard).getByRole("button", { name: "Replace" }))
    expect(within(claudeCard).getByLabelText("Authorization code from Claude")).toBeDisabled()
    expect(within(claudeCard).getByText("Paste a long-lived token instead")).toBeInTheDocument()
    expect(within(claudeCard).getByRole("link", { name: "Anthropic authentication docs" })).toHaveAttribute(
      "href",
      "https://code.claude.com/docs/en/authentication#generate-a-long-lived-token"
    )
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
        return Promise.resolve(
          new Response(JSON.stringify(notificationPreferencesPayload({ job_failed: false, message: "Notification preferences updated." })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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

    const notificationsMain = await screen.findByRole("main", { name: "Notification settings" })
    expect(await screen.findByRole("heading", { name: "Notifications" })).toBeInTheDocument()
    expect(screen.queryByRole("main", { name: "Credentials" })).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/credentials", expect.anything())
    // Two halves of one mental model — what you're notified about vs. where —
    // cross-link to each other since there's no other link between them.
    expect(within(notificationsMain).getByRole("link", { name: "Connected Platforms" })).toHaveAttribute("href", "/app-shell/settings/connected_platforms")
    const settingsNav = screen.getByRole("navigation", { name: "Settings navigation" })
    expect(within(settingsNav).getByRole("link", { name: "Credentials" })).toHaveAttribute("href", "/app-shell/credentials")
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveClass("bg-brand/10")
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
    expect(await screen.findByText("Notification preferences updated.")).toBeInTheDocument()
  })

  it("tests a credential from the credentials route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/test_credential" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
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
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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
        return Promise.resolve(
          new Response(JSON.stringify({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/credentials/codex_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              credential_test: {
                credential: "codex_auth_json",
                ok: true,
                message: "Codex ChatGPT auth.json is valid.",
                details: {}
              },
              message: "Codex ChatGPT auth.json is valid."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(credentialsPayload({ codexAuthMode: "chatgpt_login" })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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
        return Promise.resolve(
          new Response(JSON.stringify({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/credentials/codex_oauth_exchange" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              credential_test: {
                credential: "codex_auth_json",
                ok: true,
                message: "Codex ChatGPT auth.json is valid.",
                details: {}
              },
              message: "Codex ChatGPT auth.json is valid."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(credentialsPayload({ codexAuthMode: "chatgpt_login" })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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
      expect(actionCable.createSubscription).toHaveBeenCalled()
    })

    const appUserSubscriptions = (actionCable.createSubscription.mock.calls as unknown[][]).filter(
      (call) => (call[0] as { channel?: string } | undefined)?.channel === "AppUserChannel"
    )
    expect(appUserSubscriptions).toHaveLength(1)
    const received = (appUserSubscriptions[0][1] as { received: (data: unknown) => void }).received
    received({
      type: "codex_oauth.callback",
      resource: "credential",
      payload: { code: "http://localhost:1455/auth/callback?code=auto-code&state=abc" }
    })

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

  it("renders and saves /settings as the accessible profile route without admin links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify(credentialsPayload({ name: "Ada Operator", message: "Credentials updated." })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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
    expect(within(settingsNav).getByRole("link", { name: "Profile" })).toHaveClass("bg-brand/10")
    const displayName = await screen.findByLabelText("Display name")
    expect(screen.getByText("Display name")).toHaveAttribute("for", displayName.id)
    expect(screen.queryByLabelText("GitHub personal access token")).not.toBeInTheDocument()
    expect(within(settingsNav).getByRole("link", { name: "Notifications" })).toHaveAttribute("href", "/app-shell/notifications/settings")
    expect(within(settingsNav).getByRole("link", { name: "Themes" })).toHaveAttribute("href", "/app-shell/settings/themes")
    expect(within(settingsNav).getByRole("link", { name: "Hidden chats" })).toHaveAttribute("href", "/app-shell/settings/hidden_chats")
    expect(within(settingsNav).getByRole("link", { name: "Documents" })).toHaveAttribute("href", "/app-shell/documents")
    expect(within(settingsNav).getByRole("link", { name: "Tags" })).toHaveAttribute("href", "/app-shell/tags")
    expect(screen.queryByRole("link", { name: "Invitations" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "App settings" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credentials", expect.objectContaining({ credentials: "same-origin" }))
    fireEvent.change(displayName, { target: { value: "Ada Operator" } })
    fireEvent.change(screen.getByLabelText("Profile bio"), { target: { value: "Keeps the forms honest." } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(
        expect.objectContaining({
          name: "Ada Operator",
          profile_bio: "Keeps the forms honest."
        })
      )
    })
    await waitFor(() => expect(screen.getByText("Profile updated.")).toBeInTheDocument())
  })

  it("renders and saves the agent settings route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify(credentialsPayload({ agentProvider: "codex", message: "Credentials updated." })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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
    expect(within(settingsNav).getByRole("link", { name: "Agent Settings" })).toHaveClass("bg-brand/10")
    expect(screen.queryByLabelText("GitHub personal access token")).not.toBeInTheDocument()
    fireEvent.change(await screen.findByLabelText("Agent provider"), { target: { value: "codex" } })
    fireEvent.change(screen.getByLabelText("Max turns"), { target: { value: "42" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(
        expect.objectContaining({
          agent_provider: "codex",
          agent_max_turns: 42
        })
      )
    })
    await waitFor(() => {
      expect(screen.getByText("Agent settings updated.")).toBeInTheDocument()
      expect(screen.queryByText("Credentials updated.")).not.toBeInTheDocument()
    })
  })

  it("renders and saves the preferences route", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify(credentialsPayload({ schedulingPaused: true, message: "Credentials updated." })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Preferences" })).toHaveClass("bg-brand/10")
    expect(screen.queryByLabelText("Agent provider")).not.toBeInTheDocument()
    const pauseScheduling = await screen.findByLabelText("Pause scheduling")
    expect(screen.queryByRole("group", { name: "Desktop Notifications" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Job ready for review")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Job failed")).not.toBeInTheDocument()
    fireEvent.click(pauseScheduling)
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(
        expect.objectContaining({
          scheduling_paused: true
        })
      )
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).not.toHaveProperty("notification_preferences")
    })
    await waitFor(() => {
      expect(screen.getByText("Preferences saved.")).toBeInTheDocument()
      expect(screen.queryByText("Credentials updated.")).not.toBeInTheDocument()
    })
  })

  it("rotates an admin API token from the credentials route", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: vi.fn().mockImplementation(async () => true), dialog: <></> })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/notification_preferences") {
        return Promise.resolve(new Response(JSON.stringify(notificationPreferencesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/credentials/rotate_api_token" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify(credentialsPayload({ apiToken: true, newApiToken: "syrus_newtoken", message: "API token rotated." })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(credentialsPayload({ apiToken: true })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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
        return Promise.resolve(
          new Response(
            JSON.stringify(
              personalDocumentsPayload({
                documents: [
                  {
                    id: 8,
                    kind: "google_doc",
                    google_doc_url: "https://docs.google.com/document/d/user/edit",
                    filename: null,
                    content_type: null,
                    byte_size: null,
                    created_at: "2026-05-30T12:00:00Z"
                  }
                ],
                message: "Document added."
              })
            ),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
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
    expect(within(screen.getByRole("navigation", { name: "Settings navigation" })).getByRole("link", { name: "Documents" })).toHaveClass("bg-brand/10")
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
})
