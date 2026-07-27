import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom"
import { ChatRoute } from "./Chat"
import { getStartingPhrase } from "./chat/streamChrome"
import { shouldAnimateMessageEntrance } from "./chat/MessageCards"
import { storedWorkspaceCollapsed } from "./chat/workspaceTabs"
import { renderChatMessages } from "./chat/streamBuilders"
import { asExcalidrawElements, VALID_EXCALIDRAW_TYPES } from "./chat/whiteboardScene"

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

    expect(screen.getByRole("complementary", { name: "Chat workspace" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Close workspace panel" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open workspace panel" })).not.toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("false")

    fireEvent.click(screen.getByRole("button", { name: "Close workspace panel" }))

    expect(screen.queryByRole("complementary", { name: "Chat workspace" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open workspace panel" })).toBeInTheDocument()
    await waitFor(() => {
      expect(window.localStorage.getItem("syrus.chat.workspace.collapsed")).toBe("true")
    })
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
      if (path === "/api/v1/app/chats/8?attachment_type=Epic") {
        return new Promise((resolve) => {
          resolveEpicSearch = () => resolve(jsonResponse(chatPayload({
            attachment_results: [{ type: "Epic", id: 2, label: "Release planning" }]
          })))
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
    mockDesktopViewport()
  })

  it("shows proposal confirmations as system events instead of operator bubbles", async () => {
    mockChatPayload(chatPayload({
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
    }))

    renderRoute()

    const notice = await screen.findByText('Proposal confirmed. JOB-88 "Map auth" was created.')
    expect(notice).toBeInTheDocument()
    expect(notice.closest(".bg-blue-600")).toBeNull()
    expect(notice.closest(".flex.justify-center")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Show 1 hidden system message" })).not.toBeInTheDocument()
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
    expect(screen.getByText("No bookmarks yet")).toBeInTheDocument()
  })

  it("closes from the backdrop and close button without navigating", async () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })
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
    expect(scrollIntoView).not.toHaveBeenCalled()
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
})

describe("chat proposal cards", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
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

  it("labels Epic confirmation without Jobs when the proposal has no child Jobs", async () => {
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

    expect(await screen.findByRole("button", { name: "Confirm Epic" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm Epic and Jobs" })).not.toBeInTheDocument()
  })

  it("labels Epic confirmation with Jobs when the proposal has child Jobs", async () => {
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

    expect(await screen.findByRole("button", { name: "Confirm Epic and Jobs" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm Epic" })).not.toBeInTheDocument()
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

    fireEvent.click(await screen.findByRole("button", { name: "Create Epic & Start Implementing" }))

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

describe("chat_polish message entrance", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("animates only messages that arrive after the initial load", () => {
    expect(shouldAnimateMessageEntrance(true, 10, 5)).toBe(true)
    // History and older pages stay at rest; the flag and null ids gate hard.
    expect(shouldAnimateMessageEntrance(true, 5, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(true, 3, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(false, 10, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(true, null, 5)).toBe(false)
    expect(shouldAnimateMessageEntrance(true, 10, null)).toBe(false)
  })

  it("renders initially loaded messages at rest even with the flag on", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify({ feature_flags: { chat_polish: true } })
    document.body.appendChild(script)
    mockChatRouteFetch()

    renderRoute()
    await screen.findByText("Discuss aqueducts.")

    const article = document.getElementById("chat_message_9")
    expect(article).not.toBeNull()
    expect(article!.className).not.toContain("animate-chat-message-in")
    script.remove()
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

  it("shows an empty media tab state when no images have been shared", async () => {
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

    expect(await screen.findByText("No media shared yet.")).toBeInTheDocument()
  })

  it("includes media in the mobile chat tab list", async () => {
    mockMobileViewport()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }

      return Promise.resolve(jsonResponse(chatPayload()))
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

  it("shows the stop button inside the textarea wrapper when agent is active", async () => {
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

describe("composer textarea right padding", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("uses pr-12 when agent is idle and textarea is empty", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    expect(textarea).toHaveClass("pr-12")
    expect(textarea).not.toHaveClass("pr-24")
    expect(textarea).not.toHaveClass("pr-32")
  })

  it("uses pr-24 when text is typed (stash button appears)", async () => {
    mockChatRouteFetch(chatPayload())
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(textarea, { target: { value: "some text" } })
    expect(textarea).toHaveClass("pr-24")
    expect(textarea).not.toHaveClass("pr-12")
  })

  it("uses pr-24 when agent is active and textarea is empty (stop button appears)", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Queue a follow-up message...")
    expect(textarea).toHaveClass("pr-24")
    expect(textarea).not.toHaveClass("pr-12")
  })

  it("uses pr-32 when agent is active and text is typed (send + stash + stop buttons)", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/chats/8/mark_read" && (init as RequestInit)?.method === "PATCH") {
        return Promise.resolve(new Response(null, { status: 204 }))
      }
      return Promise.resolve(jsonResponse({ ...chatPayload(), agent_busy: true }))
    })
    renderRoute()

    const textarea = await screen.findByPlaceholderText("Queue a follow-up message...")
    fireEvent.change(textarea, { target: { value: "some text" } })
    expect(textarea).toHaveClass("pr-32")
    expect(textarea).not.toHaveClass("pr-12")
    expect(textarea).not.toHaveClass("pr-24")
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

describe("AgentQuestionPrompt markdown rendering", () => {
  beforeEach(() => {
    window.localStorage.clear()
    mockDesktopViewport()
  })

  it("renders bold markdown in question text as a <strong> element", async () => {
    mockChatRouteFetch(chatPayload({
      agent_questions: [{
        id: 1,
        question: "Should we use **fiber** or threads?",
        options: null,
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
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
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

    return Promise.resolve(jsonResponse(payload))
  })
}

function mockChatPayload(payload: unknown) {
  vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
    }

    return Promise.resolve(jsonResponse(payload))
  })
}

function mockDesktopViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: query.includes("min-width: 1024px"),
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

function mockMobileViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: !query.includes("min-width: 1024px"),
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

function mockChatAttachmentFetch() {
  return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/chats/8/mark_read" && init?.method === "PATCH") {
      return Promise.resolve(new Response(null, { status: 204 }))
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

function chatPayload(overrides: { chat?: Record<string, unknown>; messages?: Array<Record<string, unknown>>; bookmarks?: Array<Record<string, unknown>>; attachment_groups?: Record<string, Array<Record<string, unknown>>>; attachment_results?: Array<Record<string, unknown>>; scratchpad_items?: Array<Record<string, unknown>>; queued_messages?: Array<Record<string, unknown>>; agent_questions?: Array<Record<string, unknown>> } = {}) {
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
    local_mode_enabled: false,
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
      app_stop_path: "/api/v1/app/chats/8/stop",
      app_bookmarks_path: "/api/v1/app/chats/8/bookmarks",
      app_attachments_path: "/api/v1/app/chats/8/attachments",
      app_whiteboard_path: "/api/v1/app/chats/8/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/8/scratchpad_items/reorder"
    }
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

describe("renderChatMessages tool_result content key", () => {
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

  it("also handles legacy 'result' key for backwards compatibility", () => {
    const messages = [
      {
        type: "message" as const,
        id: 3,
        role: "tool_use" as const,
        tool_name: "Bash",
        content: { type: "tool_use", id: "tu_2", name: "Bash", input: { command: "echo hi" } },
        text: "",
        bookmarkable: false
      },
      {
        type: "message" as const,
        id: 4,
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
