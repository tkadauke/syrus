import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { slashCommandPrompt } from "../lib/slashCommands"
import { App } from "./App"
import { NewChatLauncher } from "./AppChromeV2"
import { bootstrapPayload } from "../test/app/bootstrap"
import { chatPayload, pendingAction, sidebarChat, sidebarGroups } from "../test/app/chatPayloads"
import { mockClipboardWrite, setViewportWidth } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat commands", () => {
  installAppTestLifecycle()

  it("shows and completes slash command suggestions from the chat composer", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = (await screen.findByPlaceholderText("Ask about this repository...")) as HTMLTextAreaElement
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
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      const input = (await screen.findByPlaceholderText("Ask about this repository...")) as HTMLTextAreaElement
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
        return Promise.resolve(
          new Response(JSON.stringify(chatPayload({ message: "Chat renamed." })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
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
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/chats/8",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ chat: { pinned: true } })
      })
    )
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("copies a shared chat link from the share slash command", async () => {
    const clipboardWrite = mockClipboardWrite()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/share" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ share_url: "http://syrus.test/chats/shared/token-123" }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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

    const input = (await screen.findByPlaceholderText("Ask about this repository...")) as HTMLTextAreaElement
    fireEvent.change(input, { target: { value: "/share" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => expect(clipboardWrite).toHaveBeenCalledWith("http://syrus.test/chats/shared/token-123"))
    expect(await screen.findByText("Share link copied to clipboard")).toBeInTheDocument()
    expect(input.value).toBe("")
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/share", expect.objectContaining({ method: "POST" }))
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("clears the composer after declaring a goal from a slash command", async () => {
    const activeGoal = {
      id: 12,
      chat_session_id: 8,
      user_id: 1,
      repository_id: 3,
      prompt: "Clear every canal backlog risk",
      completion_condition: null,
      mode_snapshot: { mode: "planning" },
      status: "active",
      approval_policy: "manual",
      auto_file_proposals: false,
      auto_submit_jobs: false,
      iteration_count: 0,
      terminal_at: null,
      terminal_reason: null,
      terminal_details: null,
      created_at: "2026-06-01T10:00:00Z",
      updated_at: "2026-06-01T10:00:00Z"
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/goal" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(JSON.stringify({ ...chatPayload(), active_goal: activeGoal }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
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

    const input = (await screen.findByPlaceholderText("Ask about this repository...")) as HTMLTextAreaElement
    fireEvent.change(input, { target: { value: "/goal Clear every canal backlog risk" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await screen.findByText("Goal updated.")
    expect(input.value).toBe("")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/chats/8/goal",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ goal: { prompt: "Clear every canal backlog risk" } })
      })
    )
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("updates the v2 sidebar immediately after chat slash commands change chats", async () => {
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
          return Promise.resolve(
            new Response(JSON.stringify({ message: "Chat created.", redirect_to: "/chats/9", chat: newPayload.chat }), {
              status: 201,
              headers: { "Content-Type": "application/json" }
            })
          )
        }

        return Promise.resolve(
          new Response(JSON.stringify({ groups: sidebarGroups(sidebarChats), repositories: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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

  it("keeps repository selection out of the sidebar new-chat launcher", async () => {
    const startChat = vi.fn()

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <NewChatLauncher collapsed={false} disabled={false} onStartChat={startChat} />
      </QueryClientProvider>
    )

    expect(screen.queryByRole("combobox", { name: "Repository for new chat" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Remove repository from new chat" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "New Chat" }))

    expect(startChat).toHaveBeenCalledTimes(1)
    expect(startChat).toHaveBeenCalledWith()
  })

  it("confirms clear before deleting chat history", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages" && init?.method === "DELETE") {
        return Promise.resolve(
          new Response(JSON.stringify(chatPayload({ message: "Chat history cleared.", messages: [] })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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

  it("handles panel system slash commands in the app", async () => {
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(() => Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })))

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
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })

  it("opens the bug report dialog from the /report slash command with transcript opt-in", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)

    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Bug report queued." }), { status: 201, headers: { "Content-Type": "application/json" } })
        )
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
      fireEvent.change(input, { target: { value: "/report" } })
      fireEvent.click(screen.getByRole("button", { name: "Send message" }))

      // /report opens the full bug report dialog (via BugReportButton) instead of the old simple dialog
      const dialog = await screen.findByRole("dialog", { name: "Report a bug" })
      expect(dialog).toBeInTheDocument()

      // Since chat messages are passed to the dialog, the transcript opt-in checkbox appears
      expect(within(dialog).getByRole("checkbox", { name: /include chat transcript/i })).toBeInTheDocument()

      // Submit the report without the transcript
      fireEvent.click(within(dialog).getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/bug_reports", expect.objectContaining({ method: "POST" }))
      })
      expect(await screen.findByRole("status")).toHaveTextContent("Bug report queued.")
      expect(screen.queryByRole("dialog", { name: "Report a bug" })).not.toBeInTheDocument()
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    } finally {
      script.remove()
    }
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
    fireEvent.change(input, { target: { value: "/propose" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    // The prompt itself is the slash command module's business; this asserts
    // the mechanism -- a skill command sends its generated prompt down the
    // normal message path.
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining(`"chat_message":{"text":${JSON.stringify(slashCommandPrompt("/propose"))}}`)
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
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = (await screen.findByPlaceholderText("Ask about this repository...")) as HTMLTextAreaElement
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

  it("runs chat commands through the app API", async () => {
    const search = "?view=thread"
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
    const action = {
      ...pendingAction({ id: 7, label: "Cancel JOB-44" }),
      resource_title: "Stop the aqueduct dig",
      resource_url: "/jobs/44"
    }
    const initialPayload = {
      ...chatPayload({ messages: [chatPayload().messages[0], proposalMessage], pendingActions: [action] })
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === `/api/v1/app/chats/8/bookmarks${search}` && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              ...initialPayload,
              message: "Bookmarked Aqueduct marker.",
              bookmarks: [...initialPayload.bookmarks, { id: 2, label: "Aqueduct marker", chat_message_id: 9 }]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (path === `/api/v1/app/chats/8/proposals/5/confirm${search}` && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              message: "Proposal confirmed and filed as JOB-88.",
              proposal: {
                ...proposalMessage.proposal,
                proposed: false,
                resolved: true,
                state: "confirmed",
                state_label: "Confirmed",
                materialized_label: "JOB-88",
                materialized_path: "/jobs/88",
                materialized: { kind: "job", job_id: 88, job_title: "Map auth", job_state: "open" }
              },
              messages: [
                {
                  type: "message",
                  id: 88,
                  role: "system",
                  content: {
                    text: 'Proposal confirmed. JOB-88 "Map auth" was created.',
                    source: "proposal_notification",
                    outcome: "confirmed",
                    acknowledgment: "Confirmed JOB-88."
                  },
                  text: 'Proposal confirmed. JOB-88 "Map auth" was created.',
                  bookmarkable: false,
                  created_at: "2026-05-30T11:05:00Z"
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      if (path === `/api/v1/app/chats/8/pending_actions/7/confirm${search}` && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              ...initialPayload,
              message: "Pending action confirmed.",
              messages: [chatPayload().messages[0], proposalMessage],
              pending_actions: []
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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

    fireEvent.click(screen.getByRole("button", { name: "Confirm proposal and implement" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(`/api/v1/app/chats/8/proposals/5/confirm${search}`, expect.objectContaining({ method: "POST" }))
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
      expect(fetchSpy).toHaveBeenCalledWith(`/api/v1/app/chats/8/pending_actions/7/confirm${search}`, expect.objectContaining({ method: "POST" }))
    })
    expect(await screen.findByText("Pending action confirmed.")).toBeInTheDocument()
  }, 15000)
})
