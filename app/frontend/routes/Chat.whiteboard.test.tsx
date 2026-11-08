import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { excalidrawMock } from "../test/app/appMocks"
import { chatPayload } from "../test/app/chatPayloads"
import { clickWhiteboardTab, openWhiteboardPanel } from "../test/app/whiteboard"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat whiteboard", () => {
  installAppTestLifecycle()

  it("saves chat whiteboard changes through the app API", async () => {
    excalidrawMock.updateScene.mockClear()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ version: 3 }), { status: 200, headers: { "Content-Type": "application/json" } }))
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

    await openWhiteboardPanel()
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
        elements: [
          { id: "box-1", type: "rectangle" },
          { id: "shape-react", type: "image", fileId: "file-react", version: 1 }
        ],
        appState: { viewBackgroundColor: "#ffffff" }
      })
    })
    expect(screen.queryByText(/^Version \d+$/)).not.toBeInTheDocument()
  })

  it("keeps the server scene after a whiteboard save conflict", async () => {
    excalidrawMock.updateScene.mockClear()
    let whiteboardPatchCount = 0
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        whiteboardPatchCount += 1
        return Promise.resolve(
          new Response(
            JSON.stringify({
              scene_json: {
                elements: [
                  { id: "box-1", type: "rectangle" },
                  { id: "agent-box", type: "rectangle" }
                ],
                appState: {},
                files: {}
              },
              version: 3
            }),
            { status: 409, headers: { "Content-Type": "application/json" } }
          )
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

    await openWhiteboardPanel()
    fireEvent.click(await screen.findByRole("button", { name: "Draw on whiteboard" }))

    await waitFor(() => {
      expect(excalidrawMock.updateScene).toHaveBeenCalledWith({
        elements: [
          { id: "box-1", type: "rectangle" },
          { id: "agent-box", type: "rectangle" }
        ],
        appState: {}
      })
    })
    expect(whiteboardPatchCount).toBe(1)
    expect(fetchSpy.mock.calls.some(([path, init]) => String(path) === "/api/v1/app/chats/8/whiteboard" && init?.method == null)).toBe(false)
  })

  it("reconciles an edit queued while a conflicting whiteboard save is in flight", async () => {
    let resolveFirstPatch: (response: Response) => void = () => undefined
    const patchBodies: Array<Record<string, unknown>> = []
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        patchBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>)
        if (patchBodies.length === 1) {
          return new Promise<Response>((resolve) => {
            resolveFirstPatch = resolve
          })
        }
        return Promise.resolve(new Response(JSON.stringify({ version: 4 }), { status: 200, headers: { "Content-Type": "application/json" } }))
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

    await openWhiteboardPanel()
    fireEvent.click(await screen.findByRole("button", { name: "Draw on whiteboard" }))
    await waitFor(() => expect(patchBodies).toHaveLength(1))

    act(() => {
      excalidrawMock.onChange?.(
        [
          { id: "box-1", type: "rectangle", version: 1 },
          { id: "shape-react", type: "image", version: 1 },
          { id: "second-user-shape", type: "ellipse", version: 1 }
        ],
        {},
        {}
      )
    })
    resolveFirstPatch(
      new Response(
        JSON.stringify({
          scene_json: {
            elements: [
              { id: "box-1", type: "rectangle", version: 1 },
              { id: "agent-box", type: "rectangle", version: 1 }
            ],
            appState: {},
            files: {}
          },
          version: 3
        }),
        { status: 409, headers: { "Content-Type": "application/json" } }
      )
    )

    await waitFor(() => expect(patchBodies).toHaveLength(2))
    expect(patchBodies[1].expected_version).toBe(3)
    expect(patchBodies[1].elements).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: "agent-box" }), expect.objectContaining({ id: "second-user-shape" })])
    )
    expect(fetchSpy.mock.calls.some(([path, init]) => String(path) === "/api/v1/app/chats/8/whiteboard" && init?.method == null)).toBe(false)
  })

  it("shows whiteboard snapshots in media and loads one onto the canvas", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots" && init?.method == null) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              whiteboard_snapshots: [
                {
                  id: 12,
                  name: "Important milestone with a long enough title to truncate",
                  snapshot_kind: "manual",
                  element_count: 1,
                  created_at: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString()
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots/12") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
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
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method == null) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              scene_json: { elements: [{ id: "box-1", type: "rectangle" }], appState: {}, files: {} },
              version: 2
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/8/whiteboard_snapshots" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              id: 13,
              name: "Before load",
              snapshot_kind: "auto_before_load",
              element_count: 1,
              created_at: "2026-06-26T11:00:00Z",
              scene_json: { elements: [{ id: "box-1", type: "rectangle" }], appState: {}, files: {} }
            }),
            { status: 201, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              scene_json: {
                elements: [
                  { id: "box-1", type: "rectangle" },
                  { id: "fresh-snapshot-box", type: "rectangle", boundElements: [{ id: "fresh-snapshot-label", type: "text" }] }
                ],
                appState: {},
                files: { "file-snapshot": { id: "file-snapshot", mimeType: "image/png" } }
              },
              version: 3
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(JSON.stringify(chatPayload({ whiteboardSnapshotCount: 1 })), { status: 200, headers: { "Content-Type": "application/json" } })
      )
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
    expect(screen.getByText("1 whiteboard element")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load" }))

    await waitFor(() => expect(screen.getByText("Loaded Important milestone onto canvas")).toBeInTheDocument())
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/whiteboard_snapshots",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining('"snapshot_kind":"auto_before_load"')
        })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/whiteboard",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining('"expected_version":2')
        })
      )
    })
  })

  it("does not push the initial whiteboard scene back through the imperative API", async () => {
    excalidrawMock.updateScene.mockClear()
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

    await openWhiteboardPanel()
    expect(excalidrawMock.updateScene).not.toHaveBeenCalled()
  })

  it("strips serialized collaborators before mounting the whiteboard", async () => {
    const payload = chatPayload()
    payload.whiteboard.appState = {
      viewBackgroundColor: "#ffffff",
      collaborators: {},
      selectedElementIds: { "box-1": true }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await openWhiteboardPanel()
    expect(excalidrawMock.lastInitialData?.appState).toEqual({ viewBackgroundColor: "#ffffff" })
  })

  it("strips activeTool from whiteboard appState so elements remain selectable after mount", async () => {
    const payload = chatPayload()
    payload.whiteboard.appState = {
      viewBackgroundColor: "#ffffff",
      activeTool: { type: "rectangle", customType: null }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await openWhiteboardPanel()
    expect(excalidrawMock.lastInitialData?.appState).toEqual({ viewBackgroundColor: "#ffffff" })
  })

  it("strips activeTool from appState when applying a remote whiteboard scene update", async () => {
    excalidrawMock.updateScene.mockClear()
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/whiteboard" && init?.method === "PATCH") {
        return Promise.resolve(new Response(JSON.stringify({ version: 3 }), { status: 200, headers: { "Content-Type": "application/json" } }))
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

    await openWhiteboardPanel()
    fireEvent.click(await screen.findByRole("button", { name: "Draw on whiteboard" }))

    await waitFor(() => {
      expect(excalidrawMock.updateScene).toHaveBeenCalledWith({
        elements: [
          { id: "box-1", type: "rectangle" },
          { id: "shape-react", type: "image", fileId: "file-react", version: 1 }
        ],
        appState: { viewBackgroundColor: "#ffffff" }
      })
    })
  })

  it("keeps the chat visible when the whiteboard render fails", async () => {
    excalidrawMock.throwOnRender = true
    vi.spyOn(console, "error").mockImplementation(() => {})
    const preventExpectedCanvasError = (event: ErrorEvent) => {
      if (event.error instanceof Error && event.error.message === "Canvas crashed") event.preventDefault()
    }
    window.addEventListener("error", preventExpectedCanvasError)
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await clickWhiteboardTab()
      expect(await screen.findByText("Discuss aqueducts.")).toBeInTheDocument()
      expect(await screen.findByText("Whiteboard unavailable.")).toBeInTheDocument()
      expect(screen.getByPlaceholderText("Ask about this repository...")).toBeInTheDocument()
    } finally {
      excalidrawMock.throwOnRender = false
      window.removeEventListener("error", preventExpectedCanvasError)
    }
  })
})
