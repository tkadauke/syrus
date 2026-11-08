import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { bootstrapPayload } from "../test/app/bootstrap"
import { chatPayload } from "../test/app/chatPayloads"
import { setScrollMetrics, stubChatStreamSize } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat messages", () => {
  installAppTestLifecycle()

  it("renders the chat route", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
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

  it("renders a chat and sends a message from the app API", async () => {
    const invalidateSpy = vi.spyOn(QueryClient.prototype, "invalidateQueries")
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              chatPayload({
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
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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
    window.dispatchEvent(new Event("focus"))

    const chatMain = await screen.findByRole("main", { name: "Chat" })
    expect(chatMain).toBeInTheDocument()
    expect(chatMain).toHaveClass("h-full", "overflow-hidden")
    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Aqueduct planning" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream")).toHaveClass("h-full", "min-h-0", "overflow-x-hidden", "overflow-y-auto")
    expect(screen.getByText("Discuss aqueducts.").closest(".chat-prose")).toHaveClass("text-text-primary")
    expect(screen.getByText("Discuss aqueducts.").closest(".chat-prose")?.parentElement).toHaveClass("sm:bg-surface", "sm:border-border")
    // The workspace panel is lazy-loaded; wait for it rather than relying on a
    // chunk already loaded by an earlier test.
    expect(await screen.findByRole("complementary", { name: "Chat workspace" })).toHaveClass("min-h-0", "dark:bg-gray-900", "dark:border-gray-700")
    expect(screen.getByRole("navigation", { name: "Chat workspace tabs" })).toHaveClass("dark:border-gray-700")
    expect(screen.getByRole("button", { name: "Resize chat workspace" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Refresh repo" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reset workspace" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "acme/widgets" })).not.toBeInTheDocument()
    expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Whiteboard" }))
    })
    // Fullscreen is owned entirely by the whiteboard plugin's own tab
    // component (a fixed, full-viewport portal into document.body) rather
    // than a core Chat.tsx layout shift, so the chat column/tab bar stay
    // mounted underneath -- only the toggle/Escape behavior is asserted here.
    // The tab component is lazily loaded, so wait for it to mount before
    // reaching for its Fullscreen button.
    fireEvent.click(await screen.findByRole("button", { name: "Fullscreen" }))
    expect(screen.getByRole("button", { name: "Exit fullscreen" })).toHaveAttribute("aria-pressed", "true")
    fireEvent.click(screen.getByRole("button", { name: "Exit fullscreen" }))
    expect(screen.getByRole("button", { name: "Fullscreen" })).toHaveAttribute("aria-pressed", "false")
    fireEvent.click(screen.getByRole("button", { name: "Fullscreen" }))
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.getByRole("button", { name: "Fullscreen" })).toHaveAttribute("aria-pressed", "false")
    expect(screen.queryByRole("button", { name: "Chats" })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Recent chats" })).not.toBeInTheDocument()
    expect(screen.getByText("12.4k in", { exact: false })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "New chat" })).not.toBeInTheDocument()
    expect(screen.getByPlaceholderText("Ask about this repository...")).toHaveClass("dark:bg-gray-900", "dark:text-gray-100")
    fireEvent.change(screen.getByPlaceholderText("Ask about this repository..."), { target: { value: "Now inspect proposals" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          body: expect.stringContaining('"chat_message":{"text":"Now inspect proposals"}')
        })
      )
    })
    expect(await screen.findByText("Now inspect proposals")).toBeInTheDocument()
    expect(screen.getByText("Now inspect proposals").closest(".chat-prose")).toBeNull()
    expect(screen.getByText("Now inspect proposals")).toHaveClass("whitespace-pre-wrap", "bg-brand", "text-on-brand")
    expect(screen.queryByText("Message sent.")).not.toBeInTheDocument()
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/mark_read", expect.objectContaining({ method: "PATCH" }))
    })
    await waitFor(() => {
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["chats", "recent"] })
    })
  })

  it("keeps the chat scrolled to the bottom when new messages arrive at the bottom", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
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
      queryClient.setQueryData(
        ["chats", "8", ""],
        chatPayload({
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
        })
      )
    })

    expect(await screen.findByText("The water still flows.")).toBeInTheDocument()
    await waitFor(() => expect(stream.scrollTop).toBe(1200))
    expect(screen.queryByRole("button", { name: /new messages?/ })).not.toBeInTheDocument()
  })

  it("shows a new message button when messages arrive away from the bottom", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
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
      queryClient.setQueryData(
        ["chats", "8", ""],
        chatPayload({
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
        })
      )
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
          questions: [{ question: "Which route should I take?", options: ["Fast path", "Careful path"], multiple: false }],
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

  it("renders shared chats as read-only message streams", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
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
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
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

  it("shows the pinned chat provider without offering chat provider switching", async () => {
    const providerOptions = [
      { value: "claude", label: "Claude", configured: true, effective_provider: "claude", effective_label: "Claude" },
      { value: "codex", label: "Codex", configured: true, effective_provider: "codex", effective_label: "Codex" }
    ]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/switch_provider" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Switching to codex." }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      return Promise.resolve(
        new Response(
          JSON.stringify(
            chatPayload({
              chatProvider: "claude",
              effectiveChatProvider: "claude",
              chatProviderOptions: providerOptions
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
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

    await screen.findByText("Provider")
    expect(screen.getByText("Claude")).toBeInTheDocument()
    expect(screen.queryByLabelText("Chat provider")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/switch_provider", expect.anything())
  })

  it("renders raw chat messages on the frontend", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
                  content: {
                    result: [
                      {
                        type: "text",
                        text: "1  # RSpec config\n2  RSpec.configure do |config|\n3    config.expect_with :rspec do |expectations|\n4      expectations.include_chain_clauses_in_custom_matcher_descriptions = true\n5    end\n6  end"
                      }
                    ]
                  },
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
                    result: [
                      {
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
                      }
                    ]
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Inspected 2 sources")).toBeInTheDocument()
    expect(screen.getAllByText(/app\/models\/chat\.rb/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/spec\/rails_helper\.rb/).length).toBeGreaterThan(0)
    const railsHelperDetails = screen.getAllByText(/spec\/rails_helper\.rb/)[0]?.closest("details")
    expect(railsHelperDetails).not.toBeNull()
    if (!railsHelperDetails) return
    const railsHelperSummary = railsHelperDetails.querySelector("summary")
    expect(railsHelperSummary).not.toBeNull()
    if (!railsHelperSummary) return
    if (!railsHelperDetails.open) fireEvent.click(railsHelperSummary)
    await waitFor(() => expect(screen.getByText("# RSpec config").style.color).toBe("var(--shiki-token-comment)"))
    expect(screen.getAllByText("do")[0].style.color).toBe("var(--shiki-token-keyword)")
    expect(screen.getByText(":rspec").style.color).toBe("var(--shiki-token-constant)")
    expect(screen.getByText("true").style.color).toBe("var(--shiki-token-constant)")
    expect(screen.getByText("Bash (3)")).toBeInTheDocument()
    expect(screen.getAllByText(/rg queue_as app\/jobs/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/bin\/rspec spec\/models\/job_spec\.rb/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/rg perform app\/jobs/).length).toBeGreaterThan(0)
    expect(screen.getByText("9 paths")).toBeInTheDocument()
    const globDetails = screen.getByText("9 paths").closest("details")
    expect(globDetails).not.toBeNull()
    if (!globDetails) return
    globDetails.open = true
    fireEvent(globDetails, new Event("toggle"))
    expect(screen.getByText(/spec\/services\/chat_workspace_spec\.rb/)).toBeInTheDocument()
    expect(screen.queryByText(/\/syrus-home\/\.syrus\/chat-workspaces/)).not.toBeInTheDocument()
    expect(screen.queryByText(/\/syrus-home\/\.syrus\/workflows/)).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByText("Chat").style.color).toBe("var(--shiki-token-function)"))
    expect(screen.getAllByText("class")[0].style.color).toBe("var(--shiki-token-keyword)")
    expect(screen.getAllByText("end")[0].style.color).toBe("var(--shiki-token-keyword)")
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
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Tool result")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Queue setup" })).not.toBeInTheDocument()
  })

  it("renders Codex tool rows with descriptive tool labels", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Repo info")).toBeInTheDocument()
    expect(screen.queryByText("tool_use")).not.toBeInTheDocument()
  })

  it("shows Copy button on chat messages and copies text to clipboard", async () => {
    const writeTextSpy = vi.fn().mockImplementation(async () => undefined)
    Object.defineProperty(navigator, "clipboard", { value: { writeText: writeTextSpy }, configurable: true })

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
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent("4 minutes ago")
    expect(timeEl).toHaveAttribute("dateTime", recentCreatedAt)
  })

  it("shows absolute timestamp on chat message with created_at more than 24 hours ago (same year)", async () => {
    const now = new Date()
    const pastDate = new Date(now.getFullYear(), 0, 15, 10, 29, 0)
    const oldCreatedAt = pastDate.toISOString()
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent("1/15, 10:29 AM")
    expect(timeEl).toHaveAttribute("dateTime", oldCreatedAt)
  })

  it("shows year in timestamp on chat message with created_at from a previous year", async () => {
    const previousYearDate = new Date(new Date().getFullYear() - 1, 6, 5, 22, 29, 0)
    const oldCreatedAt = previousYearDate.toISOString()
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
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
            })
          ),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    const timeEl = screen.getByRole("time")
    expect(timeEl).toHaveTextContent(`7/5/${new Date().getFullYear() - 1}, 10:29 PM`)
    expect(timeEl).toHaveAttribute("dateTime", oldCreatedAt)
  })

  it("loads older chat messages when scrolling near the top", async () => {
    const restoreSize = stubChatStreamSize({ scrollHeight: 1200, clientHeight: 600 })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
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
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      return Promise.resolve(
        new Response(JSON.stringify(chatPayload({ hasMoreOlder: true })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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

  it("loads older chat messages when touch-dragging at the top edge without a scroll event", async () => {
    const restoreSize = stubChatStreamSize({ scrollHeight: 1200, clientHeight: 600 })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
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
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(chatPayload({ hasMoreOlder: true })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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
      setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 600, scrollTop: 0 })
      fireEvent.touchMove(stream)

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
        return Promise.resolve(
          new Response(
            JSON.stringify({
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
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(chatPayload({ hasMoreOlder: true })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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

  it("ignores a message_id query param and opens the chat at the latest messages without scrolling", async () => {
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

      await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8?message_id=9", expect.objectContaining({ credentials: "same-origin" })))
      expect(await screen.findByTestId("chat-message-stream")).toBeInTheDocument()
      expect(scrollIntoView).not.toHaveBeenCalled()
    } finally {
      fetchSpy.mockRestore()
    }
  })
})
