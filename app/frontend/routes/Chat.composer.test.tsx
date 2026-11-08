import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { actionCable } from "../test/app/appMocks"
import { chatPayload } from "../test/app/chatPayloads"
import { setViewportWidth } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat composer", () => {
  installAppTestLifecycle()

  it("renders a centered landing layout for an empty chat", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } })
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
    expect(screen.getByPlaceholderText("Ask about this repository...").closest("form")?.parentElement?.parentElement).toHaveClass("max-w-sm", "sm:max-w-2xl")
  })

  it("moves the empty chat landing into the standard chat layout after the first send succeeds", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              chatPayload({
                messages: [
                  {
                    type: "message",
                    id: 10,
                    role: "user",
                    text: "Build a planning console",
                    bookmarkable: true
                  }
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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
          body: expect.stringContaining('"chat_provider":"claude","client_idempotency_key":"')
        })
      )
    })
    expect(await screen.findByText("Build a planning console")).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole("heading", { name: "What would you like to build?" })).not.toBeInTheDocument())
    expect(screen.getByTestId("chat-message-stream").parentElement?.parentElement).toHaveClass("flex-1", "opacity-100")
    expect(within(input.closest("form") as HTMLElement).queryByText("acme/widgets")).not.toBeInTheDocument()
  })

  it("hides scratch pad controls from the initial composer", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload({ messages: [] })), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("heading", { name: "What would you like to build?" })).toBeInTheDocument()

    fireEvent.change(input, { target: { value: "Build the operator briefing" } })
    expect(screen.queryByRole("button", { name: "Stash" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Upload file" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Scratch pad" })).not.toBeInTheDocument()
  })

  it("renders non-empty chats in the standard layout immediately", async () => {
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
    expect(screen.queryByRole("heading", { name: "What would you like to build?" })).not.toBeInTheDocument()
    expect(screen.getByTestId("chat-message-stream").parentElement?.parentElement).toHaveClass("flex-1", "opacity-100")
  })

  it("sends chat messages with Enter on desktop", async () => {
    const restoreViewport = setViewportWidth(1280)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              chatPayload({
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
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
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
      fireEvent.change(input, { target: { value: "Send this with enter" } })
      expect(fireEvent.keyDown(input, { key: "Enter" })).toBe(false)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/chats/8/message",
          expect.objectContaining({
            method: "POST",
            body: expect.stringContaining('"chat_message":{"text":"Send this with enter"}')
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

      const input = await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.change(input, { target: { value: "Keep editing on mobile" } })
      expect(fireEvent.keyDown(input, { key: "Enter" })).toBe(true)
      expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
    } finally {
      restoreViewport()
    }
  })

  it("shows an animated chat agent activity indicator", async () => {
    vi.spyOn(Math, "random").mockReturnValue(0)
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify(
            chatPayload({
              agentBusy: true,
              turnInFlight: false,
              agentActivity: {
                label: "running commands",
                raw_name: "exec_command",
                in_flight: true,
                elapsed_seconds: 83,
                idle_seconds: 12,
                transcript_bytes: 4096
              }
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

    const status = await screen.findByRole("status", { name: "thinking it through; running commands for 1m" })
    expect(status).toHaveTextContent("Cogitans")
    expect(status).toHaveTextContent("running commands")
    expect(status).toHaveTextContent("1m")
    expect(screen.getByTitle("thinking it through")).toHaveTextContent("Cogitans")
    expect(screen.getByTitle("running commands for 1m")).toHaveTextContent("running commands")
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
        return Promise.resolve(
          new Response(JSON.stringify(chatPayload({ agentBusy: true, queuedMessages })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/chats/8/queued_messages/14" && init?.method === "PATCH") {
        queuedMessages = []
        return Promise.resolve(
          new Response(JSON.stringify(chatPayload({ agentBusy: true, queuedMessages })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(
          new Response(JSON.stringify(chatPayload({ agentBusy: true, turnInFlight: false, queuedMessages })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
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
    expect(stop).toHaveClass("h-8", "w-8")
    expect(stop).not.toHaveClass("h-11", "px-3")
  })

  it("shows a starting state before the chat agent process is running", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
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
        return Promise.resolve(
          new Response(
            JSON.stringify(
              chatPayload({
                agentBusy: true,
                stopRequestedAt: "2026-07-01T12:00:00Z"
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
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
})
