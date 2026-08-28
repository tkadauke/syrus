import { jsonResponse } from "../testSupport"
import tailwindConfigSource from "../../../config/tailwind.config.js?raw"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { Link, MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { ChatRoute } from "./Chat"
import { CHAT_WORKSPACE_SPLIT_MIN_WIDTH } from "./chat/constants"
import { ConnectionContext } from "../lib/connectionContext"
import { getStartingPhrase } from "./chat/streamChrome"
import { shouldAnimateMessageEntrance } from "./chat/MessageCards"
import { numericArg } from "./chat/utils"
import { storedWorkspaceCollapsed, storedWorkspaceTab, workspaceTabLabel, mobileChatTabLabel, type WorkspaceTab } from "./chat/workspaceTabs"
import { buildMessageStreamItems, renderChatMessages } from "./chat/streamBuilders"
import { asExcalidrawElements, VALID_EXCALIDRAW_TYPES } from "./chat/whiteboardScene"
import { __resetDraftAttachmentsForTests } from "./chat/attachmentDraftStore"

const actionCableSubscriptions: Array<{ params: Record<string, string | number>; mixin: { connected?: () => void; received: (data: unknown) => void } }> = []

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: (params: Record<string, string | number>, mixin: { connected?: () => void; received: (data: unknown) => void }) => {
        actionCableSubscriptions.push({ params, mixin })
        return {
          perform: vi.fn(),
          unsubscribe: vi.fn()
        }
      }
    }
  })
}))

afterEach(() => {
  actionCableSubscriptions.length = 0
  vi.unstubAllGlobals()
  __resetDraftAttachmentsForTests()
})

describe("storedWorkspaceCollapsed", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("defaults to collapsed when the preference is absent", () => {
    expect(storedWorkspaceCollapsed()).toBe(true)
  })

  it("returns the stored boolean preference", () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    expect(storedWorkspaceCollapsed()).toBe(false)

    window.localStorage.setItem("syrus.chat.workspace.collapsed", "true")
    expect(storedWorkspaceCollapsed()).toBe(true)
  })
})

describe("storedWorkspaceTab", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("returns null when no preference is stored", () => {
    expect(storedWorkspaceTab()).toBeNull()
  })

  it("returns a stored fixed core tab", () => {
    window.localStorage.setItem("syrus.chat.workspace.tab", "media")
    expect(storedWorkspaceTab()).toBe("media")
  })

  it("returns a stored plugin tab, e.g. the whiteboard, so it survives a reload", () => {
    window.localStorage.setItem("syrus.chat.workspace.tab", "plugin:whiteboard_tools.canvas")
    expect(storedWorkspaceTab()).toBe("plugin:whiteboard_tools.canvas")
  })

  it("discards an unrecognized stored value", () => {
    window.localStorage.setItem("syrus.chat.workspace.tab", "not-a-real-tab")
    expect(storedWorkspaceTab()).toBeNull()
  })
})

describe("workspaceTabLabel", () => {
  const mockT = (key: string) => `T:${key}`

  it("maps each workspace tab to its translation key", () => {
    expect(workspaceTabLabel("context", mockT)).toBe("T:tab_context")
    expect(workspaceTabLabel("media", mockT)).toBe("T:tab_media")
    expect(workspaceTabLabel("files", mockT)).toBe("T:tab_files")
    expect(workspaceTabLabel("diff", mockT)).toBe("T:tab_diff")
    expect(workspaceTabLabel("jobs", mockT)).toBe("T:tab_jobs")
  })

  it("resolves a plugin tab's label_key against the plugin's own namespace", () => {
    const pluginTabs = [
      { id: "my_plugin.status", label: "Status", label_key: "my_plugin:tab_status", component: "my_plugin/Status", order: 0 }
    ]

    expect(workspaceTabLabel("plugin:my_plugin.status" as WorkspaceTab, mockT, [], pluginTabs)).toBe("T:my_plugin:tab_status")
  })

  it("falls back to the tab's plain label when it has no label_key", () => {
    const pluginTabs = [
      { id: "my_plugin.status", label: "Status", label_key: null, component: "my_plugin/Status", order: 0 }
    ]

    expect(workspaceTabLabel("plugin:my_plugin.status" as WorkspaceTab, mockT, [], pluginTabs)).toBe("Status")
  })

  it("falls back to tab_plugin when the plugin tab is unknown", () => {
    expect(workspaceTabLabel("plugin:missing.tab" as WorkspaceTab, mockT)).toBe("T:tab_plugin")
  })
})

describe("mobileChatTabLabel", () => {
  const mockT = (key: string) => `T:${key}`

  it("uses tab_chat for the chat tab", () => {
    expect(mobileChatTabLabel("chat", mockT)).toBe("T:tab_chat")
  })

  it("delegates to workspaceTabLabel for workspace tabs", () => {
    expect(mobileChatTabLabel("context", mockT)).toBe("T:tab_context")
    expect(mobileChatTabLabel("jobs", mockT)).toBe("T:tab_jobs")
  })

  it("delegates to workspaceTabLabel for plugin tabs, passing pluginTabs through", () => {
    const pluginTabs = [
      { id: "my_plugin.status", label: "Status", label_key: null, component: "my_plugin/Status", order: 0 }
    ]

    expect(mobileChatTabLabel("plugin:my_plugin.status" as WorkspaceTab, mockT, [], pluginTabs)).toBe("Status")
  })
})

describe("numericArg", () => {
  it("accepts bare IDs and JOB-prefixed IDs", () => {
    expect(numericArg("123")).toBe("123")
    expect(numericArg("JOB-123")).toBe("123")
    expect(numericArg("job-123")).toBe("123")
    expect(numericArg("EPIC-123")).toBeNull()
  })
})

describe("asExcalidrawElements", () => {
  it("filters out elements with an unknown type", () => {
    const elements = [
      { id: "r1", type: "rectangle" },
      { id: "s1", type: "sticky" },
      { id: "t1", type: "text" },
      { id: "u1", type: "unknown-future-type" }
    ]

    const result = asExcalidrawElements(elements)
    const ids = (result as unknown as Array<{ id: string }>).map(el => el.id)

    expect(ids).toContain("r1")
    expect(ids).toContain("t1")
    expect(ids).not.toContain("s1")
    expect(ids).not.toContain("u1")
  })

  it("passes through all valid Excalidraw types", () => {
    const validTypes = [...VALID_EXCALIDRAW_TYPES]
    const elements = validTypes.map((type, i) => ({ id: `el-${i}`, type }))

    const result = asExcalidrawElements(elements)

    expect(result).toHaveLength(validTypes.length)
  })

  it("returns an empty array for an empty input", () => {
    expect(asExcalidrawElements([])).toEqual([])
  })
})

describe("getStartingPhrase", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("returns the Ides of March phrase on March 15", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(2026, 2, 15))
    expect(getStartingPhrase()).toEqual({ latin: "Cave, Idus Martias.", english: "Beware the Ides of March." })
  })

  it("returns Accingitur on March 14", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(2026, 2, 14))
    expect(getStartingPhrase()).toEqual({ latin: "Accingitur", english: "girding itself" })
  })

  it("returns Accingitur on March 16", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date(2026, 2, 16))
    expect(getStartingPhrase()).toEqual({ latin: "Accingitur", english: "girding itself" })
  })
})

describe("ChatWorkspace panel collapse", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    mockDesktopViewport()
  })

  it("renders a collapsed strip by default and toggles the workspace panel", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("complementary", { name: "Chat workspace" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Open workspace panel" }))

    expect(await screen.findByRole("complementary", { name: "Chat workspace" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Close workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open workspace panel" })).not.toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("false")

    fireEvent.click(screen.getByRole("button", { name: "Close workspace panel" }))

    expect(screen.queryByRole("complementary", { name: "Chat workspace" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("true")
    })
  }, 15000)
})

describe("ChatWorkspace split breakpoint", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("renders the mobile tab-strip layout between the 1024px app breakpoint and its own wider split breakpoint", async () => {
    mockViewportWidth(CHAT_WORKSPACE_SPLIT_MIN_WIDTH - 1)
    mockChatRouteFetch()

    renderRoute()

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("navigation", { name: "Chat mobile tabs" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open workspace panel" })).not.toBeInTheDocument()
  })

  it("renders the normal desktop split at and above its own wider split breakpoint", async () => {
    mockViewportWidth(CHAT_WORKSPACE_SPLIT_MIN_WIDTH)
    mockChatRouteFetch()

    renderRoute()

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Chat mobile tabs" })).not.toBeInTheDocument()
  })
})

describe("chat message tail refetch", () => {
  it("preserves older messages when a background refetch returns only the latest page", async () => {
    const olderMessage = {
      type: "message",
      id: 1,
      role: "user",
      tool_name: null,
      content: { text: "What did the aqueduct plan say?" },
      text: "What did the aqueduct plan say?",
      bookmarkable: true
    }
    const newerMessage = {
      type: "message",
      id: 9,
      role: "assistant",
      tool_name: null,
      content: { text: "Discuss aqueducts." },
      text: "Discuss aqueducts.",
      bookmarkable: true
    }

    let chatGetCount = 0
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8") {
        chatGetCount += 1
        // First load simulates a long chat whose history (like `olderMessage`) grew past a
        // single server page via live websocket tail updates. A later refetch (e.g. triggered
        // by an Action Cable reconnect) only ever returns the server's latest page, which must
        // not clobber the history already shown.
        const messages = chatGetCount === 1 ? [olderMessage, newerMessage] : [newerMessage]
        return Promise.resolve(jsonResponse(chatPayload({ messages })))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <Routes>
            <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("What did the aqueduct plan say?")).toBeInTheDocument()
    expect(screen.getByText("Discuss aqueducts.")).toBeInTheDocument()

    await act(async () => {
      await queryClient.refetchQueries({ queryKey: ["chats", "8", ""] })
    })

    await waitFor(() => expect(chatGetCount).toBe(2))
    expect(screen.getByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByText("What did the aqueduct plan say?")).toBeInTheDocument()
  })

  it("preserves older messages across the real Action Cable stale-reconnect refetch mid-turn", async () => {
    const olderMessage = {
      type: "message",
      id: 1,
      role: "user",
      tool_name: null,
      content: { text: "What did the aqueduct plan say?" },
      text: "What did the aqueduct plan say?",
      bookmarkable: true
    }
    const newerMessage = {
      type: "message",
      id: 9,
      role: "assistant",
      tool_name: null,
      content: { text: "Discuss aqueducts." },
      text: "Discuss aqueducts.",
      bookmarkable: true
    }

    let chatGetCount = 0
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8") {
        chatGetCount += 1
        const messages = chatGetCount === 1 ? [olderMessage, newerMessage] : [newerMessage]
        return Promise.resolve(jsonResponse(chatPayload({ messages }, { turn_in_flight: true })))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    function Harness({ reconnectAt }: { reconnectAt: number | null }) {
      return (
        <QueryClientProvider client={queryClient}>
          <ConnectionContext.Provider value={{ reconnectAt }}>
            <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
              <Routes>
                <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
              </Routes>
            </MemoryRouter>
          </ConnectionContext.Provider>
        </QueryClientProvider>
      )
    }

    const { rerender } = render(<Harness reconnectAt={null} />)

    expect(await screen.findByText("What did the aqueduct plan say?")).toBeInTheDocument()
    expect(screen.getByText("Discuss aqueducts.")).toBeInTheDocument()

    // Simulate the Action Cable ConnectionMonitor reopening a stale connection after the
    // tab was backgrounded (e.g. by the OS screenshot tool) — exactly what drives
    // useChatControlsRefetchOnReconnect's real refetchQueries call on reconnect.
    await act(async () => {
      rerender(<Harness reconnectAt={1000} />)
    })

    await waitFor(() => expect(chatGetCount).toBe(2))
    expect(screen.getByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.getByText("What did the aqueduct plan say?")).toBeInTheDocument()
  })

  it("polls the chat query every 30 seconds as a fallback for a silently dead websocket", async () => {
    vi.useFakeTimers()

    try {
      let chatGetCount = 0
      vi.spyOn(window, "fetch").mockImplementation((input, init) => {
        const path = String(input)
        if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
          return Promise.resolve(new Response(null, { status: 204 }))
        }
        if (path === "/api/v1/app/chats/8") {
          chatGetCount += 1
        }

        return Promise.resolve(jsonResponse(chatPayload()))
      })

      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <Routes>
              <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

      await act(async () => { await vi.advanceTimersByTimeAsync(0) })
      expect(chatGetCount).toBe(1)

      // No Action Cable reconnect event fires (the connection is a zombie, not properly
      // closed) — only the 30s refetchInterval backstop should recover the chat state.
      await act(async () => { await vi.advanceTimersByTimeAsync(29_999) })
      expect(chatGetCount).toBe(1)

      await act(async () => { await vi.advanceTimersByTimeAsync(1) })
      expect(chatGetCount).toBe(2)
    } finally {
      vi.useRealTimers()
    }
  })
})

describe("chat compose with an omitted attachment_groups payload", () => {
  it("renders the landing view instead of crashing when attachment_groups is absent from the response", async () => {
    // Regression test for a production crash ("undefined is not an object (evaluating
    // 'n.map')"): Compose read `payload.attachment_groups.repositories` unconditionally on
    // every render. `attachment_groups` is normally always present, but ChatPayload types it
    // as optional (it doubles as the shape of the lazy /context payload), so any response that
    // omits the key — an older cached fetch, a future lazy-loading change — must not crash.
    mockChatRouteFetch(chatPayload({ messages: [] }, { attachment_groups: undefined }))

    renderRoute()

    expect(await screen.findByText("What would you like to build?")).toBeInTheDocument()
  })
})

describe("simple mode chat transcript", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    setBootstrapMode("simple")
  })

  afterEach(() => {
    document.getElementById("syrus-bootstrap-data")?.remove()
  })

  it("renders a running tool call as a generic progress indicator", async () => {
    mockChatRouteFetch(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "tool_use",
          tool_name: "Bash",
          content: { type: "tool_use", id: "tu_1", name: "Bash", input: { command: "bin/rails db:migrate" } },
          text: "",
          bookmarkable: false
        }
      ]
    }))

    renderRoute()

    expect(await screen.findByText("Making changes...")).toBeInTheDocument()
    expect(screen.queryByText("Bash")).not.toBeInTheDocument()
    expect(screen.queryByText(/bin\/rails/)).not.toBeInTheDocument()
  })

  it("removes completed successful tool calls from the transcript", async () => {
    mockChatRouteFetch(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "tool_use",
          tool_name: "Read",
          content: { type: "tool_use", id: "tu_1", name: "Read", input: { file_path: "/app/models/job.rb" } },
          text: "",
          bookmarkable: false
        },
        {
          type: "message",
          id: 10,
          role: "tool_result",
          tool_name: "Read",
          content: { type: "tool_result", tool_use_id: "tu_1", content: [{ type: "text", text: "class Job < ApplicationRecord" }], is_error: false },
          text: "",
          bookmarkable: false
        }
      ]
    }))

    renderRoute()

    await screen.findByTestId("chat-message-stream")
    expect(screen.queryByText("Reading code...")).not.toBeInTheDocument()
    expect(screen.queryByText("Read")).not.toBeInTheDocument()
    expect(screen.queryByText(/app\/models\/job\.rb/)).not.toBeInTheDocument()
    expect(screen.queryByText(/class Job/)).not.toBeInTheDocument()
  })

  it("shows only a generic snag message for errored tool calls", async () => {
    mockChatRouteFetch(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "tool_use",
          tool_name: "Grep",
          content: { type: "tool_use", id: "tu_1", name: "Grep", input: { pattern: "secret", path: "/repo/app" } },
          text: "",
          bookmarkable: false
        },
        {
          type: "message",
          id: 10,
          role: "tool_result",
          tool_name: "Grep",
          content: { type: "tool_result", tool_use_id: "tu_1", content: "rg failed in /repo/app", is_error: true },
          text: "",
          bookmarkable: false
        }
      ]
    }))

    renderRoute()

    expect(await screen.findByText("Hit a snag")).toBeInTheDocument()
    expect(screen.queryByText("Grep")).not.toBeInTheDocument()
    expect(screen.queryByText(/secret/)).not.toBeInTheDocument()
    expect(screen.queryByText(/repo\/app/)).not.toBeInTheDocument()
  })

  it("omits the context tab from the workspace DOM", async () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    mockChatRouteFetch(chatPayload({
      messages: [
        {
          type: "message",
          id: 9,
          role: "user",
          tool_name: null,
          content: { text: "Screenshot." },
          text: "Screenshot.",
          bookmarkable: true,
          attachments: [{ name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" }]
        }
      ]
    }))

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    const workspace = screen.getByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).queryByRole("button", { name: "Context" })).not.toBeInTheDocument()
    expect(within(workspace).getByRole("button", { name: "Whiteboard" })).toBeInTheDocument()
    expect(within(workspace).getByRole("button", { name: "Media" })).toBeInTheDocument()
  })
})

describe("error system message retry", () => {
  it("resends the user message that triggered a failed turn when Retry now is clicked", async () => {
    const failedTurnPayload = chatPayload({
      messages: [
        {
          type: "message",
          id: 20,
          role: "user",
          content: { text: "does syrus have that feature?" },
          text: "does syrus have that feature?",
          bookmarkable: true
        },
        {
          type: "message",
          id: 21,
          role: "system",
          content: { text: "Claude authentication failed. Refresh the Claude OAuth token in Credentials, then send the message again." },
          text: "Claude authentication failed. Refresh the Claude OAuth token in Credentials, then send the message again.",
          bookmarkable: false
        }
      ]
    })
    const retriedPayload = chatPayload({
      messages: [
        ...failedTurnPayload.messages,
        {
          type: "message",
          id: 22,
          role: "assistant",
          content: { text: "Yes, here's how." },
          text: "Yes, here's how.",
          bookmarkable: true
        }
      ]
    })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(retriedPayload))
      }

      return Promise.resolve(jsonResponse(failedTurnPayload))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Retry now" }))

    await screen.findByText("Yes, here's how.")

    const retryCall = fetchMock.mock.calls.find(([reqInput, reqInit]) => String(reqInput) === "/api/v1/app/chats/8/message" && (reqInit as RequestInit | undefined)?.method === "POST")
    expect(retryCall).toBeDefined()
    expect(JSON.parse(String((retryCall![1] as RequestInit).body))).toEqual({ chat_message: { text: "does syrus have that feature?" } })
  })

  it("does not show Retry now under a non-error system message", async () => {
    mockChatRouteFetch(chatPayload({
      messages: [
        {
          type: "message",
          id: 20,
          role: "user",
          content: { text: "hello" },
          text: "hello",
          bookmarkable: true
        },
        {
          type: "message",
          id: 21,
          role: "system",
          content: {
            text: "MCP unavailable",
            mcp_health: [
              { name: "syrus-chat-sidecar", status: "unavailable", available_tools: [], pending_tools: [], unavailable_tools: ["submit_summary"] }
            ]
          },
          text: "MCP unavailable",
          bookmarkable: false
        }
      ]
    }))

    renderRoute()

    expect(await screen.findByTestId("system-message-summary")).toHaveTextContent(/MCP unavailable/)
    expect(screen.queryByRole("button", { name: "Retry now" })).not.toBeInTheDocument()
  })
})

describe("chat compose drafts", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("restores and persists the saved draft for the current chat", async () => {
    window.localStorage.setItem("syrus.chat.draft.8", "Please inspect the channel routing.")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    expect(textarea).toHaveValue("Please inspect the channel routing.")

    fireEvent.change(textarea, { target: { value: "Follow the operator chat draft." } })

    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.draft.8")).toBe("Follow the operator chat draft.")
    })
  }, 30000)
})

describe("chat composer dictation", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  afterEach(() => {
    delete window.syrusShell
  })

  it("hides the microphone button when speech-to-text is feature-disabled", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: /dictation/i })).not.toBeInTheDocument()
  })

  it("uses streaming dictation first and does not auto-send", async () => {
    installMediaRecorderMock()
    mockAudioPermission()
    const fetchMock = mockDictationFetch(chatPayloadWithDictation({ streaming: true, batch: true, browser: true }))
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "Review" } })
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await waitFor(() => expect(actionCableSubscriptions).toHaveLength(1))
    await act(async () => {
      actionCableSubscriptions[0].mixin.connected?.()
      actionCableSubscriptions[0].mixin.received({ type: "transcript_delta", text: "the failing grader", final: true })
      actionCableSubscriptions[0].mixin.received({ type: "done" })
    })

    await waitFor(() => expect(textarea).toHaveValue("Review the failing grader"))
    expect(fetchMock.mock.calls.some((call) => String(call[0]) === "/api/v1/app/chats/8/message")).toBe(false)

    fireEvent.click(screen.getByRole("button", { name: "Send message" }))
    await waitFor(() => {
      expect(fetchMock.mock.calls.some((call) => String(call[0]) === "/api/v1/app/chats/8/message" && (call[1] as RequestInit | undefined)?.method === "POST")).toBe(true)
    })
  })

  it("prewarms desktop microphone permission before backend recording", async () => {
    installMediaRecorderMock()
    const prewarmMicrophone = vi.fn(() => Promise.resolve({ granted: true }))
    window.syrusShell = {
      dictation: { prewarmMicrophone }
    } as unknown as typeof window.syrusShell
    mockAudioPermission()
    mockDictationFetch(chatPayloadWithDictation({ batch: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await waitFor(() => expect(prewarmMicrophone).toHaveBeenCalled())
    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalled()
    const prewarmOrder = prewarmMicrophone.mock.invocationCallOrder[0]
    const getUserMediaOrder = vi.mocked(navigator.mediaDevices.getUserMedia).mock.invocationCallOrder[0]
    expect(prewarmOrder).toBeLessThan(getUserMediaOrder)
  })

  it("falls back from streaming failure to backend batch transcription", async () => {
    installMediaRecorderMock()
    mockAudioPermission()
    mockDictationFetch(chatPayloadWithDictation({ streaming: true, batch: true, browser: true }), { batchText: "batch fallback text" })
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await waitFor(() => expect(actionCableSubscriptions).toHaveLength(1))
    await act(async () => {
      actionCableSubscriptions[0].mixin.connected?.()
      actionCableSubscriptions[0].mixin.received({ type: "error", message: "stream unavailable" })
    })

    await waitFor(() => expect(textarea).toHaveValue("batch fallback text"))
  })

  it("falls back to browser speech recognition when backend modes are absent", async () => {
    const recognition = installSpeechRecognitionMock()
    mockDictationFetch(chatPayloadWithDictation({ browser: true }))
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "Please" } })
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await act(async () => {
      recognition.lastInstance?.onresult?.({
        resultIndex: 0,
        results: [{ isFinal: true, 0: { transcript: "summarize this" } }]
      })
    })

    await waitFor(() => expect(textarea).toHaveValue("Please summarize this"))
  })

  it("shows a permission-denied error when microphone access is rejected", async () => {
    installMediaRecorderMock()
    mockAudioPermission(() => Promise.reject(new DOMException("denied", "NotAllowedError")))
    mockDictationFetch(chatPayloadWithDictation({ batch: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    expect(await screen.findByText("Microphone permission was denied.")).toBeInTheDocument()
  })

  it("quietly resets to idle without an error toast on no-speech", async () => {
    const recognition = installSpeechRecognitionMock()
    mockDictationFetch(chatPayloadWithDictation({ browser: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await act(async () => {
      recognition.lastInstance?.onerror?.({ error: "no-speech" })
    })

    expect(await screen.findByText("No speech detected.")).toBeInTheDocument()
    expect(screen.queryByText("Dictation failed.")).not.toBeInTheDocument()
    expect(await screen.findByRole("button", { name: "Start dictation" })).toBeInTheDocument()
  })

  it("quietly resets to idle without an error toast when aborted follows a user-initiated stop", async () => {
    const recognition = installSpeechRecognitionMock()
    mockDictationFetch(chatPayloadWithDictation({ browser: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))
    await screen.findByRole("button", { name: "Stop dictation" })

    fireEvent.click(screen.getByRole("button", { name: "Stop dictation" }))
    await act(async () => {
      recognition.lastInstance?.onerror?.({ error: "aborted" })
    })

    expect(screen.queryByText("Dictation failed.")).not.toBeInTheDocument()
    expect(await screen.findByRole("button", { name: "Start dictation" })).toBeInTheDocument()
  })

  it("shows the error toast when aborted fires without a user-initiated stop", async () => {
    const recognition = installSpeechRecognitionMock()
    mockDictationFetch(chatPayloadWithDictation({ browser: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await act(async () => {
      recognition.lastInstance?.onerror?.({ error: "aborted" })
    })

    expect(await screen.findByText("Dictation failed.")).toBeInTheDocument()
  })

  it("shows the error toast for unrecognized error codes", async () => {
    const recognition = installSpeechRecognitionMock()
    mockDictationFetch(chatPayloadWithDictation({ browser: true }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Start dictation" }))

    await act(async () => {
      recognition.lastInstance?.onerror?.({ error: "audio-capture" })
    })

    expect(await screen.findByText("Dictation failed.")).toBeInTheDocument()
  })
})

describe("chat attachment popup", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders compact attachment type tabs without the select or search submit button", async () => {
    mockChatRouteFetch()
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))

    const dialog = screen.getByRole("dialog", { name: "Add attachment" })
    expect(within(dialog).queryByRole("combobox")).not.toBeInTheDocument()
    for (const label of ["Repo", "Epic", "Job", "Doc"]) {
      expect(within(dialog).getByRole("button", { name: label })).toBeInTheDocument()
    }
    expect(within(dialog).queryByRole("button", { name: "Search" })).not.toBeInTheDocument()
    await waitFor(() => {
      expect(within(dialog).getByPlaceholderText("Search by name or id...")).toHaveFocus()
    })
  })

  it("only offers document attachment search for Supervisor chats", async () => {
    mockChatRouteFetch(chatPayload({
      chat: { repository: null, system_kind: "supervisor", title: "Supervisor" },
      attachment_results: [
        { type: "Repository", id: 4, label: "acme/tools" },
        { type: "Epic", id: 2, label: "Release planning" },
        { type: "Job", id: 3, label: "JOB-3" },
        { type: "Document", id: 5, label: "Runbook.md" }
      ]
    }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about incidents, stuck Jobs, Workflows, Runs, queues, PRs, or operational state...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))

    const dialog = screen.getByRole("dialog", { name: "Add attachment" })
    expect(within(dialog).getByRole("button", { name: "Doc" })).toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Repo" })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Epic" })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Job" })).not.toBeInTheDocument()
    expect(within(dialog).getByRole("button", { name: "Runbook.md" })).toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "acme/tools" })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "Release planning" })).not.toBeInTheDocument()
    expect(within(dialog).queryByRole("button", { name: "JOB-3" })).not.toBeInTheDocument()
  })

  it("updates the attachment search URL from tabs and debounced input", async () => {
    mockChatRouteFetch()
    renderRouteWithLocation()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(screen.getByRole("button", { name: "Epic" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/8?attachment_type=Epic")
    })

    fireEvent.change(screen.getByPlaceholderText("Search by name or id..."), { target: { value: "roadmap" } })

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/chats/8?attachment_type=Epic&attachment_query=roadmap")
    })
  })

  it("keeps the attachment popup open while tab results load", async () => {
    let resolveEpicSearch: () => void = () => {
      throw new Error("Epic attachment search was not requested.")
    }
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/context?attachment_type=Epic") {
        return new Promise((resolve) => {
          resolveEpicSearch = () => resolve(jsonResponse({
            attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
            documents_in_scope: [],
            attachment_results: [{ type: "Epic", id: 2, label: "Release planning" }]
          }))
        })
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRouteWithLocation()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(screen.getByRole("button", { name: "Epic" }))

    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Job" })).toBeInTheDocument()

    resolveEpicSearch()
    expect(await screen.findByRole("button", { name: "Release planning" })).toBeInTheDocument()
  })

  it("keeps the upload file row wired to the hidden file picker", async () => {
    mockChatRouteFetch()
    const inputClickSpy = vi.spyOn(HTMLInputElement.prototype, "click").mockImplementation(() => undefined)

    try {
      renderRoute()

      await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
      fireEvent.click(screen.getByRole("button", { name: "Upload file" }))

      expect(inputClickSpy).toHaveBeenCalled()
    } finally {
      inputClickSpy.mockRestore()
    }
  })

  it("renders attachment results as plain buttons without card borders", async () => {
    mockChatRouteFetch(chatPayload({
      attachment_results: [{ type: "Repository", id: 4, label: "acme/tools" }]
    }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))

    expect(screen.getByRole("button", { name: "acme/tools" })).not.toHaveClass("border")
  })
})

describe("chat slash commands", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("navigates /jobs to the jobs route", async () => {
    mockChatRouteFetch()
    renderRouteWithLocation()

    await submitSlashCommand("/jobs stale")

    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/jobs?q=stale")
  })

  it("navigates /job to the Job detail route", async () => {
    mockChatRouteFetch()
    renderRouteWithLocation()

    await submitSlashCommand("/job 42")

    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/jobs/42")
  })

  it("navigates /epic to the Epic detail route", async () => {
    mockChatRouteFetch()
    renderRouteWithLocation()

    await submitSlashCommand("/epic 7")

    expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/epics/7")
  })

  it("schedules a message immediately when /schedule has time and message args", async () => {
    const fetchMock = mockChatRouteFetch()
    const before = Date.now()
    renderRoute()

    await submitSlashCommand("/schedule 2h check JOB-123")

    await waitFor(() => {
      expect(fetchMock.mock.calls.some(([input]) => String(input) === "/api/v1/app/chats/8/scheduled_messages")).toBe(true)
    })
    const scheduleCall = fetchMock.mock.calls.find(([input]) => String(input) === "/api/v1/app/chats/8/scheduled_messages")
    const scheduledMessage = JSON.parse(scheduleCall?.[1]?.body as string).scheduled_message
    expect(scheduleCall?.[1]?.method).toBe("POST")
    expect(scheduledMessage.body).toBe("check JOB-123")
    expect(new Date(scheduledMessage.fire_at).getTime()).toBeGreaterThanOrEqual(before + 2 * 60 * 60 * 1000)
    expect(new Date(scheduledMessage.fire_at).getTime()).toBeLessThanOrEqual(Date.now() + 2 * 60 * 60 * 1000)
    expect(await screen.findByText(/Message scheduled for/)).toBeInTheDocument()
  })

  it("opens a schedule modal when /schedule is missing args", async () => {
    const fetchMock = mockChatRouteFetch()
    renderRoute()

    await submitSlashCommand("/schedule")

    const dialog = await screen.findByRole("dialog", { name: "Schedule Message" })
    fireEvent.change(within(dialog).getByLabelText("Time"), { target: { value: "30m" } })
    fireEvent.change(within(dialog).getByLabelText("Message"), { target: { value: "Check the landing queue" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Schedule" }))

    await waitFor(() => {
      expect(fetchMock.mock.calls.some(([input]) => String(input) === "/api/v1/app/chats/8/scheduled_messages")).toBe(true)
    })
    const scheduleCall = fetchMock.mock.calls.find(([input]) => String(input) === "/api/v1/app/chats/8/scheduled_messages")
    expect(JSON.parse(scheduleCall?.[1]?.body as string).scheduled_message.body).toBe("Check the landing queue")
  })

  for (const command of ["/discard JOB-DRAFT-1", "/cancel 42", "/retry 42", "/clear-canvas"]) {
    it(`shows confirmation before executing ${command}`, async () => {
      const fetchMock = mockChatRouteFetch(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      }))
      renderRoute()

      await submitSlashCommand(command)

      expect(screen.getByText(`Confirm ${command.split(" ")[0]}`)).toBeInTheDocument()
      expect(fetchMock.mock.calls.some(([input]) => String(input).includes("/reject") || String(input).includes("/cancel") || String(input).includes("/run_again") || String(input).includes("/whiteboard"))).toBe(false)
    })
  }

  it("scrolls the active command into view when navigating with arrow keys", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })
    mockChatRouteFetch()
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/" } })
    fireEvent.keyDown(textarea, { key: "ArrowDown" })

    await waitFor(() => {
      expect(scrollIntoView).toHaveBeenCalledWith({ block: "nearest" })
    })
  })

  it("approves a JOB-prefixed /approve argument after confirmation", async () => {
    const fetchMock = mockChatRouteFetch()
    renderRoute()

    await submitSlashCommand("/approve job-1095")

    expect(await screen.findByText("Confirm /approve")).toBeInTheDocument()
    expect(screen.getByText("Approve JOB-1095 for landing?")).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalledWith("/api/v1/app/jobs/1095/approve", expect.objectContaining({ method: "POST" }))

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/v1/app/jobs/1095/approve",
        expect.objectContaining({ method: "POST" })
      )
    })
    expect(await screen.findByRole("status")).toHaveTextContent("Job approved")
  })

  it("opens the implemented-job picker for /approve without an ID", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/jobs?state=implemented&repo=acme%2Fwidgets&limit=50") {
        return Promise.resolve(jsonResponse({
          count: 1,
          jobs: [
            { id: 2203, title: "Approve slash command", issue_title: "Approve slash command", state: "implemented", repository_slug: "acme/widgets" }
          ]
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })
    renderRoute()

    await submitSlashCommand("/approve")
    fireEvent.click(await screen.findByText("Approve slash command"))

    expect(screen.getByText("Approve JOB-2203 for landing?")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/v1/app/jobs/2203/approve",
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("opens the job picker for /diff without an ID and sends the selected job prompt", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/jobs?repo=acme%2Fwidgets&limit=50") {
        return Promise.resolve(jsonResponse({
          count: 1,
          jobs: [
            { id: 2204, title: "Diff slash command", issue_title: "Diff slash command", state: "implemented", repository_slug: "acme/widgets", pr_url: null }
          ]
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })
    renderRoute()

    await submitSlashCommand("/diff")
    fireEvent.click(await screen.findByText("Diff slash command"))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({ method: "POST" })
      )
    })
    const messageCall = fetchMock.mock.calls.find(([input]) => String(input) === "/api/v1/app/chats/8/message")
    expect(JSON.parse(messageCall?.[1]?.body as string).chat_message.text).toContain("get_job_diff MCP tool for job 2204")
  })
})

describe("chat temporal markers", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders a timestamp between same-day messages at least five minutes apart", async () => {
    const firstDate = localDateAt(9, 0)
    const secondDate = localDateAt(9, 6)
    mockChatPayload(chatPayload({
      messages: [
        chatMessage(9, "assistant", "First update.", firstDate),
        chatMessage(10, "assistant", "Second update.", secondDate)
      ]
    }))

    renderRoute()

    expect(await screen.findByText("First update.")).toBeInTheDocument()
    expect(screen.getByText(shortTime(secondDate))).toBeInTheDocument()
    expect(screen.getByText(shortTime(secondDate)).closest("[title]")).toHaveAttribute("title", secondDate.toLocaleString())
  })

  it("renders a day divider between messages on different local days", async () => {
    const firstDate = localDateAt(23, 58, -1)
    const secondDate = localDateAt(0, 3)
    mockChatPayload(chatPayload({
      messages: [
        chatMessage(9, "assistant", "Yesterday's note.", firstDate),
        chatMessage(10, "user", "Today's note.", secondDate)
      ]
    }))

    renderRoute()

    expect(await screen.findByText("Yesterday's note.")).toBeInTheDocument()
    expect(screen.getByText(dayLabel(secondDate))).toBeInTheDocument()
  })

  it("does not render an extra timestamp between messages less than five minutes apart", async () => {
    const firstDate = localDateAt(9, 0)
    const secondDate = localDateAt(9, 4)
    mockChatPayload(chatPayload({
      messages: [
        chatMessage(9, "assistant", "First nearby update.", firstDate),
        chatMessage(10, "assistant", "Second nearby update.", secondDate)
      ]
    }))

    renderRoute()

    expect(await screen.findByText("First nearby update.")).toBeInTheDocument()
    expect(screen.getByText(shortTime(firstDate))).toBeInTheDocument()
    expect(screen.queryByText(shortTime(secondDate))).not.toBeInTheDocument()
  })
})

describe("proposal outcome system events", () => {
  beforeEach(() => {
    window.localStorage.clear()
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      writable: true,
      value: vi.fn((query: string) => ({
        matches: query.includes("min-width: 1024px") || query.includes("pointer: fine"),
        media: query,
        onchange: null,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn()
      }))
    })
  })

  afterEach(() => {
    restoreClipboardMock?.()
    restoreClipboardMock = null
    vi.restoreAllMocks()
  })

  it("shows proposal confirmations as system events with copyable job hover-card references", async () => {
    const clipboard = mockClipboardWrite()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/jobs/88") {
        return Promise.resolve(jsonResponse({
          job: {
            id: 88,
            state: "open",
            issue_title: "Map auth",
            issue_body: "Add the auth route map.",
            title_pending: false,
            start_blocked_reason: null,
            start_blocked_details: null
          },
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            ...chatMessage(9, "system", 'Proposal confirmed. JOB-88 "Map auth" was created.', localDateAt(9, 0)),
            content: {
              text: 'Proposal confirmed. JOB-88 "Map auth" was created.',
              source: "proposal_notification",
              outcome: "confirmed",
              acknowledgment: "Confirmed JOB-88."
            },
            bookmarkable: false
          }
        ]
      })))
    })

    renderRoute()

    const notice = await screen.findByText((_, element) => element?.textContent === 'Proposal confirmed. JOB-88 "Map auth" was created.')
    expect(notice).toBeInTheDocument()
    expect(notice.closest(".bg-blue-600")).toBeNull()
    expect(notice.closest(".flex.justify-center")).toBeInTheDocument()
    const slug = screen.getByRole("button", { name: "Copy JOB-88 to clipboard" })
    fireEvent.click(slug)
    await waitFor(() => expect(clipboard).toHaveBeenCalledWith("JOB-88"))
    fireEvent.mouseEnter(slug.parentElement!)
    expect(await screen.findByText("Add the auth route map.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Show 1 hidden system message" })).not.toBeInTheDocument()
  })

  it("renders a long system message collapsed to a single-line bubble with an expand/collapse toggle", async () => {
    const longBody = 'Proposal confirmed. Epic #241 "Workout planning" was created. Child jobs: JOB-3311 "Group workout exercises into blocks", JOB-3312 "Plan, Goal, and PlannedWorkout models", JOB-3313 "Progression engine". The Epic was started; ready child Jobs are dispatching.'
    mockChatPayload(chatPayload({
      messages: [
        {
          ...chatMessage(9, "system", longBody, localDateAt(9, 0)),
          content: { text: longBody, source: "proposal_notification", outcome: "confirmed" },
          bookmarkable: false
        }
      ]
    }))

    renderRoute()

    const summary = await screen.findByTestId("system-message-summary")
    expect(summary).toHaveTextContent(longBody)
    expect(summary.className).toContain("truncate")
    expect(screen.queryByTestId("system-message-details")).not.toBeInTheDocument()

    const toggle = screen.getByRole("button", { name: "Show system message details" })
    expect(toggle).toHaveAttribute("aria-expanded", "false")

    fireEvent.click(toggle)

    const details = await screen.findByTestId("system-message-details")
    expect(details).toHaveTextContent(longBody)
    const collapseToggle = screen.getByRole("button", { name: "Hide system message details" })
    expect(collapseToggle).toHaveAttribute("aria-expanded", "true")

    fireEvent.click(collapseToggle)

    expect(screen.queryByTestId("system-message-details")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show system message details" })).toBeInTheDocument()
  })
})

describe("scoped event evaluator handoffs", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("hides evaluator handoff context while rendering the assistant result", async () => {
    const handoffText = "A scoped Syrus event evaluator decided this event needs a live chat turn."
    mockChatPayload(chatPayload({
      messages: [
        {
          ...chatMessage(9, "system", `${handoffText}\n\nEvaluator decision: {"decision":"respond"}`, localDateAt(9, 0)),
          content: {
            text: `${handoffText}\n\nEvaluator decision: {"decision":"respond"}`,
            source: "scoped_event_wakeup",
            kind: "scoped_event_evaluator_handoff",
            scoped_event_wakeup: true
          },
          bookmarkable: false
        },
        chatMessage(10, "assistant", "JOB-2552 comments were addressed on PR #2253.", localDateAt(9, 1))
      ]
    }))

    renderRoute()

    expect(await screen.findByText(/comments were addressed on PR #2253/)).toBeInTheDocument()
    expect(screen.queryByText(/A scoped Syrus event evaluator decided/)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show 1 hidden system message" })).toBeInTheDocument()
  })
})

describe("chat bookmark picker command", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn()
    })
  })

  it("opens a bookmark picker from /bookmarks and renders bookmark labels", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        bookmarks: [
          { id: 1, label: "Aqueduct marker", chat_message_id: 9, anchor_message_id: 9 },
          { id: 2, label: "Canal follow-up", chat_message_id: 10, anchor_message_id: 10 }
        ]
      })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const dialog = await screen.findByRole("dialog", { name: "Bookmarks" })
    expect(within(dialog).getByText("Aqueduct marker")).toBeInTheDocument()
    expect(within(dialog).getByText("Canal follow-up")).toBeInTheDocument()
  })

  it("loads bookmark labels on demand when the chat payload did not preload them", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/bookmarks") {
        return Promise.resolve(jsonResponse({
          bookmarks: [
            { id: 1, label: "Lazy aqueduct marker", chat_message_id: 9, anchor_message_id: 9 }
          ]
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload({ bookmarks: [] })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const dialog = await screen.findByRole("dialog", { name: "Bookmarks" })
    expect(await within(dialog).findByText("Lazy aqueduct marker")).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/bookmarks", expect.anything())
  })

  it("jumps to the selected bookmark and closes the picker", async () => {
    const scrollIntoView = vi.fn()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        bookmarks: [
          { id: 1, label: "Aqueduct marker", chat_message_id: 99, anchor_message_id: 9 }
        ]
      })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const target = await screen.findByText("Aqueduct marker")
    Object.defineProperty(document.getElementById("message-9"), "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })
    fireEvent.click(target)

    await waitFor(() => {
      expect(scrollIntoView).toHaveBeenCalledWith({ block: "start", behavior: "smooth" })
    })
    expect(screen.queryByRole("dialog", { name: "Bookmarks" })).not.toBeInTheDocument()
  })

  it("shows an empty state when the chat has no bookmarks", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(await screen.findByRole("dialog", { name: "Bookmarks" })).toBeInTheDocument()
    expect(await screen.findByText("No bookmarks yet")).toBeInTheDocument()
  })

  it("closes from the backdrop and close button without navigating", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        bookmarks: [
          { id: 1, label: "Aqueduct marker", chat_message_id: 9, anchor_message_id: 9 }
        ]
      })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    const firstDialog = await screen.findByRole("dialog", { name: "Bookmarks" })
    fireEvent.click(firstDialog.parentElement!)
    expect(screen.queryByRole("dialog", { name: "Bookmarks" })).not.toBeInTheDocument()

    fireEvent.change(textarea, { target: { value: "/bookmarks" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))
    expect(await screen.findByRole("dialog", { name: "Bookmarks" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close bookmarks" }))

    expect(screen.queryByRole("dialog", { name: "Bookmarks" })).not.toBeInTheDocument()
  })
})

describe("pinned messages bar", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn()
    })
  })

  function mockPinsFetch(pins: Array<Record<string, unknown>>, payload = chatPayload()) {
    return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/pins") {
        return Promise.resolve(jsonResponse({ pins }))
      }

      return Promise.resolve(jsonResponse(payload))
    })
  }

  it("renders up to 3 most-recently-pinned messages newest first, with a hook for the rest", async () => {
    mockPinsFetch([
      { id: 1, chat_message_id: 21, text: "First pinned note.", role: "user" },
      { id: 2, chat_message_id: 22, text: "Second pinned note.", role: "assistant" },
      { id: 3, chat_message_id: 23, text: "Third pinned note.", role: "user" },
      { id: 4, chat_message_id: 24, text: "Fourth pinned note.", role: "assistant" },
      { id: 5, chat_message_id: 25, text: "Fifth pinned note.", role: "user" }
    ])

    renderRoute()

    const bar = await screen.findByTestId("pinned-messages-bar")
    const previews = within(bar).getAllByRole("button", { name: /pinned note\./ })
    expect(previews.map((button) => button.textContent)).toEqual([
      "Fifth pinned note.",
      "Fourth pinned note.",
      "Third pinned note."
    ])
    expect(within(bar).getByRole("button", { name: "+2 more" })).toBeInTheDocument()
  })

  it("renders nothing when the chat has no pinned messages", async () => {
    mockPinsFetch([])
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByTestId("pinned-messages-bar")).not.toBeInTheDocument()
  })

  it("scrolls to and highlights the message when a pinned preview is clicked", async () => {
    const scrollIntoView = vi.fn()
    mockPinsFetch([
      { id: 1, chat_message_id: 9, text: "Discuss aqueducts.", role: "assistant" }
    ])

    renderRoute()

    const preview = await screen.findByRole("button", { name: /Discuss aqueducts\./ })
    Object.defineProperty(document.getElementById("message-9"), "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })
    fireEvent.click(preview)

    await waitFor(() => {
      expect(scrollIntoView).toHaveBeenCalledWith({ block: "start", behavior: "smooth" })
    })
  })

  it("opens the Pinned workspace tab when the 'view all' affordance is clicked", async () => {
    mockPinsFetch([
      { id: 1, chat_message_id: 21, text: "First pinned note.", role: "user", created_at: "2026-08-10T10:00:00Z" },
      { id: 2, chat_message_id: 22, text: "Second pinned note.", role: "assistant", created_at: "2026-08-11T10:00:00Z" },
      { id: 3, chat_message_id: 23, text: "Third pinned note.", role: "user", created_at: "2026-08-12T10:00:00Z" },
      { id: 4, chat_message_id: 24, text: "Fourth pinned note.", role: "assistant", created_at: "2026-08-13T10:00:00Z" },
      { id: 5, chat_message_id: 25, text: "Fifth pinned note.", role: "user", created_at: "2026-08-14T10:00:00Z" }
    ])

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "+2 more" }))

    const workspace = await screen.findByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).getByRole("button", { name: "Pinned" })).toHaveClass("border-blue-600")
    expect(within(workspace).getAllByRole("listitem")).toHaveLength(5)
    expect(within(workspace).getByText("First pinned note.")).toBeInTheDocument()
  })
})

describe("chat pending proposal jump banner", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: vi.fn()
    })
  })

  it("shows the number of pending proposals above compose", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" })),
          messageWithProposal(10, proposal({ id: 2, title: "Draft build plan" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("2 pending proposals")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Jump (1 of 2)" })).toBeInTheDocument()
  })

  it("shows pending proposal count from the chat payload when proposal messages are not loaded", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      if (path === "/api/v1/app/chats/8/messages?before=9") {
        return Promise.resolve(jsonResponse({
          has_more_older: false,
          messages: [
            messageWithProposal(4, proposal({ id: 1, title: "Survey aqueduct route" }))
          ]
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "assistant",
            tool_name: null,
            content: { text: "Latest update." },
            text: "Latest update.",
            bookmarkable: true
          }
        ]
      }, { has_more_older: true, pending_proposal_count: 1 })))
    })

    renderRoute()

    expect(await screen.findByText("1 pending proposal")).toBeInTheDocument()
    const loadEarlier = screen.getByRole("button", { name: "Load earlier messages" })
    fireEvent.click(loadEarlier)

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/messages?before=9", expect.anything())
    })
  })

  it("jumps through pending proposal messages in order", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" })),
          messageWithProposal(10, proposal({ id: 2, title: "Draft build plan" }))
        ]
      })))
    })

    renderRoute()

    const jump = await screen.findByRole("button", { name: "Jump (1 of 2)" })
    const firstScroll = vi.fn()
    const secondScroll = vi.fn()
    Object.defineProperty(document.getElementById("chat_message_9"), "scrollIntoView", {
      configurable: true,
      value: firstScroll
    })
    Object.defineProperty(document.getElementById("chat_message_10"), "scrollIntoView", {
      configurable: true,
      value: secondScroll
    })

    fireEvent.click(jump)

    expect(firstScroll).toHaveBeenCalledWith({ behavior: "smooth", block: "start" })
    expect(secondScroll).not.toHaveBeenCalled()

    fireEvent.click(await screen.findByRole("button", { name: "Jump (2 of 2)" }))

    expect(secondScroll).toHaveBeenCalledWith({ behavior: "smooth", block: "start" })
  })

  it("counts each pending proposal only once when the same proposal id appears in multiple messages", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" })),
          messageWithProposal(10, proposal({ id: 1, title: "Survey aqueduct route" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("1 pending proposal")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Jump ↑" })).toBeInTheDocument()
  })

  it("does not show the banner for resolved proposals", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ proposed: false, resolved: true, state: "confirmed", state_label: "Confirmed" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Discuss proposal 9.")).toBeInTheDocument()
    expect(screen.queryByText("1 pending proposal")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Jump ↑" })).not.toBeInTheDocument()
  })

  it("clears the banner immediately after confirming a proposal, without waiting for a full refetch", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path.startsWith("/api/v1/app/chats/8/proposals/1/confirm") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          message: "Proposal confirmed. JOB-99 was created.",
          proposal: proposal({ proposed: false, resolved: true, state: "confirmed", state_label: "Confirmed" }),
          messages: [],
          pending_proposal_count: 0
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      }, { pending_proposal_count: 1 })))
    })

    renderRoute()

    expect(await screen.findByText("1 pending proposal")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => {
      expect(screen.queryByText("1 pending proposal")).not.toBeInTheDocument()
    })

    const chatPayloadFetches = fetchMock.mock.calls.filter((call) => String(call[0]) === "/api/v1/app/chats/8")
    expect(chatPayloadFetches.length).toBe(1)
  })
})

describe("chat proposal cards", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders the proposal slug as a copyable button", async () => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal({ slug: "JOB-DRAFT-1" }))]
      })))
    })

    renderRoute()

    const copyButton = await screen.findByRole("button", { name: "Copy JOB-DRAFT-1 to clipboard" })
    expect(copyButton).toBeInTheDocument()
    fireEvent.click(copyButton)
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("JOB-DRAFT-1")
  })

  it("shows an edit button only for proposed proposal cards", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({ slug: "JOB-DRAFT-1" })),
          messageWithProposal(10, proposal({ id: 2, slug: "JOB-DRAFT-2", proposed: false, resolved: true, state: "confirmed", state_label: "Confirmed" }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Edit JOB-DRAFT-2" })).not.toBeInTheDocument()
  })

  it("opens the edit modal and saves a title change", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/proposals/1" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(chatPayload({
          messages: [messageWithProposal(9, proposal({ title: "Survey north aqueduct" }))]
        })))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" }))
    const dialog = screen.getByRole("dialog", { name: "Edit proposal" })
    expect(dialog.parentElement?.parentElement).toBe(document.body)
    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Survey north aqueduct" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/proposals/1", expect.objectContaining({ method: "PATCH" }))
    })
    const patchCall = fetchMock.mock.calls.find((call) => String(call[0]) === "/api/v1/app/chats/8/proposals/1" && (call[1] as RequestInit | undefined)?.method === "PATCH")
    expect(JSON.parse(String((patchCall?.[1] as RequestInit).body))).toMatchObject({
      proposal: { title: "Survey north aqueduct" }
    })
    expect(await screen.findByText("Survey north aqueduct")).toBeInTheDocument()
  })

  it("removes the target epic from a job proposal in the edit modal", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/proposals/1" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(chatPayload({
          messages: [messageWithProposal(9, proposal({ target_epic_id: null, target_epic_label: null }))]
        })))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal({ target_epic_id: 42, target_epic_label: "EPIC-42" }))]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" }))
    const dialog = screen.getByRole("dialog", { name: "Edit proposal" })
    expect(within(dialog).getByText("EPIC-42")).toBeInTheDocument()

    fireEvent.click(within(dialog).getByRole("button", { name: "Remove target epic" }))
    expect(within(dialog).queryByText("EPIC-42")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/proposals/1", expect.objectContaining({ method: "PATCH" }))
    })
    const patchCall = fetchMock.mock.calls.find((call) => String(call[0]) === "/api/v1/app/chats/8/proposals/1" && (call[1] as RequestInit | undefined)?.method === "PATCH")
    expect(JSON.parse(String((patchCall?.[1] as RequestInit).body))).toMatchObject({
      proposal: { target_epic_id: null }
    })
  })

  it("closes the edit modal on Escape when the proposal is unchanged", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" }))
    expect(screen.getByRole("dialog", { name: "Edit proposal" })).toBeInTheDocument()

    fireEvent.keyDown(document, { key: "Escape" })

    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Edit proposal" })).not.toBeInTheDocument()
    })
    expect(screen.queryByText("Discard unsaved proposal changes?")).not.toBeInTheDocument()
  })

  it("asks before discarding proposal edits on Escape when fields changed", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" }))
    fireEvent.change(screen.getByLabelText("Title"), { target: { value: "Survey north aqueduct" } })

    fireEvent.keyDown(document, { key: "Escape" })

    expect(await screen.findByText("Discard unsaved proposal changes?")).toBeInTheDocument()
    expect(screen.getByRole("dialog", { name: "Edit proposal" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Keep editing" }))
    await waitFor(() => {
      expect(screen.queryByText("Discard unsaved proposal changes?")).not.toBeInTheDocument()
    })
    expect(screen.getByRole("dialog", { name: "Edit proposal" })).toBeInTheDocument()

    fireEvent.keyDown(document, { key: "Escape" })
    fireEvent.click(await screen.findByRole("button", { name: "Discard changes" }))

    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Edit proposal" })).not.toBeInTheDocument()
    })
  })

  it("searches proposal dependencies and adds a selected result as a pill", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path.startsWith("/api/v1/app/chats/8/proposals/search")) {
        return Promise.resolve(jsonResponse({
          proposals: [
            { id: 2, slug: "api-build", title: "Build API", state: "proposed" }
          ]
        }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Edit JOB-DRAFT-1" }))
    fireEvent.change(screen.getByPlaceholderText("Search proposals"), { target: { value: "api" } })

    await waitFor(() => {
      expect(fetchMock.mock.calls.some((call) => String(call[0]).startsWith("/api/v1/app/chats/8/proposals/search?q=api"))).toBe(true)
    })
    fireEvent.click(await screen.findByRole("button", { name: /api-build/ }))

    expect(screen.getByText("api-build")).toBeInTheDocument()
  })

  it("does not show edit or reject buttons on child proposals of a withdrawn epic bundle", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            proposed: false,
            resolved: true,
            state: "withdrawn",
            state_label: "Withdrawn",
            epic_bundle: true,
            active_children_count: 1,
            children: [
              {
                id: 11,
                title: "Build first step",
                slug: "JOB-DRAFT-1",
                body: "Create the first onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: [],
                app_update_path: "/api/v1/app/chats/8/proposals/11",
                app_reject_path: "/api/v1/app/chats/8/proposals/11/reject"
              }
            ]
          }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Build first step")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Edit JOB-DRAFT-1" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reject child Job" })).not.toBeInTheDocument()
  })

  it("hides dependency slugs on child proposals of a linear epic", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 2,
            children: [
              {
                id: 11,
                title: "Build first step",
                slug: "JOB-DRAFT-1",
                body: "Create the first onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: ["job-build-second-step"],
                app_update_path: "/api/v1/app/chats/8/proposals/11",
                app_reject_path: "/api/v1/app/chats/8/proposals/11/reject"
              },
              {
                id: 12,
                title: "Build second step",
                slug: "JOB-DRAFT-2",
                body: "Create the second onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: [],
                app_update_path: "/api/v1/app/chats/8/proposals/12",
                app_reject_path: "/api/v1/app/chats/8/proposals/12/reject"
              }
            ]
          }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Build first step")).toBeInTheDocument()
    expect(screen.queryByText(/depends on/)).not.toBeInTheDocument()
  })

  it("shortens the visible Epic confirmation label while preserving the full accessible name", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 0,
            children: []
          }))
        ]
      })))
    })

    renderRoute()

    const confirmButton = await screen.findByRole("button", { name: "Confirm Epic" })
    expect(confirmButton).toHaveTextContent("Backlog")
    expect(confirmButton).toHaveAttribute("title", "Confirm Epic")
    expect(screen.queryByText("Confirm Epic")).not.toBeInTheDocument()
  })

  it("shortens the visible Epic and Jobs confirmation label while preserving the full accessible name", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 1,
            children: [
              {
                id: 11,
                title: "Build first step",
                slug: "JOB-DRAFT-1",
                body: "Create the first onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: [],
                app_update_path: "/api/v1/app/chats/8/proposals/11",
                app_reject_path: "/api/v1/app/chats/8/proposals/1/children/11/reject"
              }
            ]
          }))
        ]
      })))
    })

    renderRoute()

    const confirmButton = await screen.findByRole("button", { name: "Confirm Epic and Jobs" })
    expect(confirmButton).toHaveTextContent("Backlog")
    expect(confirmButton).toHaveAttribute("title", "Confirm Epic and Jobs")
    expect(screen.queryByText("Confirm Epic and Jobs")).not.toBeInTheDocument()
  })

  it("offers Create Epic & Start Implementing on Epic proposals to developers and sends the start flag", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: developerUser() }))
      }
      if (path.startsWith("/api/v1/app/chats/8/proposals/1/confirm") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(chatPayload({ messages: [] })))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 0,
            children: []
          }))
        ]
      })))
    })

    renderRoute()

    const startButton = await screen.findByRole("button", { name: "Create Epic & Start Implementing" })
    expect(startButton).toHaveTextContent("Implement")
    expect(startButton).toHaveAttribute("title", "Create Epic & Start Implementing")

    fireEvent.click(startButton)

    await waitFor(() => {
      const confirmCall = fetchMock.mock.calls.find((call) => String(call[0]).startsWith("/api/v1/app/chats/8/proposals/1/confirm"))
      expect(confirmCall).toBeTruthy()
      expect(JSON.parse(confirmCall?.[1]?.body as string)).toEqual({ start: true })
    })
  })

  it("hides Create Epic & Start Implementing from non-developers on Epic proposals", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: { ...developerUser(), role: "product_owner" } }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 0,
            children: []
          }))
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Confirm Epic" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Create Epic & Start Implementing" })).not.toBeInTheDocument()
  })

  it("keeps Epic proposal action labels on one row at mobile width", async () => {
    mockMobileViewport()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: developerUser() }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          messageWithProposal(9, proposal({
            kind: "epic",
            kind_label: "Epic",
            title: "Plan onboarding",
            slug: "EPIC-DRAFT-1",
            epic_bundle: true,
            active_children_count: 1,
            children: [
              {
                id: 11,
                title: "Build first step",
                slug: "JOB-DRAFT-1",
                body: "Create the first onboarding step.",
                state: "proposed",
                state_label: "Pending",
                proposed: true,
                repository_slug: "acme/widgets",
                dependencies: [],
                app_update_path: "/api/v1/app/chats/8/proposals/11",
                app_reject_path: "/api/v1/app/chats/8/proposals/1/children/11/reject"
              }
            ]
          }))
        ]
      })))
    })

    renderRoute()

    await screen.findByRole("button", { name: "Confirm Epic and Jobs" })
    const footer = screen.getByTestId("proposal-action-footer")
    await within(footer).findByText("Implement")
    expect(footer).toHaveClass("flex-nowrap", "overflow-hidden")
    expect(footer).not.toHaveClass("flex-wrap")
    expect(within(footer).getByText("Backlog")).toBeInTheDocument()
    expect(within(footer).getByText("Implement")).toBeInTheDocument()
    expect(within(footer).getByText("Reject")).toBeInTheDocument()
    for (const button of within(footer).getAllByRole("button")) {
      expect(button).toHaveClass("min-w-0", "flex-1", "whitespace-nowrap")
    }
  })

  it("does not offer Create Epic & Start Implementing on non-Epic proposals", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [messageWithProposal(9, proposal())]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Confirm" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Create Epic & Start Implementing" })).not.toBeInTheDocument()
  })
})

describe("chat compose image attachments", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows an edit glyph on the annotate thumbnail affordance", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [new File(["pixels"], "screen.png", { type: "image/png" })] } })

    const annotateButton = await screen.findByRole("button", { name: "Annotate screen.png" })
    expect(annotateButton.querySelector("svg")).toBeInTheDocument()
    expect(annotateButton.querySelector("span")).toHaveClass("group-hover:opacity-100", "group-focus-visible:opacity-100")
    expect(screen.getByRole("button", { name: "Remove screen.png" }).querySelector("svg")).toBeInTheDocument()
  })

  it("removes the textarea required constraint when an attachment is present without text", async () => {
    mockChatRouteFetch()
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    expect(textarea).toBeRequired()

    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["pixels"], "attach.png", { type: "image/png" })] }
    })

    await screen.findByRole("button", { name: "Remove attach.png" })
    expect(textarea).not.toBeRequired()
  })
})

describe("chat compose attachment persistence across remounts", () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it("keeps an in-progress attachment after navigating away from the chat and back", async () => {
    mockDesktopViewport()
    mockChatRouteFetch()
    renderRouteWithAwayLink()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["pixels"], "kept.png", { type: "image/png" })] }
    })
    await screen.findByRole("button", { name: "Remove kept.png" })

    fireEvent.click(screen.getByText("Go away"))
    await screen.findByText("Away page")

    fireEvent.click(screen.getByText("Go back"))
    await screen.findByPlaceholderText("Ask about this repository...")

    expect(await screen.findByRole("button", { name: "Remove kept.png" })).toBeInTheDocument()
  })

  it("keeps an in-progress attachment when crossing the mobile/desktop breakpoint mid-session", async () => {
    mockChatRouteFetch()
    const viewport = mockDynamicViewport(true)
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), {
      target: { files: [new File(["pixels"], "kept.png", { type: "image/png" })] }
    })
    await screen.findByRole("button", { name: "Remove kept.png" })

    // ChatWorkspace renders an entirely different JSX branch per isDesktop,
    // so flipping it remounts the ChatColumn/Compose subtree — the exact
    // mechanism the bug report described for the breakpoint-crossing trigger.
    act(() => {
      viewport.setDesktop(false)
    })
    await screen.findByPlaceholderText("Ask about this repository...")

    expect(await screen.findByRole("button", { name: "Remove kept.png" })).toBeInTheDocument()
  })
})

describe("chat composer paste-to-attach", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("attaches a pasted image through the same funnel as the picker", async () => {
    mockChatRouteFetch()
    renderRoute()
    const textarea = await screen.findByPlaceholderText("Ask about this repository...")

    const file = new File(["pixels"], "pasted.png", { type: "image/png" })
    fireEvent.paste(textarea, {
      clipboardData: { files: [file], items: [{ kind: "file", type: "image/png", getAsFile: () => file }], getData: () => "" }
    })

    expect(await screen.findByRole("button", { name: "Remove pasted.png" })).toBeInTheDocument()
  })

  it("falls back to clipboard items when files is empty (Safari)", async () => {
    mockChatRouteFetch()
    renderRoute()
    const textarea = await screen.findByPlaceholderText("Ask about this repository...")

    const file = new File(["pixels"], "safari.png", { type: "image/png" })
    fireEvent.paste(textarea, {
      clipboardData: { files: [], items: [{ kind: "file", type: "image/png", getAsFile: () => file }], getData: () => "" }
    })

    expect(await screen.findByRole("button", { name: "Remove safari.png" })).toBeInTheDocument()
  })

  it("leaves plain-text pastes to the browser default", async () => {
    mockChatRouteFetch()
    renderRoute()
    const textarea = await screen.findByPlaceholderText("Ask about this repository...")

    fireEvent.paste(textarea, {
      clipboardData: { files: [], items: [{ kind: "string", type: "text/plain", getAsFile: () => null }], getData: () => "hello" }
    })

    await waitFor(() => {
      expect(screen.queryByRole("button", { name: /^Remove / })).not.toBeInTheDocument()
    })
  })
})

describe("chat message entrance", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("animates only messages that arrive after the initial load", () => {
    expect(shouldAnimateMessageEntrance(10, 5)).toBe(true)
    // History and older pages stay at rest; null ids gate hard.
    expect(shouldAnimateMessageEntrance(5, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(3, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(null, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(10, null)).toBe(false)
  })

  it("renders initially loaded messages at rest", async () => {
    mockChatRouteFetch()

    renderRoute()
    await screen.findByText("Discuss aqueducts.")

    const article = document.getElementById("chat_message_9")
    expect(article).not.toBeNull()
    expect(article!.className).not.toContain("animate-chat-message-in")
  })

  it("never pins a lingering transform after the entrance animation finishes", () => {
    // A "forwards"/"both" fill-mode keeps the animation's final `transform`
    // applied to the message <article> forever. Even a no-op translateY(0)
    // creates a CSS containing block for any `position: fixed` descendant
    // (e.g. the image lightbox modal in MessageCards.tsx), trapping it
    // inside the message bubble instead of covering the viewport.
    const match = tailwindConfigSource.match(/"chat-message-in":\s*"chat-message-in [^"]*"/)
    expect(match).not.toBeNull()
    expect(match![0]).not.toMatch(/\b(both|forwards)\b/)
  })
})

describe("chat message image attachments", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders image thumbnails and opens a dismissible lightbox", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "user",
            tool_name: null,
            content: { text: "Inspect this." },
            text: "Inspect this.",
            bookmarkable: true,
            attachments: [
              { name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" },
              { name: "notes.pdf", mime_type: "application/pdf", data: "cGRm" }
            ]
          }
        ]
      })))
    })

    renderRoute()

    const thumbnail = await screen.findByRole("button", { name: "Open diagram.png" })
    expect(screen.getByAltText("diagram.png")).toHaveAttribute("src", "data:image/png;base64,cGl4ZWxz")
    // Non-image attachments (a PDF) render as a labeled chip, not a thumbnail, so
    // they never leave a blank bubble and are always visible in the transcript.
    expect(screen.getByText("notes.pdf")).toBeInTheDocument()

    fireEvent.click(thumbnail)

    expect(screen.getByRole("dialog", { name: "diagram.png" })).toBeInTheDocument()

    fireEvent.keyDown(window, { key: "Escape" })

    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "diagram.png" })).not.toBeInTheDocument()
    })
  })

  it("shows all shared images in the media tab with downloads and lightbox preview", async () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "user",
            tool_name: null,
            content: { text: "First image." },
            text: "First image.",
            bookmarkable: true,
            attachments: [
              { name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" },
              { name: "notes.pdf", mime_type: "application/pdf", data: "cGRm" }
            ]
          },
          {
            type: "message",
            id: 10,
            role: "assistant",
            tool_name: null,
            content: { text: "Second image." },
            text: "Second image.",
            bookmarkable: true,
            attachments: [
              { name: "mockup.jpg", mime_type: "image/jpeg", data: "anBlZw==" }
            ]
          }
        ]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Media" }))

    const workspace = screen.getByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).getByText("diagram.png")).toBeInTheDocument()
    expect(within(workspace).getByText("mockup.jpg")).toBeInTheDocument()
    expect(within(workspace).queryByText("notes.pdf")).not.toBeInTheDocument()

    const download = within(workspace).getByRole("link", { name: "Download diagram.png" })
    expect(download).toHaveAttribute("href", "data:image/png;base64,cGl4ZWxz")
    expect(download).toHaveAttribute("download", "diagram.png")

    fireEvent.click(within(workspace).getByRole("button", { name: "Open mockup.jpg" }))

    expect(screen.getByRole("dialog", { name: "mockup.jpg" })).toBeInTheDocument()
  })

  it("hides the media tab and falls back to another tab when no media has been shared", async () => {
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "media")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const workspace = await screen.findByRole("complementary", { name: "Chat workspace" })
    expect(within(workspace).queryByRole("button", { name: "Media" })).not.toBeInTheDocument()
    expect(screen.queryByText("No media shared yet.")).not.toBeInTheDocument()
  })

  it("includes media in the mobile chat tab list once there is something to show", async () => {
    mockMobileViewport()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "user",
            tool_name: null,
            content: { text: "Screenshot." },
            text: "Screenshot.",
            bookmarkable: true,
            attachments: [{ name: "diagram.png", mime_type: "image/png", data: "cGl4ZWxz" }]
          }
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByRole("button", { name: "Media" })).toBeInTheDocument()
  })
})

describe("chat jobs tab", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    mockDesktopViewport()
  })

  it("does not show the Jobs tab when there are no confirmed proposals", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { confirmed_proposal_count: 0 } })))
    })

    renderRoute()

    await screen.findByText("Discuss aqueducts.")
    expect(screen.queryByRole("button", { name: "Jobs" })).not.toBeInTheDocument()
  })

  it("shows the Jobs tab when there is at least one confirmed proposal", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/job_status") {
        return Promise.resolve(jsonResponse([]))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { confirmed_proposal_count: 1 } })))
    })

    renderRoute()

    await screen.findByText("Discuss aqueducts.")
    expect(screen.getByRole("button", { name: "Jobs" })).toBeInTheDocument()
  })

  it("shows the Jobs tab when there is at least one linked direct job", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/job_status") {
        return Promise.resolve(jsonResponse([]))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { confirmed_proposal_count: 0, linked_direct_job_count: 1 } })))
    })

    renderRoute()

    await screen.findByText("Discuss aqueducts.")
    expect(screen.getByRole("button", { name: "Jobs" })).toBeInTheDocument()
  })

  it("shows the job status panel content when the Jobs tab is active", async () => {
    window.localStorage.setItem("syrus.chat.workspace.tab", "jobs")
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/job_status") {
        return Promise.resolve(jsonResponse([]))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { confirmed_proposal_count: 2 } })))
    })

    renderRoute()

    expect(await screen.findByText("No confirmed proposals yet.")).toBeInTheDocument()
  })
})

describe("chat pinned tab", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    mockDesktopViewport()
  })

  function mockPinsFetch(pins: Array<Record<string, unknown>>, payload = chatPayload()) {
    return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/pins") {
        return Promise.resolve(jsonResponse({ pins }))
      }

      return Promise.resolve(jsonResponse(payload))
    })
  }

  it("does not show the Pinned tab when there are no pinned messages", async () => {
    mockPinsFetch([])

    renderRoute()

    await screen.findByText("Discuss aqueducts.")
    await waitFor(() => {
      expect(screen.queryByRole("button", { name: "Pinned" })).not.toBeInTheDocument()
    })
  })

  it("shows the Pinned tab when there is at least one pinned message", async () => {
    mockPinsFetch([{ id: 1, chat_message_id: 9, text: "Discuss aqueducts.", role: "assistant" }])

    renderRoute()

    expect(await screen.findByRole("button", { name: "Pinned" })).toBeInTheDocument()
  })
})

describe("chat attachment detach confirmation", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    window.localStorage.setItem("syrus.chat.workspace.tab", "context")
    mockDesktopViewport()
  })

  it("does not detach an attachment on the first click", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))

    expect(screen.getByRole("button", { name: "Detach Runbook.md?" })).toBeInTheDocument()
    expect(detachRequests(fetchMock)).toHaveLength(0)
  })

  it("detaches an attachment on the second click of the same button", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))
    fireEvent.click(screen.getByRole("button", { name: "Detach Runbook.md?" }))

    await waitFor(() => {
      expect(detachRequests(fetchMock)).toHaveLength(1)
    })
  })

  it("cancels a pending detach without calling the API", async () => {
    const fetchMock = mockChatAttachmentFetch()

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Runbook.md" }))
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(screen.getByRole("button", { name: "Runbook.md" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Detach Runbook.md?" })).not.toBeInTheDocument()
    expect(detachRequests(fetchMock)).toHaveLength(0)
  })
})

describe("repositoryless chat compose", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("invites open-ended chat and allows submit without an attached repository", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({ chat: { repository: null }, messages: [] })))
    })

    renderRoute()

    expect(await screen.findByText("Ask anything, or attach a repository for code context.")).toBeInTheDocument()
    const textarea = await screen.findByPlaceholderText("Ask anything — or attach a repository to give the agent context...")
    fireEvent.change(textarea, { target: { value: "Can you help me plan a release?" } })

    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled()
  })

  it("uses Supervisor operations wording without the repository attachment hint", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        chat: { repository: null, system_kind: "supervisor", title: "Supervisor" },
        messages: []
      })))
    })

    renderRoute()

    expect(await screen.findByText("Ask about incidents, stuck Jobs, Workflows, Runs, queues, PRs, or operational state.")).toBeInTheDocument()
    expect(screen.queryByText("Ask anything, or attach a repository for code context.")).not.toBeInTheDocument()
    expect(await screen.findByPlaceholderText("Ask about incidents, stuck Jobs, Workflows, Runs, queues, PRs, or operational state...")).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("Ask anything — or attach a repository to give the agent context...")).not.toBeInTheDocument()
  })
})

describe("chat settings gear button", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders a gear button with aria-label 'Chat settings' in the header", async () => {
    mockChatRouteFetch()
    renderRoute()

    expect(await screen.findByRole("button", { name: "Chat settings" })).toBeInTheDocument()
  })

  it("opens the settings dialog when the gear button is clicked", async () => {
    mockChatRouteFetch()
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Chat settings" }))

    expect(await screen.findByRole("dialog", { name: "Chat settings" })).toBeInTheDocument()
  })

  it("does not render the gear button on mobile where the header is hidden", async () => {
    mockMobileViewport()
    mockChatRouteFetch()
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Chat settings" })).not.toBeInTheDocument()
  })

  it("opens the settings dialog from the /settings slash command", async () => {
    mockChatRouteFetch()
    renderRoute()

    await submitSlashCommand("/settings")

    expect(await screen.findByRole("dialog", { name: "Chat settings" })).toBeInTheDocument()
  })
})

describe("chat slash commands", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("copies the last assistant response to the clipboard", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "assistant",
            tool_name: null,
            content: { text: "First assistant response." },
            text: "First assistant response.",
            bookmarkable: true
          },
          {
            type: "message",
            id: 10,
            role: "user",
            tool_name: null,
            content: { text: "Thanks." },
            text: "Thanks.",
            bookmarkable: true
          },
          {
            type: "message",
            id: 11,
            role: "assistant",
            tool_name: null,
            content: { text: "Latest assistant response." },
            text: "Latest assistant response.",
            bookmarkable: true
          }
        ]
      })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "/copy" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    expect(writeText).toHaveBeenCalledWith("Latest assistant response.")
    expect(await screen.findByText("Copied to clipboard")).toBeInTheDocument()
  })

  it("does not render assistant messages with empty text (thinking-only turns)", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload({
        messages: [
          {
            type: "message",
            id: 9,
            role: "assistant",
            tool_name: null,
            content: { text: "" },
            text: "",
            bookmarkable: true
          },
          {
            type: "message",
            id: 10,
            role: "assistant",
            tool_name: null,
            content: { text: "Here is the answer." },
            text: "Here is the answer.",
            bookmarkable: true
          }
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Here is the answer.")).toBeInTheDocument()
    expect(document.getElementById("chat_message_9")).not.toBeInTheDocument()
    expect(document.getElementById("chat_message_10")).toBeInTheDocument()
  })
})

describe("composer next-step suggestion", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  function findComposerTextarea() {
    return screen.findByRole("textbox")
  }

  it("renders the suggestion as ghost text with a tab hint when the composer is empty", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    const ghost = await screen.findByTestId("chat-suggestion-ghost")
    expect(ghost).toHaveTextContent("Create an Epic from these findings")
    expect(ghost).toHaveTextContent("tab")
    expect(screen.getByText("Suggested next message: Create an Epic from these findings. Press Tab to accept.")).toBeInTheDocument()
  })

  it("does not render ghost text when no suggestion is stored", async () => {
    mockChatRouteFetch(chatPayload())

    renderRoute()

    expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
    expect(screen.queryByTestId("chat-suggestion-ghost")).not.toBeInTheDocument()
  })

  it("fills the composer with the suggestion on Tab after the grace period", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    await screen.findByTestId("chat-suggestion-ghost")
    const textarea = await findComposerTextarea()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 300)
    fireEvent.keyDown(textarea, { key: "Tab" })
    nowSpy.mockRestore()

    expect(textarea).toHaveValue("Create an Epic from these findings")
    expect(screen.queryByTestId("chat-suggestion-ghost")).not.toBeInTheDocument()
  })

  it("does not hijack Tab while the suggestion is inside the arrival grace period", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))
    // Freeze the clock across render AND keydown so the Tab lands
    // "immediately" after the suggestion's arrival timestamp — inside
    // the grace period — regardless of real render latency.
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(1_700_000_000_000)

    try {
      renderRoute()

      await screen.findByTestId("chat-suggestion-ghost")
      const textarea = await findComposerTextarea()
      const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab" })

      expect(defaultNotPrevented).toBe(true)
      expect(textarea).toHaveValue("")
      expect(screen.getByTestId("chat-suggestion-ghost")).toBeInTheDocument()
    } finally {
      nowSpy.mockRestore()
    }
  })

  it("leaves Shift+Tab focus navigation alone even when the ghost renders", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    await screen.findByTestId("chat-suggestion-ghost")
    const textarea = await findComposerTextarea()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 300)
    const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab", shiftKey: true })
    nowSpy.mockRestore()

    expect(defaultNotPrevented).toBe(true)
    expect(textarea).toHaveValue("")
    expect(screen.getByTestId("chat-suggestion-ghost")).toBeInTheDocument()
  })

  it("leaves modifier-chord Tab presses alone even when the ghost renders", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    await screen.findByTestId("chat-suggestion-ghost")
    const textarea = await findComposerTextarea()
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 300)
    const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab", ctrlKey: true })
    nowSpy.mockRestore()

    expect(defaultNotPrevented).toBe(true)
    expect(textarea).toHaveValue("")
    expect(screen.getByTestId("chat-suggestion-ghost")).toBeInTheDocument()
  })

  it("dismisses the suggestion for the session on Escape", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    await screen.findByTestId("chat-suggestion-ghost")
    const textarea = await findComposerTextarea()
    fireEvent.keyDown(textarea, { key: "Escape" })

    expect(screen.queryByTestId("chat-suggestion-ghost")).not.toBeInTheDocument()
    expect(textarea).toHaveValue("")
  })

  it("hides the ghost while the operator is typing", async () => {
    mockChatRouteFetch(chatPayload({ chat: { suggested_next_step: "Create an Epic from these findings" } }))

    renderRoute()

    await screen.findByTestId("chat-suggestion-ghost")
    const textarea = await findComposerTextarea()
    fireEvent.change(textarea, { target: { value: "My own idea" } })

    expect(screen.queryByTestId("chat-suggestion-ghost")).not.toBeInTheDocument()

    fireEvent.change(textarea, { target: { value: "" } })

    expect(await screen.findByTestId("chat-suggestion-ghost")).toBeInTheDocument()
  })
})

describe("scratchpad stash button", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows the stash button when the agent is idle and textarea has text", async () => {
    mockChatRouteFetch(chatPayload({ chat: { agent_busy: false } }))
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "Draft idea" } })

    expect(screen.getByRole("button", { name: "Stash" })).toBeInTheDocument()
  })

  it("does not show the stash button when the textarea is empty and agent is active", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Queue a follow-up message...")
    expect(screen.queryByRole("button", { name: "Stash" })).not.toBeInTheDocument()
  })

  it("shows the stash button when agent is active and textarea has text", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Queue a follow-up message...")
    fireEvent.change(textarea, { target: { value: "Draft idea" } })

    expect(screen.getByRole("button", { name: "Stash" })).toBeInTheDocument()
  })

  it("calls POST scratchpad_items and clears the textarea on stash", async () => {
    const updatedPayload = {
      ...chatPayload({
        scratchpad_items: [{ id: 1, content: "Draft idea", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }]
      }),
      agent_busy: true
    }

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Queue a follow-up message...")
    fireEvent.change(textarea, { target: { value: "Draft idea" } })
    fireEvent.click(screen.getByRole("button", { name: "Stash" }))

    await waitFor(() => {
      expect(textarea).toHaveValue("")
    })

    const stashCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )
    expect(stashCalls).toHaveLength(1)
    expect(JSON.parse((stashCalls[0][1] as RequestInit).body as string)).toEqual({ scratchpad_item: { content: "Draft idea" } })
  })

  it("shows 'Stash (Tab)' in the stash button tooltip", async () => {
    mockChatRouteFetch(chatPayload({ chat: { agent_busy: false } }))
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "some text" } })

    expect(screen.getByRole("button", { name: "Stash" })).toHaveAttribute("title", "Stash (Tab)")
  })

  it("stashes on Tab when the textarea has text", async () => {
    const updatedPayload = chatPayload({
      scratchpad_items: [{ id: 1, content: "Draft idea", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }]
    })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "Draft idea" } })
    const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab" })

    expect(defaultNotPrevented).toBe(false)

    await waitFor(() => {
      expect(textarea).toHaveValue("")
    })

    const stashCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )
    expect(stashCalls).toHaveLength(1)
    expect(JSON.parse((stashCalls[0][1] as RequestInit).body as string)).toEqual({ scratchpad_item: { content: "Draft idea" } })
  })

  it("does not stash on Tab when the textarea is empty", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab" })

    expect(defaultNotPrevented).toBe(true)
    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )).toBe(false)
  })

  it("does not stash on Shift+Tab when textarea has text", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse(chatPayload()))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "Draft idea" } })
    const defaultNotPrevented = fireEvent.keyDown(textarea, { key: "Tab", shiftKey: true })

    expect(defaultNotPrevented).toBe(true)
    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )).toBe(false)
  })
})

describe("composer stop button", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows the stop button in the control row when agent is active", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Queue a follow-up message...")
    expect(screen.getByRole("button", { name: "Stop agent" })).toBeInTheDocument()
  })

  it("does not show the stop button when agent is idle", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Stop agent" })).not.toBeInTheDocument()
  })

  it("does not show the stop button when switching provider", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true, switching_provider: true }))
    })
    renderRoute()

    await screen.findByRole("textbox")
    expect(screen.queryByRole("button", { name: "Stop agent" })).not.toBeInTheDocument()
  })
})

describe("floating composer control order", () => {
  function fullControlsPayload(chatOverrides: Record<string, unknown> = {}, rootOverrides: Record<string, unknown> = {}) {
    const base = chatPayload(
      {
        chat: {
          available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }],
          effective_chat_provider: "claude",
          ...chatOverrides
        }
      },
      { coding_mode_enabled: true, speech_to_text: speechCapability({ streaming: true }), ...rootOverrides }
    )
    return { ...base, paths: { ...base.paths, ...speechPaths() } }
  }

  function expectDocumentOrder(...elements: HTMLElement[]) {
    for (let index = 0; index < elements.length - 1; index += 1) {
      const [a, b] = [elements[index], elements[index + 1]]
      expect(Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    }
  }

  beforeEach(() => {
    window.localStorage.clear()
  })

  it("renders controls in the canonical order on a desktop viewport", async () => {
    mockDesktopViewport()
    mockChatRouteFetch(fullControlsPayload())
    renderRoute()

    const attachment = await screen.findByRole("button", { name: "Add attachment" })
    const dictation = screen.getByRole("button", { name: "Start dictation" })
    const mode = screen.getByRole("button", { name: "Change mode" })
    const model = screen.getByRole("button", { name: "Chat model" })
    const effort = screen.getByRole("button", { name: "Effort" })
    const send = screen.getByRole("button", { name: "Send message" })

    expectDocumentOrder(attachment, dictation, mode, model, effort, send)
  })

  it("renders controls in the canonical order on a mobile viewport", async () => {
    mockMobileViewport()
    mockChatRouteFetch(fullControlsPayload())
    renderRoute()

    const attachment = await screen.findByRole("button", { name: "Add attachment" })
    const dictation = screen.getByRole("button", { name: "Start dictation" })
    const mode = screen.getByRole("button", { name: "Change mode" })
    const model = screen.getByRole("button", { name: "Chat model" })
    const effort = screen.getByRole("button", { name: "Effort" })
    const send = screen.getByRole("button", { name: "Send message" })

    expectDocumentOrder(attachment, dictation, mode, model, effort, send)
  })

  it("hides (not merely disables) the mode, model, and effort selectors while a turn is in flight", async () => {
    mockDesktopViewport()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...fullControlsPayload(), agent_busy: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Queue a follow-up message...")

    expect(screen.queryByRole("button", { name: "Change mode" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Chat model" })).not.toBeInTheDocument()
    // Regression guard: ChatEffortSelector previously had no agentActive gate at
    // all and stayed fully interactive mid-turn.
    expect(screen.queryByRole("button", { name: "Effort" })).not.toBeInTheDocument()

    expect(screen.getByRole("button", { name: "Enqueue message" })).toBeInTheDocument()
  })

  it("shows the mode, model, and effort selectors again once the agent goes idle", async () => {
    mockDesktopViewport()
    mockChatRouteFetch(fullControlsPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")

    expect(screen.getByRole("button", { name: "Change mode" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Chat model" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Effort" })).toBeInTheDocument()
  })

  // jsdom never loads compiled CSS, so a Tailwind `hidden sm:block` wrapper
  // can't be asserted via toBeInTheDocument()/toBeVisible() the way a
  // conditional-render gate (like the agentActive check above) can — assert
  // the responsive classes are present instead, mirroring how the
  // "floating composer positioning" suite already asserts `className`
  // content for CSS-driven behavior jsdom can't compute.
  it("only ever renders the effort selector at sm: and above, independent of agent state", async () => {
    mockDesktopViewport()
    mockChatRouteFetch(fullControlsPayload())
    renderRoute()

    const effort = await screen.findByRole("button", { name: "Effort" })
    const wrapper = effort.parentElement as HTMLElement
    expect(wrapper.className).toContain("hidden")
    expect(wrapper.className).toContain("sm:block")
  })
})

describe("floating composer positioning", () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
    mockDesktopViewport()
  })

  it("floats over the message list without sharing a containing block with the workspace panel", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    const messageStream = await screen.findByTestId("chat-message-stream")
    const panel = await screen.findByRole("complementary", { name: "Chat workspace" })
    const composeForm = document.querySelector('[data-tour="chat-compose"]') as HTMLElement | null
    expect(composeForm).not.toBeNull()
    const form = composeForm as HTMLElement

    expect(form.className).toContain("absolute")

    let ancestor = form.parentElement
    while (ancestor && !ancestor.contains(messageStream)) {
      ancestor = ancestor.parentElement
    }

    expect(ancestor).not.toBeNull()
    const columnAncestor = ancestor as HTMLElement
    expect(columnAncestor.className).toContain("relative")
    expect(columnAncestor.contains(panel)).toBe(false)
  })

  it("pins both horizontal edges to the chat column ancestor so no max-width value can push it past the workspace panel", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    const messageStream = await screen.findByTestId("chat-message-stream")
    const composeForm = document.querySelector('[data-tour="chat-compose"]') as HTMLElement

    // jsdom never runs layout, so a fabricated getBoundingClientRect can't
    // give this any real signal — it would just assert numbers this same
    // test chose. What jsdom CAN verify is the actual mechanism the "no
    // overlap" guarantee depends on: with both edges pinned to the
    // `position: relative` ancestor via `left`/`right` (mobile) and
    // `sm:inset-x-0` (desktop), CSS guarantees the rendered box can never
    // exceed that ancestor's own padding box — `max-w-*` can only ever
    // shrink it from there, never grow past it. A regression here (losing
    // `sm:inset-x-0`, switching `absolute` to `fixed`, or reintroducing an
    // unbounded width) is exactly the kind of change that would let the
    // pill escape its ancestor and overlap the panel again.
    let ancestor = composeForm.parentElement
    while (ancestor && !ancestor.contains(messageStream)) {
      ancestor = ancestor.parentElement
    }
    expect(ancestor).not.toBeNull()

    expect(composeForm.className).toContain("absolute")
    expect(composeForm.className).not.toMatch(/(?:^|\s)fixed(?:\s|$)/)
    expect(composeForm.className).toContain("left-[max(0.5rem,env(safe-area-inset-left))]")
    expect(composeForm.className).toContain("right-[max(0.5rem,env(safe-area-inset-right))]")
    expect(composeForm.className).toContain("sm:inset-x-0")
    expect(composeForm.className).not.toMatch(/(?:^|\s)w-screen(?:\s|$)/)
    expect(composeForm.className).not.toMatch(/(?:^|\s)w-full(?:\s|$)/)
  })

  // Regression coverage for the banner-painted-under-the-pill bug: the
  // banner used to be a plain in-flow sibling of the (absolutely
  // positioned) composer, so the composer's own box didn't push it up and
  // the composer painted over it instead. It now lives inside the same
  // positioned box as the composer (`[data-tour="chat-compose"]`) and uses
  // `bottom-full`, so it always sits exactly at the composer's current top
  // edge, however tall the composer grows.
  it("positions the pending-proposal banner with bottom-full inside the composer's own positioned box", async () => {
    mockChatRouteFetch(chatPayload({
      messages: [messageWithProposal(9, proposal({ id: 1, title: "Survey aqueduct route" }))]
    }))
    renderRoute()

    const bannerText = await screen.findByText("1 pending proposal")
    const banner = bannerText.closest("div") as HTMLElement
    expect(banner.className).toContain("absolute")
    expect(banner.className).toContain("bottom-full")

    const composerBox = document.querySelector('[data-tour="chat-compose"]') as HTMLElement
    expect(composerBox).not.toBeNull()
    expect(composerBox.contains(banner)).toBe(true)
    expect(composerBox.className).toContain("absolute")
  })
})

// jsdom has no ResizeObserver (Compose already no-ops when it's undefined,
// same guard pattern as Terminal.tsx), so these tests install a synchronous
// stub to exercise the propagation path: Compose measures its floating
// form -> reports the height up to ChatColumn -> ChatColumn exposes it as
// `--chat-composer-height` on the chat column section, which the message
// stream's padding, the "new messages" pill, and the pending-proposal
// banner all read from.
describe("floating composer height tracking", () => {
  let observedElements: HTMLElement[]

  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
    observedElements = []

    class StubResizeObserver {
      private callback: () => void

      constructor(callback: () => void) {
        this.callback = callback
      }

      observe(element: HTMLElement) {
        observedElements.push(element)
        // A real ResizeObserver reports asynchronously (never inside the
        // same effect flush that called observe()) — mirror that here so
        // this doesn't race ChatColumn's own synchronous mount-time reset
        // effect the way a same-tick callback would.
        void Promise.resolve().then(() => this.callback())
      }

      unobserve() {}
      disconnect() {}
    }

    vi.stubGlobal("ResizeObserver", StubResizeObserver)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("exposes the composer's measured height as --chat-composer-height on the chat column", async () => {
    // The stub's observe() invokes its callback synchronously (mirroring a
    // real ResizeObserver's initial report), so the mocked height needs to
    // be in place before the composer's mount-time effect calls observe().
    vi.spyOn(HTMLFormElement.prototype, "getBoundingClientRect").mockReturnValue({
      height: 240, width: 600, top: 0, left: 0, right: 600, bottom: 240, x: 0, y: 0, toJSON: () => ({})
    } as DOMRect)

    mockChatRouteFetch(chatPayload())
    renderRoute()

    const messageStream = await screen.findByTestId("chat-message-stream")
    const form = document.querySelector('[data-tour="chat-compose"] form') as HTMLFormElement
    expect(form).not.toBeNull()
    expect(observedElements).toContain(form)

    let ancestor: HTMLElement | null = form.parentElement
    while (ancestor && !ancestor.contains(messageStream)) {
      ancestor = ancestor.parentElement
    }
    expect(ancestor).not.toBeNull()
    const columnAncestor = ancestor as HTMLElement

    await waitFor(() => {
      expect(columnAncestor.style.getPropertyValue("--chat-composer-height")).toBe("240px")
    })
  })

  it("wires the message stream padding and the new-messages pill to track --chat-composer-height without regressing their static fallback", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    const messageStream = await screen.findByTestId("chat-message-stream")
    expect(messageStream.className).toContain("pb-[max(7rem,calc(var(--chat-composer-height,0px)+1.5rem))]")
    expect(messageStream.className).toContain("sm:pb-[max(8rem,calc(var(--chat-composer-height,0px)+2rem))]")
  })
})

describe("composer textarea right padding", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  // The send/stash/stop cluster moved out of the textarea's corner and into the
  // bottom control row (canonical control order), so the textarea no longer
  // reserves growing right padding for an embedded button group.
  it("keeps a fixed right padding regardless of agent state or typed text", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Queue a follow-up message...")
    expect(textarea).toHaveClass("pr-3")
    fireEvent.change(textarea, { target: { value: "some text" } })
    expect(textarea).toHaveClass("pr-3")
  })
})

describe("scratchpad panel", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("does not render the scratchpad panel when there are no items", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByText("Scratch pad")).not.toBeInTheDocument()
  })

  it("renders the scratchpad panel with items when scratchpad_items is non-empty", async () => {
    mockChatRouteFetch(chatPayload({
      scratchpad_items: [
        { id: 1, content: "Review the aqueduct spec", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
      ]
    }))
    renderRoute()

    expect(await screen.findByText("Review the aqueduct spec")).toBeInTheDocument()
    expect(screen.getByText("Scratch pad")).toBeInTheDocument()
  })

  it("loads item content into the empty textarea and deletes the item on click", async () => {
    const afterDeletePayload = chatPayload({ scratchpad_items: [] })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items/1" && (init as RequestInit)?.method === "DELETE") {
        return Promise.resolve(jsonResponse(afterDeletePayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 1, content: "Check the aqueduct route", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      })))
    })

    renderRoute()

    await screen.findByText("Check the aqueduct route")
    fireEvent.click(screen.getByText("Check the aqueduct route"))

    const textarea = screen.getByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
    await waitFor(() => {
      expect(textarea).toHaveValue("Check the aqueduct route")
    })

    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items/1" && (call[1] as RequestInit)?.method === "DELETE"
    )).toBe(true)
  })

  it("auto-stashes existing text and loads item when textarea has content on load", async () => {
    const afterStashPayload = chatPayload({
      scratchpad_items: [
        { id: 1, content: "Check the aqueduct route", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" },
        { id: 2, content: "Already have some text", app_update_path: "/api/v1/app/chats/8/scratchpad_items/2", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/2" }
      ]
    })
    const afterDeletePayload = chatPayload({ scratchpad_items: [
      { id: 2, content: "Already have some text", app_update_path: "/api/v1/app/chats/8/scratchpad_items/2", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/2" }
    ] })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(afterStashPayload))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items/1" && (init as RequestInit)?.method === "DELETE") {
        return Promise.resolve(jsonResponse(afterDeletePayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 1, content: "Check the aqueduct route", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      })))
    })

    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...") as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: "Already have some text" } })

    await screen.findByText("Check the aqueduct route")
    fireEvent.click(screen.getByText("Check the aqueduct route"))

    await waitFor(() => {
      expect(textarea).toHaveValue("Check the aqueduct route")
    })

    const stashCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )
    expect(stashCalls).toHaveLength(1)
    expect(JSON.parse((stashCalls[0][1] as RequestInit).body as string)).toEqual({ scratchpad_item: { content: "Already have some text" } })

    const deleteCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items/1" && (call[1] as RequestInit)?.method === "DELETE"
    )
    expect(deleteCalls).toHaveLength(1)
  })

  it("calls DELETE when the delete button is clicked", async () => {
    const updatedPayload = chatPayload({ scratchpad_items: [] })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items/1" && (init as RequestInit)?.method === "DELETE") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 1, content: "Temporary note", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      })))
    })

    renderRoute()

    expect(await screen.findByText("Temporary note")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Delete item" }))

    await waitFor(() => {
      expect(screen.queryByText("Temporary note")).not.toBeInTheDocument()
    })

    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items/1" && (call[1] as RequestInit)?.method === "DELETE"
    )).toBe(true)
  })

  it("shows edit form when edit button is clicked and saves on save", async () => {
    const updatedPayload = chatPayload({
      scratchpad_items: [
        { id: 1, content: "Updated note", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
      ]
    })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items/1" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 1, content: "Original note", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      })))
    })

    renderRoute()

    await screen.findByText("Original note")
    fireEvent.click(screen.getByRole("button", { name: "Edit item" }))

    const editTextarea = screen.getByRole("textbox", { name: "Edit item" })
    fireEvent.change(editTextarea, { target: { value: "Updated note" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/chats/8/scratchpad_items/1", expect.objectContaining({ method: "PATCH" }))
    })
    expect(await screen.findByText("Updated note")).toBeInTheDocument()
    expect(screen.queryByText("Original note")).not.toBeInTheDocument()
  })

  it("shows inline add field inside the panel and adds an item on Enter", async () => {
    const updatedPayload = chatPayload({
      scratchpad_items: [
        { id: 1, content: "New draft note", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" },
        { id: 2, content: "First item", app_update_path: "/api/v1/app/chats/8/scratchpad_items/2", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/2" }
      ]
    })

    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 2, content: "First item", app_update_path: "/api/v1/app/chats/8/scratchpad_items/2", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/2" }
        ]
      })))
    })

    renderRoute()

    await screen.findByText("First item")
    const addInput = screen.getByRole("textbox", { name: "Add a note..." })
    fireEvent.change(addInput, { target: { value: "New draft note" } })
    fireEvent.keyDown(addInput, { key: "Enter" })

    expect(await screen.findByText("New draft note")).toBeInTheDocument()
    expect(addInput).toHaveValue("")
  })

  it("collapses and expands the panel on header click", async () => {
    mockChatRouteFetch(chatPayload({
      scratchpad_items: [
        { id: 1, content: "Check the aqueduct route", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
      ]
    }))
    renderRoute()

    await screen.findByText("Check the aqueduct route")

    fireEvent.click(screen.getByText("Scratch pad").closest("button")!)

    expect(screen.queryByText("Check the aqueduct route")).not.toBeInTheDocument()

    fireEvent.click(screen.getByText("Scratch pad").closest("button")!)

    expect(await screen.findByText("Check the aqueduct route")).toBeInTheDocument()
  })

  it("shows a Queue button on scratchpad items", async () => {
    mockChatRouteFetch(chatPayload({
      scratchpad_items: [
        { id: 1, content: "Refactor the aqueduct service", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
      ]
    }))
    renderRoute()

    await screen.findByText("Refactor the aqueduct service")
    expect(screen.getByRole("button", { name: "Queue" })).toBeInTheDocument()
  })

  it("calls POST queued_messages then DELETE scratchpad item on Queue click", async () => {
    const afterEnqueue = {
      ...chatPayload({
        scratchpad_items: [
          { id: 1, content: "Refactor the aqueduct service", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      }),
      agent_busy: true,
      queued_messages: [{ id: 20, text: "Refactor the aqueduct service", created_at: null, app_update_path: "/api/v1/app/chats/8/queued_messages/20", app_delete_path: "/api/v1/app/chats/8/queued_messages/20" }]
    }
    const afterDelete = chatPayload({ scratchpad_items: [], queued_messages: afterEnqueue.queued_messages })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/queued_messages" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(afterEnqueue))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items/1" && (init as RequestInit)?.method === "DELETE") {
        return Promise.resolve(jsonResponse(afterDelete))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        scratchpad_items: [
          { id: 1, content: "Refactor the aqueduct service", app_update_path: "/api/v1/app/chats/8/scratchpad_items/1", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/1" }
        ]
      })))
    })

    renderRoute()

    await screen.findByText("Refactor the aqueduct service")
    fireEvent.click(screen.getByRole("button", { name: "Queue" }))

    await waitFor(() => {
      expect(screen.queryByText("Scratch pad")).not.toBeInTheDocument()
    })

    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/queued_messages" && (call[1] as RequestInit)?.method === "POST"
    )).toBe(true)
    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items/1" && (call[1] as RequestInit)?.method === "DELETE"
    )).toBe(true)

    const enqueueCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/queued_messages" && (call[1] as RequestInit)?.method === "POST"
    )
    expect(JSON.parse((enqueueCalls[0][1] as RequestInit).body as string)).toMatchObject({ chat_message: { text: "Refactor the aqueduct service" } })
  })

  it("does not show the panel when agent is active but scratchpad is empty", async () => {
    mockChatRouteFetch({ ...chatPayload({ scratchpad_items: [] }), agent_busy: true })
    renderRoute()

    await screen.findByPlaceholderText("Queue a follow-up message...")
    expect(screen.queryByText("Scratch pad")).not.toBeInTheDocument()
  })
})

describe("queued message stash", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows a Stash button on each queued message row", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        queued_messages: [
          { id: 14, text: "Check the forum routes", created_at: null, app_update_path: "/api/v1/app/chats/8/queued_messages/14", app_delete_path: "/api/v1/app/chats/8/queued_messages/14" }
        ]
      })))
    })
    renderRoute()

    await screen.findByText("Check the forum routes")
    expect(screen.getByRole("button", { name: "Stash" })).toBeInTheDocument()
  })

  it("calls POST scratchpad_items then DELETE queued message on Stash click", async () => {
    const afterCreate = chatPayload({
      queued_messages: [
        { id: 14, text: "Check the forum routes", created_at: null, app_update_path: "/api/v1/app/chats/8/queued_messages/14", app_delete_path: "/api/v1/app/chats/8/queued_messages/14" }
      ],
      scratchpad_items: [
        { id: 5, content: "Check the forum routes", app_update_path: "/api/v1/app/chats/8/scratchpad_items/5", app_delete_path: "/api/v1/app/chats/8/scratchpad_items/5" }
      ]
    })
    const afterDelete = chatPayload({ scratchpad_items: afterCreate.scratchpad_items, queued_messages: [] })

    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (String(input) === "/api/v1/app/chats/8/scratchpad_items" && (init as RequestInit)?.method === "POST") {
        return Promise.resolve(jsonResponse(afterCreate))
      }
      if (String(input) === "/api/v1/app/chats/8/queued_messages/14" && (init as RequestInit)?.method === "DELETE") {
        return Promise.resolve(jsonResponse(afterDelete))
      }
      return Promise.resolve(jsonResponse(chatPayload({
        queued_messages: [
          { id: 14, text: "Check the forum routes", created_at: null, app_update_path: "/api/v1/app/chats/8/queued_messages/14", app_delete_path: "/api/v1/app/chats/8/queued_messages/14" }
        ]
      })))
    })

    renderRoute()

    await screen.findByText("Check the forum routes")
    fireEvent.click(screen.getByRole("button", { name: "Stash" }))

    await waitFor(() => {
      expect(screen.queryByText("Queued messages")).not.toBeInTheDocument()
    })

    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )).toBe(true)
    expect(fetchMock.mock.calls.some((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/queued_messages/14" && (call[1] as RequestInit)?.method === "DELETE"
    )).toBe(true)

    const stashCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
      String(call[0]) === "/api/v1/app/chats/8/scratchpad_items" && (call[1] as RequestInit)?.method === "POST"
    )
    expect(JSON.parse((stashCalls[0][1] as RequestInit).body as string)).toEqual({ scratchpad_item: { content: "Check the forum routes" } })
  })
})

describe("scratchpad panel via + menu", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows a Scratch pad button inside the + attachment popover", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))

    const dialog = screen.getByRole("dialog", { name: "Add attachment" })
    expect(within(dialog).getByRole("button", { name: /scratch pad/i })).toBeInTheDocument()
  })

  it("opens the scratchpad panel when clicking Scratch pad in the + menu even with no items", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))

    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()
  })

  it("closes the scratchpad panel when clicking the dismiss button", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))

    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close scratch pad" }))

    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()
  })

  it("toggles the scratchpad panel closed on second + menu click when open", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))
    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))
    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()
  })
})

describe("scratchpad panel via + menu", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("shows a Scratch pad button inside the + attachment popover", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))

    const dialog = screen.getByRole("dialog", { name: "Add attachment" })
    expect(within(dialog).getByRole("button", { name: /scratch pad/i })).toBeInTheDocument()
  })

  it("opens the scratchpad panel when clicking Scratch pad in the + menu even with no items", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))

    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()
  })

  it("closes the scratchpad panel when clicking the dismiss button", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))

    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close scratch pad" }))

    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()
  })

  it("toggles the scratchpad panel closed on second + menu click when open", async () => {
    mockChatRouteFetch(chatPayload({ scratchpad_items: [] }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))
    expect(screen.getByRole("button", { name: "Close scratch pad" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Add attachment" })).getByRole("button", { name: /scratch pad/i }))
    expect(screen.queryByRole("button", { name: "Close scratch pad" })).not.toBeInTheDocument()
  })
})

describe("AgentQuestions markdown rendering", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders bold markdown in question text as a <strong> element", async () => {
    mockChatRouteFetch(chatPayload({
      agent_questions: [{
        id: 1,
        questions: [{ question: "Should we use **fiber** or threads?", options: null, multiple: false }],
        asked_at: "2026-07-18T12:00:00Z",
        app_answer_path: "/api/v1/app/chats/8/agent_questions/1/answer"
      }]
    }))

    renderRoute()

    await screen.findByRole("region", { name: "Agent questions" })
    const strong = document.querySelector("strong")
    expect(strong).not.toBeNull()
    expect(strong).toHaveTextContent("fiber")
    expect(screen.queryByText(/\*\*fiber\*\*/)).not.toBeInTheDocument()
  })
})

describe("AgentQuestions wizard", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  const ANSWER_PATH = "/api/v1/app/chats/8/agent_questions/1/answer"

  function mockAgentQuestionsRouteFetch(agentQuestions: Array<Record<string, unknown>>) {
    const answerCalls: Array<{ path: string; body: { answers?: unknown[] } }> = []
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === ANSWER_PATH && init?.method === "POST") {
        answerCalls.push({ path, body: JSON.parse(String(init.body || "{}")) })
        return Promise.resolve(jsonResponse(chatPayload({ agent_questions: [] }, { message: "Answer submitted." })))
      }

      return Promise.resolve(jsonResponse(chatPayload({ agent_questions: agentQuestions })))
    })
    return { fetchMock, answerCalls }
  }

  it("advances a single-select step immediately, lets Back change it, and submits the summary atomically", async () => {
    const { answerCalls } = mockAgentQuestionsRouteFetch([{
      id: 1,
      questions: [
        { question: "Which path?", options: ["Fast", "Careful"], multiple: false },
        { question: "Any notes?", options: null, multiple: false }
      ],
      asked_at: "2026-07-18T12:00:00Z",
      app_answer_path: ANSWER_PATH
    }])

    renderRoute()

    await screen.findByText("Which path?")
    expect(screen.queryByRole("button", { name: "Back" })).not.toBeInTheDocument()
    // The generalized Stepper renders a "Question X of N" progress indicator up front.
    expect(screen.getByText("Question 1")).toBeInTheDocument()
    expect(screen.getByText("Question 2")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Fast" }))

    // Single-select commits and advances without a separate POST.
    await screen.findByText("Any notes?")
    expect(screen.queryByText("Which path?")).not.toBeInTheDocument()
    expect(answerCalls).toHaveLength(0)

    fireEvent.click(screen.getByRole("button", { name: "Back" }))
    await screen.findByText("Which path?")

    // Re-answering the first step overwrites the earlier draft.
    fireEvent.click(screen.getByRole("button", { name: "Careful" }))
    await screen.findByText("Any notes?")

    fireEvent.change(screen.getByLabelText("Custom answer"), { target: { value: "None." } })
    fireEvent.click(screen.getByRole("button", { name: "Submit" }))

    await screen.findByText("Review your answers")
    expect(screen.getByText("Careful")).toBeInTheDocument()
    expect(screen.getByText("None.")).toBeInTheDocument()
    expect(answerCalls).toHaveLength(0)

    fireEvent.click(screen.getByRole("button", { name: "Submit all answers" }))

    await waitFor(() => expect(answerCalls).toHaveLength(1))
    expect(answerCalls[0].body.answers).toEqual(["Careful", "None."])
    await screen.findByText("Answer submitted.")
    expect(screen.queryByRole("region", { name: "Agent questions" })).not.toBeInTheDocument()
  })

  it("requires an explicit Submit for multi-select and preserves the checked state across Back", async () => {
    mockAgentQuestionsRouteFetch([{
      id: 1,
      questions: [
        { question: "Which tools?", options: ["Fiber", "Threads", "Locks"], multiple: true },
        { question: "Any notes?", options: null, multiple: false }
      ],
      asked_at: "2026-07-18T12:00:00Z",
      app_answer_path: ANSWER_PATH
    }])

    renderRoute()

    await screen.findByText("Which tools?")
    expect(screen.getByRole("button", { name: "Submit" })).toBeDisabled()

    fireEvent.click(screen.getByRole("checkbox", { name: "Toggle Fiber" }))
    fireEvent.click(screen.getByRole("checkbox", { name: "Toggle Threads" }))
    expect(screen.getByRole("button", { name: "Submit" })).toBeEnabled()

    // Checking boxes alone must not advance the wizard.
    expect(screen.getByText("Which tools?")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Submit" }))
    await screen.findByText("Any notes?")

    fireEvent.click(screen.getByRole("button", { name: "Back" }))
    await screen.findByText("Which tools?")

    expect(screen.getByRole("checkbox", { name: "Toggle Fiber" })).toBeChecked()
    expect(screen.getByRole("checkbox", { name: "Toggle Threads" })).toBeChecked()
    expect(screen.getByRole("checkbox", { name: "Toggle Locks" })).not.toBeChecked()
  })

  it("renders no wizard chrome for a single question and posts immediately", async () => {
    const { answerCalls } = mockAgentQuestionsRouteFetch([{
      id: 1,
      questions: [{ question: "Which path?", options: ["Fast", "Careful"], multiple: false }],
      asked_at: "2026-07-18T12:00:00Z",
      app_answer_path: ANSWER_PATH
    }])

    renderRoute()

    await screen.findByText("Which path?")
    expect(screen.queryByRole("button", { name: "Back" })).not.toBeInTheDocument()
    expect(screen.queryByText("Review your answers")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Fast" }))

    await waitFor(() => expect(answerCalls).toHaveLength(1))
    expect(answerCalls[0].body.answers).toEqual(["Fast"])
  })

  it("records the decline literal for a free-text step", async () => {
    const { answerCalls } = mockAgentQuestionsRouteFetch([{
      id: 1,
      questions: [{ question: "Anything else?", options: null, multiple: false }],
      asked_at: "2026-07-18T12:00:00Z",
      app_answer_path: ANSWER_PATH
    }])

    renderRoute()

    await screen.findByText("Anything else?")
    fireEvent.click(screen.getByRole("button", { name: "Decline to answer" }))

    await waitFor(() => expect(answerCalls).toHaveLength(1))
    expect(answerCalls[0].body.answers).toEqual(["I decline to answer."])
  })

  it("records the decline literal as an array for a multi-select step", async () => {
    const { answerCalls } = mockAgentQuestionsRouteFetch([{
      id: 1,
      questions: [{ question: "Which tools?", options: ["Fiber", "Threads"], multiple: true }],
      asked_at: "2026-07-18T12:00:00Z",
      app_answer_path: ANSWER_PATH
    }])

    renderRoute()

    await screen.findByText("Which tools?")
    fireEvent.click(screen.getByRole("button", { name: "Decline to answer" }))

    await waitFor(() => expect(answerCalls).toHaveLength(1))
    expect(answerCalls[0].body.answers).toEqual([["I decline to answer."]])
  })
})

describe("group chat participants and composer hint", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  function groupParticipants() {
    return [
      { id: 1, name: "Marcus Cato", avatar_url: null, role: "owner" },
      { id: 2, name: "Livia Drusilla", avatar_url: null, role: "member" }
    ]
  }

  it("shows the @syrus mention hint in the composer for a group chat with 2+ participants", async () => {
    mockChatRouteFetch(chatPayload({ chat: { conversation_kind: "group", participants: groupParticipants() } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByTestId("group-mention-hint")).toBeInTheDocument()
  })

  it("does not show the mention hint in a direct chat", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByTestId("group-mention-hint")).not.toBeInTheDocument()
  })

  it("does not show the mention hint once the group is down to one participant", async () => {
    mockChatRouteFetch(chatPayload({
      chat: { conversation_kind: "group", participants: [{ id: 1, name: "Marcus Cato", avatar_url: null, role: "owner" }] }
    }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByTestId("group-mention-hint")).not.toBeInTheDocument()
  })

  it("renders the participant list in the chat header for a group chat", async () => {
    mockChatRouteFetch(chatPayload({ chat: { conversation_kind: "group", participants: groupParticipants() } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByText("Marcus Cato")).toBeInTheDocument()
    expect(screen.getByText("Livia Drusilla")).toBeInTheDocument()
  })

  it("adds a participant through the invite picker", async () => {
    const payload = chatPayload({ chat: { conversation_kind: "group", participants: groupParticipants() } })
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: { id: 1, display_name: "Marcus Cato" } }))
      }
      if (path.startsWith("/api/v1/app/users/invitable")) {
        return Promise.resolve(jsonResponse([{ id: 3, name: "Cicero", avatar_url: null }]))
      }
      if (path === "/api/v1/app/chats/8/participants" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          participants: [...groupParticipants(), { id: 3, name: "Cicero", avatar_url: null, role: "member" }]
        }, 201))
      }

      return Promise.resolve(jsonResponse(payload))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: /Add participant/i }))

    const option = await screen.findByRole("option", { name: /Cicero/i })
    fireEvent.click(option)
    fireEvent.click(screen.getByRole("button", { name: "Add" }))

    await waitFor(() => {
      expect(fetchMock.mock.calls.some((call) => String(call[0]) === "/api/v1/app/chats/8/participants" && (call[1] as RequestInit)?.method === "POST")).toBe(true)
    })
    await waitFor(() => {
      expect(screen.queryByRole("dialog", { name: "Add participant" })).not.toBeInTheDocument()
    })
    expect(screen.getAllByText("Cicero").length).toBeGreaterThan(0)
  })

  it("removes another participant from the group", async () => {
    const payload = chatPayload({ chat: { conversation_kind: "group", participants: groupParticipants() } })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: { id: 1, display_name: "Marcus Cato" } }))
      }
      if (path === "/api/v1/app/chats/8/participants/2" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ participants: [groupParticipants()[0]] }))
      }

      return Promise.resolve(jsonResponse(payload))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Remove Livia Drusilla" }))

    await waitFor(() => {
      expect(screen.queryByText("Livia Drusilla")).not.toBeInTheDocument()
    })
  })

  it("leaves the group chat when the current user removes themselves, navigating away", async () => {
    const payload = chatPayload({ chat: { conversation_kind: "group", participants: groupParticipants() } })
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/bootstrap") {
        return Promise.resolve(jsonResponse({ current_user: { id: 1, display_name: "Marcus Cato" } }))
      }
      if (path === "/api/v1/app/chats/8/participants/1" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse({ participants: [groupParticipants()[1]] }))
      }

      return Promise.resolve(jsonResponse(payload))
    })

    renderRouteWithLocation()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(await screen.findByRole("button", { name: "Leave chat" }))

    await waitFor(() => {
      expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/dashboard/jobs")
    })
  })
})

function renderRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
        <Routes>
          <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function renderRouteWithAwayLink() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
        <Routes>
          <Route element={<ChatRouteWithAwayLink />} path="/app-shell/chats/:id" />
          <Route element={<AwayPage />} path="/app-shell/away" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function ChatRouteWithAwayLink() {
  return (
    <>
      <Link to="/app-shell/away">Go away</Link>
      <ChatRoute />
    </>
  )
}

function AwayPage() {
  return (
    <>
      <div>Away page</div>
      <Link to="/app-shell/chats/8">Go back</Link>
    </>
  )
}

// Unlike mockDesktopViewport/mockMobileViewport (a fixed snapshot), this
// keeps the registered matchMedia change listener so a test can flip the
// breakpoint mid-session the way a real window resize would.
function mockDynamicViewport(initialDesktop: boolean) {
  let matches = initialDesktop
  const listeners = new Set<(event: { matches: boolean }) => void>()
  const mediaQueryList = {
    get matches() {
      return matches
    },
    media: "(min-width: 1024px)",
    onchange: null,
    addEventListener: (_event: string, listener: (event: { matches: boolean }) => void) => {
      listeners.add(listener)
    },
    removeEventListener: (_event: string, listener: (event: { matches: boolean }) => void) => {
      listeners.delete(listener)
    },
    addListener: (listener: (event: { matches: boolean }) => void) => listeners.add(listener),
    removeListener: (listener: (event: { matches: boolean }) => void) => listeners.delete(listener),
    dispatchEvent: vi.fn()
  }

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn(() => mediaQueryList)
  })

  return {
    setDesktop(next: boolean) {
      matches = next
      listeners.forEach((listener) => listener({ matches: next }))
    }
  }
}

function renderRouteWithLocation() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
        <LocationProbe />
        <Routes>
          <Route element={<ChatRoute />} path="/app-shell/chats/:id" />
          <Route element={<div />} path="/app-shell/jobs" />
          <Route element={<div />} path="/app-shell/jobs/:id" />
          <Route element={<div />} path="/app-shell/epics/:id" />
          <Route element={<div />} path="/app-shell/dashboard/jobs" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function setBootstrapMode(mode: "advanced" | "simple") {
  document.getElementById("syrus-bootstrap-data")?.remove()
  const script = document.createElement("script")
  script.id = "syrus-bootstrap-data"
  script.type = "application/json"
  script.textContent = JSON.stringify({ app: { mode }, feature_flags: {} })
  document.body.appendChild(script)
}

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}{location.search}</div>
}

async function submitSlashCommand(command: string) {
  const textarea = await screen.findByPlaceholderText("Ask about this repository...")
  fireEvent.change(textarea, { target: { value: command } })
  fireEvent.click(screen.getByRole("button", { name: "Send message" }))
}

function mockChatRouteFetch(payload = chatPayload()) {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (path === "/api/v1/app/chats/8/scheduled_messages" && init?.method === "POST") {
      const body = JSON.parse(String(init.body || "{}")).scheduled_message || {}
      return Promise.resolve(jsonResponse({
        id: 1,
        body: body.body || "",
        fire_at: body.fire_at || new Date().toISOString(),
        message: "Message scheduled."
      }, 201))
    }

    return Promise.resolve(jsonResponse(payload))
  })
}

function mockDictationFetch(payload = chatPayload(), options: { batchText?: string } = {}) {
  vi.stubGlobal("XMLHttpRequest", fakeDictationXMLHttpRequestClass(options.batchText || "backend batch transcript"))
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (path === "/api/v1/app/chats/8/speech_to_text/stream" && init?.method === "POST") {
      return Promise.resolve(jsonResponse({
        stream: {
          transport: "action_cable",
          channel: "ChatDictationChannel",
          chat_session_id: 8,
          events: ["started", "ack", "transcript_delta", "done", "cancelled", "error"],
          fallback: {
            mode: "backend_batch",
            buffered_audio_required: true,
            endpoint: "/api/v1/app/chats/8/speech_to_text"
          }
        }
      }))
    }
    if (path === "/api/v1/app/chats/8/speech_to_text" && init?.method === "POST") {
      return Promise.resolve(jsonResponse({
        transcript: {
          text: options.batchText || "backend batch transcript",
          source: "backend_batch",
          confidence: null
        }
      }))
    }
    if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
      return Promise.resolve(jsonResponse(payload))
    }

    return Promise.resolve(jsonResponse(payload))
  })
}

class FakeDictationXMLHttpRequest {
  method = ""
  url = ""
  responseType = ""
  response: unknown = null
  status = 0
  headers: Record<string, string> = {}
  onload: (() => void) | null = null
  onerror: (() => void) | null = null
  onabort: (() => void) | null = null

  constructor(private readonly transcriptText: string) {}

  open(method: string, url: string) {
    this.method = method
    this.url = url
  }

  setRequestHeader(name: string, value: string) {
    this.headers[name] = value
  }

  send(_body: XMLHttpRequestBodyInit | null) {
    this.status = 200
    this.response = {
      transcript: {
        text: this.transcriptText,
        source: "backend_batch",
        confidence: null
      }
    }
    window.setTimeout(() => this.onload?.(), 0)
  }

  abort() {
    this.onabort?.()
  }
}

function fakeDictationXMLHttpRequestClass(transcriptText: string) {
  return class extends FakeDictationXMLHttpRequest {
    constructor() {
      super(transcriptText)
    }
  }
}

function chatPayloadWithDictation(options: { streaming?: boolean; batch?: boolean; browser?: boolean }) {
  const payload = chatPayload({}, { speech_to_text: speechCapability(options) })
  return {
    ...payload,
    paths: {
      ...payload.paths,
      ...speechPaths()
    }
  }
}

function speechCapability(options: { streaming?: boolean; batch?: boolean; browser?: boolean }) {
  return {
    enabled: Boolean(options.streaming || options.batch || options.browser),
    modes: {
      backend_streaming: { available: Boolean(options.streaming) },
      backend_batch: { available: Boolean(options.batch) },
      browser: { available: Boolean(options.browser) }
    }
  }
}

function speechPaths() {
  return {
    app_speech_to_text_batch_path: "/api/v1/app/chats/8/speech_to_text",
    app_speech_to_text_stream_path: "/api/v1/app/chats/8/speech_to_text/stream"
  }
}

function mockAudioPermission(result: Promise<MediaStream> | (() => Promise<MediaStream>) = () => Promise.resolve(fakeMediaStream())) {
  Object.defineProperty(navigator, "mediaDevices", {
    configurable: true,
    value: {
      getUserMedia: vi.fn(() => typeof result === "function" ? result() : result)
    }
  })
}

function fakeMediaStream() {
  return {
    getTracks: () => [{ stop: vi.fn() }]
  } as unknown as MediaStream
}

function installMediaRecorderMock() {
  class FakeMediaRecorder {
    static isTypeSupported() {
      return true
    }

    state: "inactive" | "recording" = "inactive"
    ondataavailable: ((event: BlobEvent) => void) | null = null
    onstop: (() => void) | null = null

    constructor(_stream: MediaStream, _options?: MediaRecorderOptions) {}

    start() {
      this.state = "recording"
    }

    stop() {
      this.state = "inactive"
      this.ondataavailable?.({ data: new Blob(["audio"], { type: "audio/webm" }) } as BlobEvent)
      this.onstop?.()
    }
  }

  vi.stubGlobal("MediaRecorder", FakeMediaRecorder)
}

function installSpeechRecognitionMock() {
  const holder: { lastInstance: SpeechRecognitionMock | null } = { lastInstance: null }

  class SpeechRecognitionMock {
    continuous = false
    interimResults = false
    onresult: ((event: { resultIndex: number; results: Array<{ isFinal: boolean; 0: { transcript: string } }> }) => void) | null = null
    onerror: ((event: { error?: string }) => void) | null = null
    onend: (() => void) | null = null
    start = vi.fn()
    stop = vi.fn(() => this.onend?.())

    constructor() {
      holder.lastInstance = this
    }
  }

  vi.stubGlobal("SpeechRecognition", SpeechRecognitionMock)
  return holder
}

let restoreClipboardMock: (() => void) | null = null

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

function mockChatPayload(payload: unknown) {
  vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (path.startsWith("/api/v1/app/chats/8/context")) {
      return Promise.resolve(jsonResponse(emptyChatContextPayload()))
    }

    return Promise.resolve(jsonResponse(payload))
  })
}

function emptyChatContextPayload() {
  return {
    attachment_groups: { repositories: [], epics: [], jobs: [], documents: [] },
    documents_in_scope: [],
    attachment_results: []
  }
}

// Evaluates a `(min-width: Npx)` / `(max-width: Npx)` query against a
// simulated viewport width, the way a real browser's matchMedia would.
// Chat.tsx registers matchMedia listeners at more than one breakpoint (the
// app-wide 1024px used by ChatView's header and ChatWorkspace's own wider
// CHAT_WORKSPACE_SPLIT_MIN_WIDTH split), so a mock keyed to one literal
// breakpoint string silently stops covering the other.
function mockViewportWidth(width: number) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: matchesViewportWidth(query, width),
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

function matchesViewportWidth(query: string, width: number) {
  const minMatch = query.match(/min-width:\s*(\d+)px/)
  if (minMatch) return width >= Number(minMatch[1])

  const maxMatch = query.match(/max-width:\s*(\d+)px/)
  if (maxMatch) return width <= Number(maxMatch[1])

  return false
}

function mockDesktopViewport() {
  mockViewportWidth(1920)
}

function mockMobileViewport() {
  mockViewportWidth(375)
}

function mockChatAttachmentFetch() {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }
    if (path.startsWith("/api/v1/app/chats/8/context")) {
      return Promise.resolve(jsonResponse({
        ...emptyChatContextPayload(),
        attachment_groups: {
          repositories: [],
          epics: [],
          jobs: [],
          documents: [
            { id: 31, label: "Runbook.md", app_detach_path: "/api/v1/app/chats/8/attachments/31" }
          ]
        }
      }))
    }

    return Promise.resolve(jsonResponse(chatPayload({
      attachment_groups: {
        documents: [
          { id: 31, label: "Runbook.md", app_detach_path: "/api/v1/app/chats/8/attachments/31" }
        ]
      }
    })))
  })
}

function detachRequests(fetchMock: ReturnType<typeof vi.spyOn>) {
  return fetchMock.mock.calls.filter((call: unknown[]) => {
    const input = call[0]
    const init = call[1] as RequestInit | undefined
    return String(input) === "/api/v1/app/chats/8/attachments/31" && init?.method === "DELETE"
  })
}

function messageWithProposal(id: number, chatProposal: Record<string, unknown>) {
  return {
    type: "message",
    id,
    role: "assistant",
    tool_name: null,
    content: { text: `Discuss proposal ${id}.` },
    text: `Discuss proposal ${id}.`,
    bookmarkable: true,
    proposal: chatProposal
  }
}

function chatMessage(id: number, role: "assistant" | "user" | "system", text: string, createdAt: Date) {
  return {
    type: "message",
    id,
    role,
    tool_name: null,
    content: { text },
    text,
    bookmarkable: true,
    created_at: createdAt.toISOString()
  }
}

function localDateAt(hour: number, minute: number, dayOffset = 0) {
  const date = new Date()
  date.setDate(date.getDate() + dayOffset)
  date.setHours(hour, minute, 0, 0)
  return date
}

function shortTime(date: Date) {
  return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
}

function dayLabel(date: Date) {
  const today = new Date()
  const todayStart = new Date(today.getFullYear(), today.getMonth(), today.getDate())
  const dateStart = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  const dayDelta = Math.round((todayStart.getTime() - dateStart.getTime()) / (24 * 60 * 60 * 1000))

  if (dayDelta === 0) return "Today"
  if (dayDelta === 1) return "Yesterday"

  return date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" })
}

function developerUser() {
  return {
    id: 1,
    email_address: "dev@example.com",
    name: "Developer",
    first_name: null,
    last_name: null,
    display_name: "Developer",
    admin: false,
    role: "developer",
    scheduling_paused: false,
    landing_paused: false,
    agent_provider: "claude",
    chat_provider: "claude",
    agent_max_turns: 200,
    theme: "light",
    locale: "en"
  }
}

function proposal(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    kind: "job",
    kind_label: "Job",
    state: "proposed",
    state_label: "Pending",
    title: "Survey aqueduct route",
    slug: "JOB-DRAFT-1",
    body: "Inspect the aqueduct route.",
    proposed: true,
    resolved: false,
    epic_bundle: false,
    scoped_repository_slug: null,
    dependency_slugs: [],
    dependencies: [],
    has_dependencies: false,
    target_epic_id: null,
    target_epic_label: null,
    app_update_path: "/api/v1/app/chats/8/proposals/1",
    app_confirm_path: "/api/v1/app/chats/8/proposals/1/confirm",
    app_reject_path: "/api/v1/app/chats/8/proposals/1/reject",
    materialized_label: null,
    materialized_path: null,
    materialized: null,
    ...overrides
  }
}

function chatPayload(overrides: { chat?: Record<string, unknown>; messages?: Array<Record<string, unknown>>; bookmarks?: Array<Record<string, unknown>>; attachment_groups?: Record<string, Array<Record<string, unknown>>>; attachment_results?: Array<Record<string, unknown>>; scratchpad_items?: Array<Record<string, unknown>>; queued_messages?: Array<Record<string, unknown>>; agent_questions?: Array<Record<string, unknown>> } = {}, rootOverrides: Record<string, unknown> = {}) {
  return {
    chat: {
      id: 8,
      title: "Aqueduct planning",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/8",
      repository: { id: 3, slug: "acme/widgets", repository_path: "/repositories/3" },
      stop_requested_at: null,
      cumulative_input_tokens: 12400,
      cumulative_output_tokens: 3200,
      cumulative_cost_usd: 0.0123,
      confirmed_proposal_count: 0,
      ...overrides.chat
    },
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    switching_provider: false,
    has_more_older: false,
    pending_proposal_count: undefined,
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
    bookmarks: overrides.bookmarks || [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: overrides.agent_questions || [],
    queued_messages: overrides.queued_messages || [],
    scratchpad_items: overrides.scratchpad_items || [],
    attachment_groups: {
      repositories: overrides.attachment_groups?.repositories || [],
      epics: overrides.attachment_groups?.epics || [],
      jobs: overrides.attachment_groups?.jobs || [],
      documents: overrides.attachment_groups?.documents || []
    },
    documents_in_scope: [],
    attachment_results: overrides.attachment_results || [],
    preview_panels: [],
    workspace_tabs: [
      { id: "whiteboard_tools.canvas", label: "Whiteboard", label_key: "whiteboard_tools:tab_whiteboard", component: "whiteboard_tools/WhiteboardTab", order: 0 }
    ],
    local_mode_enabled: false,
    speech_to_text: {
      enabled: false,
      modes: {
        backend_streaming: { available: false },
        backend_batch: { available: false },
        browser: { available: false }
      }
    },
    whiteboard: {
      version: 1,
      elements: [],
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
      app_branch_path: "/api/v1/app/chats/8/branch",
      app_enqueue_message_path: "/api/v1/app/chats/8/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/8/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_bookmarks_index_path: "/api/v1/app/chats/8/bookmarks",
      app_context_path: "/api/v1/app/chats/8/context",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/8/scratchpad_items/reorder"
    },
    ...rootOverrides
  }
}

describe("chat mode selector in toolbar", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("does not render the mode selector when only planning mode is available", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Change mode" })).not.toBeInTheDocument()
  })

  it("renders the mode selector when coding mode is available", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), coding_mode_enabled: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("button", { name: "Change mode" })).toBeInTheDocument()
  })

  it("does not render the mode selector for Supervisor chats when coding mode is available", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({
        ...chatPayload({ chat: { repository: null, system_kind: "supervisor", title: "Supervisor" } }),
        coding_mode_enabled: true,
        local_mode_enabled: true
      }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Ask about incidents, stuck Jobs, Workflows, Runs, queues, PRs, or operational state...")
    expect(screen.queryByRole("button", { name: "Change mode" })).not.toBeInTheDocument()
  })

  it("renders the mode selector when local mode is available", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), local_mode_enabled: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("button", { name: "Change mode" })).toBeInTheDocument()
  })

  it("shows Planning label in the selector when no mode is set", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), coding_mode_enabled: true }))
    })
    renderRoute()

    const button = await screen.findByRole("button", { name: "Change mode" })
    expect(button).toHaveTextContent("Planning")
  })

  it("shows the current mode label when a non-default mode is set", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload({ chat: { mode: "coding" } }), coding_mode_enabled: true }))
    })
    renderRoute()

    const button = await screen.findByRole("button", { name: "Change mode" })
    expect(button).toHaveTextContent("Coding")
  })

  it("opens a listbox with available mode options on click", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), coding_mode_enabled: true }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Change mode" }))

    const listbox = screen.getByRole("listbox")
    expect(within(listbox).getByRole("option", { name: "Planning" })).toBeInTheDocument()
    expect(within(listbox).getByRole("option", { name: "Coding" })).toBeInTheDocument()
  })

  it("calls PATCH /api/v1/app/chats/8 with the selected mode and closes the dropdown", async () => {
    const updatedPayload = { ...chatPayload({ chat: { mode: "coding" } }), coding_mode_enabled: true }
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), coding_mode_enabled: true }))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Change mode" }))
    fireEvent.click(within(screen.getByRole("listbox")).getByRole("option", { name: "Coding" }))

    await waitFor(() => {
      const patchCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
        String(call[0]) === "/api/v1/app/chats/8" && (call[1] as RequestInit)?.method === "PATCH"
      )
      expect(patchCalls).toHaveLength(1)
      expect(JSON.parse((patchCalls[0][1] as RequestInit).body as string)).toMatchObject({ chat: { mode: "coding" } })
    })

    expect(screen.queryByRole("listbox")).not.toBeInTheDocument()
  })
})

describe("LocalDaemonBanner", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  function mockLocalChatFetch(options: { daemonSessionStatus?: number; daemonSessionBody?: unknown } = {}) {
    let createCalls = 0
    const spy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8/local_daemon_session" && init?.method === "POST") {
        createCalls += 1
        return Promise.resolve(jsonResponse(
          options.daemonSessionBody ?? {
            daemon_session: {
              id: 1,
              chat_session_id: 8,
              connected: false,
              daemon_repo: null,
              daemon_branch: null,
              last_heartbeat_at: null,
              auth_token: "secret-token"
            }
          },
          options.daemonSessionStatus ?? 201
        ))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload({ chat: { mode: "local" } }), local_mode_enabled: true }))
    })
    return { spy, createCalls: () => createCalls }
  }

  it("creates a pairing session and renders the interpolated command", async () => {
    mockLocalChatFetch()
    renderRoute()

    await screen.findByText("syrus local --chat 8 --token secret-token")
  })

  it("only requests a pairing session once", async () => {
    const { createCalls } = mockLocalChatFetch()
    renderRoute()

    await screen.findByText("syrus local --chat 8 --token secret-token")
    expect(createCalls()).toBe(1)
  })

  it("shows an error message when the pairing session request fails", async () => {
    mockLocalChatFetch({
      daemonSessionStatus: 404,
      daemonSessionBody: { error: { code: "not_found", message: "Local Mode is not enabled." } }
    })
    renderRoute()

    await screen.findByText("Could not prepare a pairing command. Try reloading the page.")
  })

  it("does not render a banner once the daemon is connected", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({
        ...chatPayload({ chat: { mode: "local", local_daemon_state: "connected" } }),
        local_mode_enabled: true
      }))
    })
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByText(/syrus local/)).not.toBeInTheDocument()
  })
})

describe("chat model selector in toolbar", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("does not render the model selector when available_chat_models is absent", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Chat model" })).not.toBeInTheDocument()
  })

  it("does not render the model selector when available_chat_models is empty", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [] } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Chat model" })).not.toBeInTheDocument()
  })

  it("renders the model selector when available_chat_models is non-empty", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }] } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("button", { name: "Chat model" })).toBeInTheDocument()
  })

  it("shows Default label when no model is selected", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }], chat_model: null } }))
    renderRoute()

    const button = await screen.findByRole("button", { name: "Chat model" })
    expect(button).toHaveTextContent("Default")
  })

  it("shows the current model label when a model is selected", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }], chat_model: "claude-opus-4-7" } }))
    renderRoute()

    const button = await screen.findByRole("button", { name: "Chat model" })
    expect(button).toHaveTextContent("Opus 4.7")
  })

  it("opens a listbox with model options on click", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }] } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Chat model" }))

    const listbox = screen.getByRole("listbox")
    expect(within(listbox).getByRole("option", { name: "Default" })).toBeInTheDocument()
    expect(within(listbox).getByRole("option", { name: "Opus 4.7" })).toBeInTheDocument()
  })

  it("calls PATCH with the selected model and closes the dropdown", async () => {
    const models = [{ value: "claude-opus-4-7", label: "Opus 4.7" }]
    const updatedPayload = chatPayload({ chat: { available_chat_models: models, chat_model: "claude-opus-4-7" } })
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({ chat: { available_chat_models: models } })))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Chat model" }))
    fireEvent.click(within(screen.getByRole("listbox")).getByRole("option", { name: "Opus 4.7" }))

    await waitFor(() => {
      const patchCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
        String(call[0]) === "/api/v1/app/chats/8" && (call[1] as RequestInit)?.method === "PATCH"
      )
      expect(patchCalls).toHaveLength(1)
      expect(JSON.parse((patchCalls[0][1] as RequestInit).body as string)).toMatchObject({ chat: { chat_model: "claude-opus-4-7" } })
    })

    expect(screen.queryByRole("listbox")).not.toBeInTheDocument()
  })

  it("closes the dropdown on outside click", async () => {
    mockChatRouteFetch(chatPayload({ chat: { available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }] } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Chat model" }))
    expect(screen.getByRole("listbox")).toBeInTheDocument()

    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument()
  })
})

describe("chat effort selector in toolbar", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("does not render the effort selector when the provider is not claude", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "codex" } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.queryByRole("button", { name: "Effort" })).not.toBeInTheDocument()
  })

  it("renders the effort selector when the provider is claude", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "claude" } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    expect(screen.getByRole("button", { name: "Effort" })).toBeInTheDocument()
  })

  it("shows None label when no effort is set", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "claude", chat_effort: null } }))
    renderRoute()

    const button = await screen.findByRole("button", { name: "Effort" })
    expect(button).toHaveTextContent("None")
  })

  it("shows the current effort label when an effort is selected", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "claude", chat_effort: "high" } }))
    renderRoute()

    const button = await screen.findByRole("button", { name: "Effort" })
    expect(button).toHaveTextContent("High")
  })

  it("opens a listbox with effort options on click", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "claude" } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Effort" }))

    const listbox = screen.getByRole("listbox")
    expect(within(listbox).getByRole("option", { name: "None" })).toBeInTheDocument()
    expect(within(listbox).getByRole("option", { name: "Medium" })).toBeInTheDocument()
    expect(within(listbox).getByRole("option", { name: "High" })).toBeInTheDocument()
  })

  it("calls PATCH with the selected effort and closes the dropdown", async () => {
    const updatedPayload = chatPayload({ chat: { effective_chat_provider: "claude", chat_effort: "medium" } })
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      if (path === "/api/v1/app/chats/8" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(jsonResponse(updatedPayload))
      }
      return Promise.resolve(jsonResponse(chatPayload({ chat: { effective_chat_provider: "claude" } })))
    })

    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Effort" }))
    fireEvent.click(within(screen.getByRole("listbox")).getByRole("option", { name: "Medium" }))

    await waitFor(() => {
      const patchCalls = fetchMock.mock.calls.filter((call: unknown[]) =>
        String(call[0]) === "/api/v1/app/chats/8" && (call[1] as RequestInit)?.method === "PATCH"
      )
      expect(patchCalls).toHaveLength(1)
      expect(JSON.parse((patchCalls[0][1] as RequestInit).body as string)).toMatchObject({ chat: { chat_effort: "medium" } })
    })

    expect(screen.queryByRole("listbox")).not.toBeInTheDocument()
  })

  it("closes the dropdown on outside click", async () => {
    mockChatRouteFetch(chatPayload({ chat: { effective_chat_provider: "claude" } }))
    renderRoute()

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Effort" }))
    expect(screen.getByRole("listbox")).toBeInTheDocument()

    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument()
  })

  it("keeps the effort selector in the same wrapping toolbar row as the mode and model selectors", async () => {
    mockChatRouteFetch(chatPayload(
      { chat: { effective_chat_provider: "claude", available_chat_models: [{ value: "claude-opus-4-7", label: "Opus 4.7" }] } },
      { coding_mode_enabled: true }
    ))
    renderRoute()

    const modeButton = await screen.findByRole("button", { name: "Change mode" })
    const modelButton = screen.getByRole("button", { name: "Chat model" })
    const effortButton = screen.getByRole("button", { name: "Effort" })

    // Regression guard: the effort selector used to live outside the toolbar's
    // wrapping flex row as a `justify-between` sibling, so once the row wrapped
    // to a second line on narrow viewports it centered against the row's full
    // (multi-line) height and floated away from the control it belonged next to.
    // All toolbar controls must share the same wrapping row so they wrap together.
    const modeRow = modeButton.closest('[class*="flex-wrap"]')
    const modelRow = modelButton.closest('[class*="flex-wrap"]')
    const effortRow = effortButton.closest('[class*="flex-wrap"]')

    expect(modeRow).not.toBeNull()
    expect(modelRow).toBe(modeRow)
    expect(effortRow).toBe(modeRow)
  })
})

describe("renderChatMessages tool_result content key", () => {
  it("anchors proposal and pending action cards after the tool events that produced them", () => {
    const proposal = {
      id: 88,
      kind: "job",
      kind_label: "Job",
      state: "proposed",
      state_label: "Proposed",
      title: "Fix transcript cards",
      slug: "job-fix-transcript-cards",
      body: "Keep cards next to their producing calls.",
      proposed: true,
      resolved: false,
      epic_bundle: false,
      scoped_repository_slug: "tkadauke/syrus",
      dependency_slugs: [],
      depends_on_job_ids: [],
      depends_on_epic_ids: [],
      dependencies: [],
      has_dependencies: false,
      target_epic_id: null,
      target_epic_label: null,
      app_update_path: "/api/v1/app/chats/122/proposals/88",
      app_confirm_path: "/api/v1/app/chats/122/proposals/88/confirm",
      app_reject_path: "/api/v1/app/chats/122/proposals/88/reject",
      materialized_label: null,
      materialized_path: null,
      materialized: null,
      materialized_epic_state: null,
      materialized_epic_state_path: null,
      media_ids: []
    }

    const messages = [
      {
        type: "message" as const,
        id: 1,
        role: "user" as const,
        content: { text: "Please prepare these actions." },
        text: "Please prepare these actions.",
        bookmarkable: true
      },
      {
        type: "message" as const,
        id: 2,
        role: "assistant" as const,
        content: [{ type: "text", text: "I will draft the job first." }],
        text: "I will draft the job first.",
        bookmarkable: true
      },
      {
        type: "message" as const,
        id: 3,
        role: "tool_use" as const,
        tool_name: "syrus-chat-sidecar.propose_job",
        content: { type: "tool_use", id: "toolu_propose", name: "propose_job", input: { title: "Fix transcript cards" } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 4,
        role: "assistant" as const,
        content: [{ type: "text", text: "Job proposal proposed." }],
        text: "Job proposal proposed.",
        bookmarkable: true,
        proposal
      },
      {
        type: "message" as const,
        id: 5,
        role: "assistant" as const,
        content: [{ type: "text", text: "Now I will request the rebase." }],
        text: "Now I will request the rebase.",
        bookmarkable: true
      },
      {
        type: "message" as const,
        id: 6,
        role: "tool_use" as const,
        tool_name: "syrus-chat-sidecar.rebase_job",
        content: { type: "tool_use", id: "toolu_rebase", name: "rebase_job", input: { job_id: 2325 } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 7,
        role: "tool_result" as const,
        tool_name: "syrus-chat-sidecar.rebase_job",
        content: {
          type: "tool_result",
          tool_use_id: "toolu_rebase",
          content: "{\"pending_action_id\":114,\"message\":\"Job rebase requires operator confirmation.\"}",
          is_error: false
        },
        text: "",
        bookmarkable: false
      }
    ]
    const pendingActions = [{
      id: 114,
      label: "Rebase JOB-2325",
      detail: null,
      state: "pending" as const,
      action: "rebase_job",
      action_type: null,
      chat_message_id: 6,
      app_confirm_path: "/api/v1/app/chats/122/pending_actions/114/confirm",
      app_reject_path: "/api/v1/app/chats/122/pending_actions/114/reject",
      app_cancel_path: "/api/v1/app/chats/122/pending_actions/114"
    }]

    const stream = buildMessageStreamItems(renderChatMessages(messages), pendingActions)
    const proposalIndex = stream.findIndex((item) => item.type === "message" && item.proposal?.id === proposal.id)
    const pendingActionIndex = stream.findIndex((item) => item.type === "pending_action" && item.pendingAction.id === 114)

    expect(proposalIndex).toBeGreaterThan(stream.findIndex((item) => item.type === "tool_group" && item.calls.some((call) => call.message_id === 3)))
    expect(pendingActionIndex).toBeGreaterThan(stream.findIndex((item) => item.type === "tool_group" && item.calls.some((call) => call.message_id === 6)))
    expect(pendingActionIndex).toBeLessThan(stream.findIndex((item) => item.type === "message" && item.id === 5) + 3)
    expect(stream[pendingActionIndex - 1].type).toBe("tool_group")
  })

  it("appends only truly unanchored pending actions at the bottom", () => {
    const messages = [
      {
        type: "message" as const,
        id: 1,
        role: "user" as const,
        content: { text: "Check this job" },
        text: "Check this job",
        bookmarkable: true
      },
      {
        type: "message" as const,
        id: 2,
        role: "tool_use" as const,
        tool_name: "syrus-chat-sidecar.check_job_mergeability",
        content: { type: "tool_use", id: "toolu_merge", name: "check_job_mergeability", input: { job_id: 2351 } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 3,
        role: "tool_result" as const,
        tool_name: "syrus-chat-sidecar.check_job_mergeability",
        content: {
          type: "tool_result",
          tool_use_id: "toolu_merge",
          content: [{ type: "text", text: "{\"pending_action_id\":201}" }],
          is_error: false
        },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 4,
        role: "assistant" as const,
        content: [{ type: "text", text: "Done." }],
        text: "Done.",
        bookmarkable: true
      }
    ]
    const anchored = {
      id: 201,
      label: "Check mergeability for JOB-2351",
      detail: null,
      state: "pending" as const,
      action: "check_job_mergeability",
      action_type: null,
      chat_message_id: 2,
      app_confirm_path: "/api/v1/app/chats/122/pending_actions/201/confirm",
      app_reject_path: "/api/v1/app/chats/122/pending_actions/201/reject",
      app_cancel_path: "/api/v1/app/chats/122/pending_actions/201"
    }
    const legacy = {
      ...anchored,
      id: 202,
      label: "Cancel JOB-2352",
      action: "cancel_job",
      chat_message_id: null
    }

    const stream = buildMessageStreamItems(renderChatMessages(messages), [anchored, legacy])
    const anchoredIndex = stream.findIndex((item) => item.type === "pending_action" && item.pendingAction.id === 201)
    const legacyIndex = stream.findIndex((item) => item.type === "pending_action" && item.pendingAction.id === 202)

    expect(stream[anchoredIndex - 1].type).toBe("tool_group")
    expect(legacyIndex).toBe(stream.length - 1)
  })

  it("renders result_body from the canonical 'content' key, not the legacy 'result' key", () => {
    const messages = [
      {
        type: "message" as const,
        id: 1,
        role: "tool_use" as const,
        tool_name: "Read",
        content: { type: "tool_use", id: "tu_1", name: "Read", input: { file_path: "/foo.rb" } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 2,
        role: "tool_result" as const,
        tool_name: "Read",
        content: {
          type: "tool_result",
          tool_use_id: "tu_1",
          content: [{ type: "text", text: "file contents here" }],
          is_error: false
        },
        text: "",
        bookmarkable: false
      }
    ]

    const items = renderChatMessages(messages)
    expect(items).toHaveLength(1)
    const group = items[0]
    expect(group.type).toBe("tool_group")
    if (group.type === "tool_group") {
      expect(group.calls).toHaveLength(1)
      expect(group.calls[0].result_body).not.toBe("(empty)")
      expect(group.calls[0].result_body).toContain("file contents here")
    }
  })

  it("renders canonical object result_body as pretty JSON", () => {
    const messages = [
      {
        type: "message" as const,
        id: 3,
        role: "tool_use" as const,
        tool_name: "syrus-chat-sidecar.read_job",
        content: { type: "tool_use", id: "tu_2", name: "syrus-chat-sidecar.read_job", input: { job_id: 2654 } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 4,
        role: "tool_result" as const,
        tool_name: "syrus-chat-sidecar.read_job",
        content: {
          type: "tool_result",
          tool_use_id: "tu_2",
          content: { affected_job: "JOB-2654", state: "open" },
          is_error: false
        },
        text: "",
        bookmarkable: false
      }
    ]

    const items = renderChatMessages(messages)
    expect(items).toHaveLength(1)
    const group = items[0]
    expect(group.type).toBe("tool_group")
    if (group.type === "tool_group") {
      expect(group.calls).toHaveLength(1)
      expect(group.calls[0].result_body).toContain('"affected_job": "JOB-2654"')
      expect(group.calls[0].result_body).toContain('"state": "open"')
      expect(group.calls[0].result_body).not.toContain("[object Object]")
    }
  })

  it("also handles legacy 'result' key for backwards compatibility", () => {
    const messages = [
      {
        type: "message" as const,
        id: 5,
        role: "tool_use" as const,
        tool_name: "Bash",
        content: { type: "tool_use", id: "tu_2", name: "Bash", input: { command: "echo hi" } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 6,
        role: "tool_result" as const,
        tool_name: "Bash",
        content: {
          type: "tool_result",
          tool_use_id: "tu_2",
          result: "hi\n",
          is_error: false
        },
        text: "",
        bookmarkable: false
      }
    ]

    const items = renderChatMessages(messages)
    expect(items).toHaveLength(1)
    const group = items[0]
    expect(group.type).toBe("tool_group")
    if (group.type === "tool_group") {
      expect(group.calls[0].result_body).not.toBe("(empty)")
      expect(group.calls[0].result_body).toContain("hi")
    }
  })
})

describe("renderChatMessages provider usage-limit banner", () => {
  it("projects structured provider usage-limit content into a prominent warning system message", () => {
    const items = renderChatMessages([
      {
        type: "message" as const,
        id: 9,
        role: "system" as const,
        content: {
          text: "Syrus halted work for codex gpt-5.5: usage limit or quota exhausted.",
          provider_error: {
            kind: "provider_usage_limit",
            provider: "codex",
            model: "gpt-5.5",
            halted: true,
            detail: "Codex API error: weekly usage limit exhausted"
          }
        },
        text: "Syrus halted work for codex gpt-5.5: usage limit or quota exhausted.",
        bookmarkable: false
      }
    ])

    expect(items).toHaveLength(1)
    const item = items[0]
    expect(item.type).toBe("message")
    if (item.type === "message") {
      expect(item.system).toMatchObject({
        tone: "warning",
        label: "Usage limit",
        prominent: true,
        body: expect.stringContaining("Syrus halted work for codex gpt-5.5")
      })
      expect(item.system?.body).toContain("weekly usage limit exhausted")
    }
  })
})
