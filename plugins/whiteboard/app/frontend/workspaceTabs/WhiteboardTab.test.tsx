import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, render, screen, waitFor } from "@testing-library/react"
import type { ChatPayload, ChatWhiteboardElement } from "@app/api/chats"
import { beforeEach, describe, expect, it, vi } from "vitest"
import WhiteboardTab from "./WhiteboardTab"

const excalidrawMock = vi.hoisted(() => ({
  initialData: null as { elements?: readonly ChatWhiteboardElement[] } | null,
  onChange: null as ((elements: readonly ChatWhiteboardElement[], appState: unknown, files: unknown) => void) | null,
  updateScene: vi.fn(),
  addFiles: vi.fn()
}))

const apiMock = vi.hoisted(() => ({
  patchChatWhiteboard: vi.fn()
}))

vi.mock("@excalidraw/excalidraw", () => ({
  Excalidraw: ({
    excalidrawAPI,
    initialData,
    onChange
  }: {
    excalidrawAPI: (api: { updateScene: typeof excalidrawMock.updateScene; addFiles: typeof excalidrawMock.addFiles }) => void
    initialData: { elements?: readonly ChatWhiteboardElement[] }
    onChange: typeof excalidrawMock.onChange
  }) => {
    excalidrawMock.initialData = initialData
    excalidrawMock.onChange = onChange
    excalidrawAPI({ updateScene: excalidrawMock.updateScene, addFiles: excalidrawMock.addFiles })
    return <div data-testid="excalidraw-canvas" />
  }
}))

vi.mock("@app/api/chats", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/api/chats")>()),
  patchChatWhiteboard: apiMock.patchChatWhiteboard
}))

const arrow = {
  id: "arrow-1",
  type: "arrow",
  x: 100,
  y: 50,
  width: 200,
  height: 0,
  points: [
    [0, 0],
    [200, 0]
  ],
  startBinding: { elementId: "box-1", focus: 0, gap: 1 },
  endBinding: { elementId: "box-2", focus: 0, gap: 1 },
  boundElements: [{ id: "label-1", type: "text" }]
}
const label = {
  id: "label-1",
  type: "text",
  text: "flows",
  originalText: "flows",
  containerId: "arrow-1",
  x: 170,
  y: 38,
  width: 60,
  height: 25
}

function payload(version: number, elements: ChatWhiteboardElement[]): ChatPayload {
  return {
    chat: { id: 8 },
    whiteboard: { version, elements, appState: {}, files: {}, loaded: true },
    paths: { app_whiteboard_path: "/api/v1/app/chats/8/whiteboard" }
  } as unknown as ChatPayload
}

function renderTab(chatPayload: ChatPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <WhiteboardTab payload={chatPayload} />
    </QueryClientProvider>
  )
}

describe("WhiteboardTab bound arrow labels", () => {
  beforeEach(() => {
    excalidrawMock.initialData = null
    excalidrawMock.onChange = null
    excalidrawMock.updateScene.mockReset()
    excalidrawMock.addFiles.mockReset()
    apiMock.patchChatWhiteboard.mockReset()
    apiMock.patchChatWhiteboard.mockResolvedValue({
      status: 200,
      payload: { version: 2, scene_json: { elements: [arrow, label], appState: {}, files: {} } }
    })
  })

  it("supplies the bound arrow and visible text together in Excalidraw initialData", async () => {
    renderTab(payload(1, [arrow, label]))

    await screen.findByTestId("excalidraw-canvas")
    expect(excalidrawMock.initialData?.elements).toEqual([arrow, label])
    expect(excalidrawMock.initialData?.elements?.[0]).toMatchObject({
      boundElements: [{ id: "label-1", type: "text" }]
    })
    expect(excalidrawMock.initialData?.elements?.[1]).toMatchObject({
      text: "flows",
      containerId: "arrow-1"
    })
  })

  it("keeps the arrow and label associated in the live updateScene path", async () => {
    const view = renderTab(payload(1, []))
    await screen.findByTestId("excalidraw-canvas")

    view.rerender(
      <QueryClientProvider client={new QueryClient()}>
        <WhiteboardTab payload={payload(2, [arrow, label])} />
      </QueryClientProvider>
    )

    await waitFor(() =>
      expect(excalidrawMock.updateScene).toHaveBeenCalledWith({
        elements: [arrow, label],
        appState: {}
      })
    )
  })

  it("persists resized bound geometry without losing the arrow label association", async () => {
    renderTab(payload(1, [arrow, label]))
    await screen.findByTestId("excalidraw-canvas")

    const resizedArrow = {
      ...arrow,
      x: 140,
      width: 260,
      points: [
        [0, 0],
        [260, 0]
      ],
      version: 2
    }
    const movedLabel = { ...label, x: 240, version: 2 }
    act(() => excalidrawMock.onChange?.([resizedArrow, movedLabel], {}, {}))

    await waitFor(
      () =>
        expect(apiMock.patchChatWhiteboard).toHaveBeenCalledWith("/api/v1/app/chats/8/whiteboard", {
          elements: [resizedArrow, movedLabel],
          appState: {},
          files: {},
          expected_version: 1
        }),
      { timeout: 2000 }
    )
    expect(resizedArrow.boundElements).toEqual([{ id: "label-1", type: "text" }])
    expect(movedLabel.containerId).toBe("arrow-1")
  })
})
